import { HttpError } from "./http";
import { META_API, UpstreamError } from "./upstream";

const MODEL = "muse-voice-transcribe-1.0";
const REALTIME_URL = "https://api.meta.ai/v1/asr/realtime";
const MODES = new Set(["PUSH_TO_TALK", "ENDPOINTING"]);
const ENCODINGS: Record<string, number> = { PCM_24KHZ: 48_000, PCM_16KHZ: 32_000 };
const PARTIAL_MODES = new Set(["CUMULATIVE", "DELTA"]);

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

/** Duration of a PCM WAV file in seconds, or null if the header is not RIFF/WAVE PCM. */
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
    if (id === "fmt " && offset + 20 <= buf.byteLength) byteRate = v.getUint32(offset + 16, true);
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

/**
 * Relays a realtime transcription session. The app sends its handshake without a key as the
 * first text frame; the Worker validates it, injects the key and the model, and then forwards
 * binary PCM frames up and server events down. `onEnd` receives the seconds of audio relayed.
 */
export function relayAsr(apiKey: string, onEnd: (seconds: number) => void): Response {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();

  let upstream: WebSocket | null = null;
  let handshake = false;
  let bytesPerSecond = ENCODINGS.PCM_24KHZ;
  let audioBytes = 0;
  let ended = false;
  const pending: (ArrayBuffer | string)[] = [];

  const end = () => {
    if (ended) return;
    ended = true;
    onEnd(audioBytes / bytesPerSecond);
  };
  const forward = (data: ArrayBuffer | string) => {
    if (upstream) upstream.send(data);
    else pending.push(data);
  };

  const open = async (raw: string) => {
    let hs: Record<string, unknown>;
    try {
      hs = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      safeClose(server, 1008, "handshake must be JSON");
      return;
    }
    const encoding = typeof hs.audioEncoding === "string" && hs.audioEncoding in ENCODINGS ? hs.audioEncoding : "PCM_24KHZ";
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
    ws.accept();
    ws.send(JSON.stringify(config));
    ws.addEventListener("message", (e) => {
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
  };

  server.addEventListener("message", (e) => {
    if (!handshake) {
      handshake = true;
      if (typeof e.data !== "string") {
        safeClose(server, 1008, "first frame must be the JSON handshake");
        return;
      }
      void open(e.data);
      return;
    }
    if (typeof e.data === "string") {
      // After the handshake the only text frame the API accepts is the end-of-input marker.
      if (e.data.includes('"endStream"')) forward(JSON.stringify({ type: "endStream" }));
      return;
    }
    audioBytes += e.data.byteLength;
    forward(e.data);
  });
  server.addEventListener("close", (e) => {
    safeClose(upstream, e.code, "client closed");
    end();
  });
  server.addEventListener("error", () => {
    safeClose(upstream, 1000, "client error");
    end();
  });

  return new Response(null, { status: 101, webSocket: client });
}
