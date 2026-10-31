import { HttpError } from "./http";
import { META_API, UpstreamError } from "./upstream";

const MODEL = "muse-voice-transcribe-1.0";
const REALTIME_URL = `${META_API}/asr/realtime`;
const MODES = new Set(["PUSH_TO_TALK", "ENDPOINTING"]);
const ENCODINGS: Record<string, number> = { PCM_24KHZ: 48_000, PCM_16KHZ: 32_000 };
const PARTIAL_MODES = new Set(["CUMULATIVE", "DELTA"]);
/** A live session is charged, and the spend cap re-checked, every this many seconds of audio. */
const CHARGE_EVERY_SECONDS = 30;
/** Audio held while the upstream session opens (5 s at 24 kHz). */
const MAX_PENDING_BYTES = 240_000;

export interface AsrOptions {
  mode?: string;
  languageBias?: string[];
  keywords?: string[];
}

function cleanList(list: unknown, max: number): string[] | undefined {
  if (!Array.isArray(list)) return undefined;
  const out = list.filter((s): s is string => typeof s === "string" && s.trim().length > 0).map((s) => s.trim());
  return out.length ? out.slice(0, max) : undefined;
}

function cleanOptions(o: AsrOptions): AsrOptions {
  return {
    mode: o.mode && MODES.has(o.mode) ? o.mode : "PUSH_TO_TALK",
    languageBias: cleanList(o.languageBias, 4),
    keywords: cleanList(o.keywords, 50),
  };
}

/**
 * Duration in seconds of a mono 16-bit PCM WAV at 16 or 24 kHz, or null for anything else.
 * The rate is derived from the format fields, never from the header's own byte rate.
 */
export function wavDurationSeconds(buf: ArrayBuffer): number | null {
  const v = new DataView(buf);
  if (buf.byteLength < 44) return null;
  const tag = (o: number) => String.fromCharCode(v.getUint8(o), v.getUint8(o + 1), v.getUint8(o + 2), v.getUint8(o + 3));
  if (tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;
  let byteRate = 0;
  let offset = 12;
  while (offset + 8 <= buf.byteLength) {
    const id = tag(offset);
    const size = v.getUint32(offset + 4, true);
    if (id === "fmt " && offset + 24 <= buf.byteLength) {
      const format = v.getUint16(offset + 8, true);
      const channels = v.getUint16(offset + 10, true);
      const sampleRate = v.getUint32(offset + 12, true);
      const bits = v.getUint16(offset + 22, true);
      if (format !== 1 || channels !== 1 || bits !== 16 || (sampleRate !== 16_000 && sampleRate !== 24_000)) return null;
      byteRate = sampleRate * 2;
    }
    if (id === "data") {
      const dataBytes = Math.min(size, buf.byteLength - offset - 8);
      return byteRate > 0 ? dataBytes / byteRate : null;
    }
    offset += 8 + size + (size % 2);
  }
  return null;
}

/** One complete WAV recording → transcript (batch endpoint). */
export async function transcribe(apiKey: string, wav: ArrayBuffer, options: AsrOptions): Promise<{ json: unknown; seconds: number }> {
  const seconds = wavDurationSeconds(wav);
  if (seconds === null) throw new HttpError(400, "invalid_audio", "Expected a mono 16-bit PCM WAV file (16 or 24 kHz)");
  const form = new FormData();
  form.append(
    "request",
    new Blob([JSON.stringify({ model: MODEL, audioEncoding: "WAV", ...cleanOptions(options) })], { type: "application/json" }),
  );
  form.append("audio", new File([wav], "audio.wav", { type: "audio/wav" }));
  const res = await fetch(`${META_API}/asr/transcribe`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
    body: form,
  });
  if (!res.ok) throw await UpstreamError.from(res, "asr");
  return { json: await res.json(), seconds };
}

function safeClose(ws: WebSocket | null, code: number, reason: string): void {
  if (!ws) return;
  // 1005/1006 are reserved and cannot be sent.
  const sendable = code >= 1000 && code <= 4999 && code !== 1005 && code !== 1006 ? code : 1011;
  try {
    ws.close(sendable, reason.slice(0, 120));
  } catch {
    // Already closed.
  }
}

export interface RelayMeter {
  /** Records the cost of this many seconds of audio. */
  charge(seconds: number): void;
  /** True when the spend cap has been reached. */
  overCap(): Promise<boolean>;
}

/**
 * Relays a realtime transcription session. The app sends its handshake without a key as the
 * first text frame; the Worker validates it, injects the key and the model, and then forwards
 * binary PCM frames up and server events down. Audio is charged as it flows, and the session
 * closes if the spend cap is reached.
 */
export function relayAsr(apiKey: string, meter: RelayMeter): Response {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  // Recent runtimes deliver binary frames as Blob by default; PCM must stay an ArrayBuffer.
  server.binaryType = "arraybuffer";
  server.accept();

  let upstream: WebSocket | null = null;
  let handshake = false;
  let bytesPerSecond = ENCODINGS.PCM_24KHZ;
  let audioBytes = 0;
  let chargedBytes = 0;
  let ended = false;
  const pending: (ArrayBuffer | string)[] = [];
  let pendingBytes = 0;

  const chargeUpTo = (bytes: number) => {
    const seconds = (bytes - chargedBytes) / bytesPerSecond;
    if (seconds > 0) meter.charge(seconds);
    chargedBytes = bytes;
  };
  const end = () => {
    if (ended) return;
    ended = true;
    chargeUpTo(audioBytes);
    safeClose(upstream, 1000, "session ended");
  };
  const forward = (data: ArrayBuffer | string) => {
    if (ended) return;
    if (upstream) {
      if (upstream.readyState !== WebSocket.OPEN) return;
      try {
        upstream.send(data);
      } catch {
        // Upstream closed under us; its close handler ends the session.
      }
    } else if (pendingBytes < MAX_PENDING_BYTES) {
      pending.push(data);
      pendingBytes += typeof data === "string" ? data.length : data.byteLength;
    }
  };

  const open = async (raw: string) => {
    let hs: Record<string, unknown>;
    try {
      hs = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      safeClose(server, 1008, "handshake must be JSON");
      end();
      return;
    }
    const encoding = typeof hs.audioEncoding === "string" && Object.hasOwn(ENCODINGS, hs.audioEncoding) ? hs.audioEncoding : "PCM_24KHZ";
    bytesPerSecond = ENCODINGS[encoding];
    const config = {
      model: MODEL,
      authorization: { accessToken: `Bearer ${apiKey}` },
      audioEncoding: encoding,
      ...cleanOptions(hs as AsrOptions),
      ...(typeof hs.partialMode === "string" && PARTIAL_MODES.has(hs.partialMode) ? { partialMode: hs.partialMode } : {}),
    };
    const res = await fetch(`${REALTIME_URL}?sessionId=pip-${crypto.randomUUID()}`, { headers: { Upgrade: "websocket" } });
    const ws = res.webSocket;
    if (!ws) {
      safeClose(server, 1011, `upstream refused (${res.status})`);
      end();
      return;
    }
    ws.binaryType = "arraybuffer";
    ws.accept();
    if (ended) {
      // The app went away while the upstream session was opening.
      safeClose(ws, 1000, "client gone");
      return;
    }
    ws.send(JSON.stringify(config));
    ws.addEventListener("message", (e) => {
      // Never pass on anything that could carry the key.
      if (typeof e.data === "string" && e.data.includes(apiKey)) return;
      try {
        server.send(e.data as string | ArrayBuffer);
      } catch {
        safeClose(ws, 1000, "client gone");
      }
    });
    ws.addEventListener("close", (e) => {
      safeClose(server, e.code, e.reason);
      end();
    });
    ws.addEventListener("error", () => {
      safeClose(server, 1011, "upstream error");
      end();
    });
    upstream = ws;
    for (const m of pending.splice(0)) ws.send(m);
    pendingBytes = 0;
  };

  server.addEventListener("message", (e) => {
    if (ended) return;
    if (!handshake) {
      handshake = true;
      if (typeof e.data !== "string") {
        safeClose(server, 1008, "first frame must be the JSON handshake");
        end();
        return;
      }
      open(e.data).catch(() => {
        safeClose(server, 1011, "upstream unavailable");
        end();
      });
      return;
    }
    if (typeof e.data === "string") {
      // After the handshake the only text frame the API accepts is the end-of-input marker.
      if (e.data.includes('"endStream"')) forward(JSON.stringify({ type: "endStream" }));
      return;
    }
    audioBytes += e.data.byteLength;
    forward(e.data);
    if (audioBytes - chargedBytes >= CHARGE_EVERY_SECONDS * bytesPerSecond) {
      chargeUpTo(audioBytes);
      meter.overCap().then((over) => {
        if (over) {
          safeClose(server, 1008, "spend cap reached");
          end();
        }
      }, () => {});
    }
  });
  server.addEventListener("close", (e) => {
    safeClose(upstream, e.code, "client closed");
    end();
  });
  server.addEventListener("error", () => end());

  return new Response(null, { status: 101, webSocket: client });
}
