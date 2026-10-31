import { HttpError } from "./http";
import { UpstreamError } from "./upstream";

// ElevenLabs is the only non-Meta model in Pip: Meta has no text-to-speech model.
const ELEVENLABS = "https://api.elevenlabs.io/v1/text-to-speech";
const MODEL = "eleven_flash_v2_5";
const VOICE_ID = /^[A-Za-z0-9]{16,32}$/;
const MAX_CHARS = 600;
// Flash: 0.5 credit per character; about $0.17 per 1,000 credits on the Starter plan.
const USD_PER_CHAR = 0.5 * 0.00017;

export interface SpeakRequest {
  text: string;
  voice: string;
  /** ISO 639-1, e.g. "nl" or "en". */
  language?: string;
}

/**
 * Streams speech for one sentence as newline-delimited JSON chunks, each with base64 PCM
 * (24 kHz, 16-bit mono) and the start time of every character, which the app uses to time cues.
 */
export async function speak(apiKey: string, req: SpeakRequest, charge: (usd: number) => void): Promise<Response> {
  const text = typeof req.text === "string" ? req.text.trim() : "";
  if (!text || text.length > MAX_CHARS) throw new HttpError(400, "invalid_request", `text must be 1–${MAX_CHARS} characters`);
  if (typeof req.voice !== "string" || !VOICE_ID.test(req.voice)) throw new HttpError(400, "invalid_request", "voice must be an ElevenLabs voice id");
  const language = typeof req.language === "string" && /^[a-z]{2}$/.test(req.language) ? req.language : undefined;

  const res = await fetch(`${ELEVENLABS}/${req.voice}/stream/with-timestamps?output_format=pcm_24000`, {
    method: "POST",
    headers: { "xi-api-key": apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({ text, model_id: MODEL, ...(language ? { language_code: language } : {}) }),
  });
  if (!res.ok || !res.body) throw await UpstreamError.from(res, "speak");
  charge(text.length * USD_PER_CHAR);
  return new Response(res.body, { headers: { "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache" } });
}
