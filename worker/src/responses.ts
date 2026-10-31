import { sparkCost, type ChatUsage } from "./cost";
import { HttpError } from "./http";
import { META_API, UpstreamError } from "./upstream";

// The Responses API is used for two things the chat route cannot do: web search (finding a
// product's official manual) and reading a PDF from its URL.
const ALLOWED_MODELS = new Set(["muse-spark-1.3", "muse-wonder-1.0"]);
const USD_PER_SEARCH = 2.5 / 1000;

interface ResponsesUsage {
  input_tokens?: number;
  output_tokens?: number;
  input_tokens_details?: { cached_tokens?: number } | null;
}

/** Only web search may be used as a tool, and only https files may be referenced. */
function validate(body: Record<string, unknown>): void {
  if (typeof body.model !== "string" || !ALLOWED_MODELS.has(body.model)) {
    throw new HttpError(400, "model_not_allowed", `Allowed models: ${[...ALLOWED_MODELS].join(", ")}`);
  }
  if (body.stream === true) throw new HttpError(400, "invalid_request", "Streaming is not supported on this route");
  if (body.tools !== undefined) {
    if (!Array.isArray(body.tools) || body.tools.some((t) => typeof t !== "object" || t === null || (t as { type?: unknown }).type !== "web_search")) {
      throw new HttpError(400, "invalid_request", "Only the web_search tool is allowed");
    }
  }
  const raw = JSON.stringify(body.input ?? "");
  for (const m of raw.matchAll(/"file_url"\s*:\s*"([^"]*)"/g)) {
    if (!m[1].startsWith("https://")) throw new HttpError(400, "invalid_request", "file_url must be https");
  }
}

export async function responses(apiKey: string, body: Record<string, unknown>, charge: (usd: number) => void): Promise<Response> {
  validate(body);
  body.store = false;
  const res = await fetch(`${META_API}/responses`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw await UpstreamError.from(res, "responses");
  const json = (await res.json()) as { usage?: ResponsesUsage; output?: { type?: string }[] };
  const u = json.usage ?? {};
  const usage: ChatUsage = {
    prompt_tokens: u.input_tokens ?? 0,
    completion_tokens: u.output_tokens ?? 0,
    prompt_tokens_details: { cached_tokens: u.input_tokens_details?.cached_tokens ?? 0 },
  };
  const searches = (json.output ?? []).filter((o) => o.type === "web_search_call").length;
  charge(sparkCost(usage, body.model as string) + searches * USD_PER_SEARCH);
  return Response.json(json);
}

/**
 * Checks that a document link really exists before Pip relies on it: an https URL that answers
 * 200 with a PDF or a web page. Models can produce links that look right but do not exist.
 */
export async function checkSource(url: unknown): Promise<Response> {
  if (typeof url !== "string" || !/^https:\/\/[^/\s]+\.[^/\s]+\//.test(url)) {
    throw new HttpError(400, "invalid_request", "url must be an https link");
  }
  const host = new URL(url).hostname;
  if (/^(\d+\.){3}\d+$/.test(host) || host === "localhost" || host.endsWith(".local")) {
    throw new HttpError(400, "invalid_request", "url must be a public site");
  }
  const res = await fetch(url, { method: "GET", headers: { Range: "bytes=0-1023", "User-Agent": "Mozilla/5.0 (Pip manual check)" }, redirect: "follow" });
  const type = res.headers.get("content-type") ?? "";
  const ok = (res.status === 200 || res.status === 206) && (type.includes("pdf") || type.includes("html"));
  const range = res.headers.get("content-range");
  const bytes = range ? Number(range.split("/")[1]) : Number(res.headers.get("content-length") ?? 0);
  await res.body?.cancel();
  return Response.json({ ok, status: res.status, contentType: type, bytes: Number.isFinite(bytes) ? bytes : 0, finalUrl: res.url, host: new URL(res.url).hostname });
}
