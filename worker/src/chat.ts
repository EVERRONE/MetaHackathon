import { sparkCost, sparkFallbackCost, type ChatUsage } from "./cost";
import { HttpError } from "./http";
import { META_API, UpstreamError } from "./upstream";

const ALLOWED_MODELS = new Set(["muse-spark-1.3", "muse-wonder-1.0"]);

/**
 * Passes an SSE stream through unchanged while watching for the final `usage` chunk.
 * `onDone` runs once, when the stream ends or the client goes away.
 */
export function usageTap(onDone: (usage: ChatUsage | null, bytes: number) => void): TransformStream<Uint8Array, Uint8Array> {
  const decoder = new TextDecoder();
  let buffer = "";
  let usage: ChatUsage | null = null;
  let bytes = 0;
  let done = false;
  const scan = (final: boolean) => {
    const lines = buffer.split("\n");
    buffer = final ? "" : (lines.pop() ?? "");
    for (const line of lines) {
      if (!line.startsWith("data:") || !line.includes('"usage"')) continue;
      try {
        const chunk = JSON.parse(line.slice(5).trim()) as { usage?: ChatUsage | null };
        if (chunk.usage) usage = chunk.usage;
      } catch {
        // Not JSON (e.g. [DONE]); ignore.
      }
    }
  };
  const finish = () => {
    if (done) return;
    done = true;
    onDone(usage, bytes);
  };
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      controller.enqueue(chunk);
      bytes += chunk.byteLength;
      buffer += decoder.decode(chunk, { stream: true });
      scan(false);
    },
    flush() {
      buffer += decoder.decode();
      scan(true);
      finish();
    },
    cancel() {
      finish();
    },
  } as Transformer<Uint8Array, Uint8Array>);
}

/** Reserves an amount before a call; returns how to settle it with the real cost afterwards. */
export type Reserve = (usd: number) => Promise<(actual: number) => void>;

const ALLOWED_KEYS = new Set([
  "model", "messages", "stream", "stream_options", "reasoning_effort", "prompt_cache_key", "max_completion_tokens", "response_format", "temperature",
]);
const ALLOWED_EFFORTS = new Set(["minimal", "low", "medium"]);
const ROLES = new Set(["system", "user", "assistant"]);
export const MAX_COMPLETION_TOKENS = 8_000;
const DEFAULT_COMPLETION_TOKENS = 4_000;
const MAX_MESSAGES = 40;
/** The memory search sends up to 12 contact sheets. */
const MAX_IMAGES = 16;

/**
 * Only what the app sends passes: the known fields, inline images only (no links for Meta's
 * servers to fetch, no stored files), no tools or several choices, and a bounded output that is
 * always set (a missing limit meant the model's own). Returns the inline image count and the
 * output limit, for the reservation.
 */
export function validateChat(body: Record<string, unknown>): { images: number; maxOutput: number } {
  if (typeof body.model !== "string" || !ALLOWED_MODELS.has(body.model)) {
    throw new HttpError(400, "model_not_allowed", `Allowed models: ${[...ALLOWED_MODELS].join(", ")}`);
  }
  const unknown = Object.keys(body).filter((k) => !ALLOWED_KEYS.has(k));
  if (unknown.length) throw new HttpError(400, "invalid_request", `Unsupported fields: ${unknown.join(", ")}`);
  if (body.stream !== undefined && typeof body.stream !== "boolean") throw new HttpError(400, "invalid_request", "stream must be true or false");
  if (body.reasoning_effort !== undefined && !ALLOWED_EFFORTS.has(body.reasoning_effort as string)) {
    throw new HttpError(400, "invalid_request", `reasoning_effort must be one of ${[...ALLOWED_EFFORTS].join(", ")}`);
  }
  if (body.prompt_cache_key !== undefined && (typeof body.prompt_cache_key !== "string" || body.prompt_cache_key.length > 200)) {
    throw new HttpError(400, "invalid_request", "prompt_cache_key must be a short string");
  }
  if (body.temperature !== undefined && typeof body.temperature !== "number") throw new HttpError(400, "invalid_request", "temperature must be a number");
  if (body.response_format !== undefined && (typeof body.response_format !== "object" || body.response_format === null)) {
    throw new HttpError(400, "invalid_request", "response_format must be an object");
  }
  const requested = body.max_completion_tokens;
  if (requested !== undefined && !(typeof requested === "number" && requested > 0)) {
    throw new HttpError(400, "invalid_request", "max_completion_tokens must be a positive number");
  }
  const maxOutput = Math.min(Math.floor((requested as number | undefined) ?? DEFAULT_COMPLETION_TOKENS), MAX_COMPLETION_TOKENS);
  body.max_completion_tokens = maxOutput;

  if (!Array.isArray(body.messages) || body.messages.length === 0 || body.messages.length > MAX_MESSAGES) {
    throw new HttpError(400, "invalid_request", `messages must be an array of 1–${MAX_MESSAGES}`);
  }
  let images = 0;
  for (const m of body.messages as { role?: unknown; content?: unknown }[]) {
    if (typeof m !== "object" || m === null || !ROLES.has(m.role as string)) throw new HttpError(400, "invalid_request", "Each message needs a role");
    if (typeof m.content === "string") continue;
    if (!Array.isArray(m.content)) throw new HttpError(400, "invalid_request", "content must be a string or an array of parts");
    for (const part of m.content as { type?: unknown; text?: unknown; image_url?: { url?: unknown } }[]) {
      if (part?.type === "text" && typeof part.text === "string") continue;
      if (part?.type === "image_url" && typeof part.image_url?.url === "string" && part.image_url.url.startsWith("data:image/")) {
        images += 1;
        continue;
      }
      throw new HttpError(400, "invalid_request", "Parts are text or inline data:image URLs");
    }
  }
  if (images > MAX_IMAGES) throw new HttpError(400, "invalid_request", `At most ${MAX_IMAGES} images`);
  return { images, maxOutput };
}

/**
 * Forwards an OpenAI-style chat completion to Muse with the key injected. The most it can cost
 * (its input and its full output limit) is reserved first; streams are passed through byte for
 * byte, and the reservation is settled from the usage chunk.
 */
export async function chat(
  apiKey: string,
  body: Record<string, unknown>,
  /** Request size without inline images, for the estimates. */
  requestBytes: number,
  reserve: Reserve,
): Promise<Response> {
  const { images, maxOutput } = validateChat(body);
  const model = body.model as string;
  body.store = false;
  const stream = body.stream === true;
  if (stream) {
    const opts = typeof body.stream_options === "object" && body.stream_options !== null ? body.stream_options : {};
    body.stream_options = { ...opts, include_usage: true };
  }
  const settle = await reserve(chatReservation(requestBytes, images, maxOutput, model));
  let upstream: Response;
  try {
    upstream = await fetch(`${META_API}/chat/completions`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (err) {
    settle(0);
    throw err;
  }
  if (!upstream.ok) {
    settle(0);
    throw await UpstreamError.from(upstream, "chat");
  }

  if (!stream || !upstream.body) {
    const json = (await upstream.json()) as { usage?: ChatUsage };
    settle(json.usage ? sparkCost(json.usage, model) : chatReservation(requestBytes, images, maxOutput, model));
    return Response.json(json);
  }

  const tapped = upstream.body.pipeThrough(
    usageTap((usage, bytes) => settle(usage ? sparkCost(usage, model) : sparkFallbackCost(requestBytes, bytes, images, model, maxOutput))),
  );
  return new Response(tapped, {
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache",
    },
  });
}

/** The most a chat call can cost: its input (inline images priced per image) and its full output. */
export function chatReservation(requestBytes: number, images: number, maxOutput: number, model: string): number {
  return sparkFallbackCost(requestBytes, maxOutput * 150, images, model, maxOutput);
}
