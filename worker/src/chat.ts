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

/**
 * Forwards an OpenAI-style chat completion to Muse Spark with the key injected.
 * Streams are passed through byte for byte; the cost is recorded from the usage chunk.
 */
export async function chat(
  apiKey: string,
  body: Record<string, unknown>,
  /** Request size without inline images, for the fallback cost estimate. */
  requestBytes: number,
  imageCount: number,
  charge: (usd: number) => void,
): Promise<Response> {
  if (typeof body.model !== "string" || !ALLOWED_MODELS.has(body.model)) {
    throw new HttpError(400, "model_not_allowed", `Allowed models: ${[...ALLOWED_MODELS].join(", ")}`);
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    throw new HttpError(400, "invalid_request", "messages must be a non-empty array");
  }
  const model = body.model;
  body.store = false;
  const stream = body.stream === true;
  if (stream) {
    const opts = typeof body.stream_options === "object" && body.stream_options !== null ? body.stream_options : {};
    body.stream_options = { ...opts, include_usage: true };
  }

  const upstream = await fetch(`${META_API}/chat/completions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!upstream.ok) throw await UpstreamError.from(upstream, "chat");

  if (!stream || !upstream.body) {
    const json = (await upstream.json()) as { usage?: ChatUsage };
    charge(json.usage ? sparkCost(json.usage, model) : sparkFallbackCost(requestBytes, 0, imageCount));
    return Response.json(json);
  }

  const tapped = upstream.body.pipeThrough(
    usageTap((usage, bytes) => charge(usage ? sparkCost(usage, model) : sparkFallbackCost(requestBytes, bytes, imageCount))),
  );
  return new Response(tapped, {
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache",
    },
  });
}
