import type { Reserve } from "./chat";
import { inputRate, sparkCost, type ChatUsage } from "./cost";
import { HttpError } from "./http";
import { META_API, UpstreamError } from "./upstream";

// The Responses API is used for two things the chat route cannot do: web search (finding a
// product's official manual) and reading a PDF from its URL.
const ALLOWED_MODELS = new Set(["muse-spark-1.3", "muse-wonder-1.0"]);
const ALLOWED_KEYS = new Set(["model", "input", "instructions", "tools", "tool_choice", "reasoning", "text", "max_output_tokens", "temperature", "store", "stream"]);
const ALLOWED_EFFORTS = new Set(["minimal", "low", "medium"]);
const MAX_OUTPUT_TOKENS = 16_000;
const MAX_IMAGES = 16;
const MAX_FILES = 2;
const USD_PER_SEARCH = 2.5 / 1000;
/** Up-front estimates, charged before the call so a dropped request still counts. */
const TOKENS_PER_IMAGE = 1_600;
const TOKENS_PER_FILE = 20_000;
const SEARCHES_ALLOWANCE = 2;

interface ResponsesUsage {
  input_tokens?: number;
  output_tokens?: number;
  input_tokens_details?: { cached_tokens?: number } | null;
}

type Part = { type?: unknown; text?: unknown; image_url?: unknown; file_url?: unknown };

/** Counts what the request sends, checking every part on the way. */
function checkInput(input: unknown): { images: number; files: number } {
  const counts = { images: 0, files: 0 };
  if (typeof input === "string") return counts;
  if (!Array.isArray(input)) throw new HttpError(400, "invalid_request", "input must be a string or an array of messages");
  for (const item of input as { role?: unknown; content?: unknown }[]) {
    if (typeof item !== "object" || item === null || typeof item.role !== "string") throw new HttpError(400, "invalid_request", "Each input item is a message with a role");
    if (typeof item.content === "string") continue;
    if (!Array.isArray(item.content)) throw new HttpError(400, "invalid_request", "content must be a string or an array of parts");
    for (const part of item.content as Part[]) {
      const keys = typeof part === "object" && part !== null ? Object.keys(part) : [];
      switch (part?.type) {
        case "input_text":
          if (typeof part.text !== "string" || keys.some((k) => k !== "type" && k !== "text")) throw new HttpError(400, "invalid_request", "input_text takes text only");
          break;
        case "input_image":
          // Inline images only: no links for Meta's servers to fetch.
          if (typeof part.image_url !== "string" || !part.image_url.startsWith("data:image/") || keys.some((k) => !["type", "image_url", "detail"].includes(k))) {
            throw new HttpError(400, "invalid_request", "input_image must be an inline data:image URL");
          }
          counts.images += 1;
          break;
        case "input_file": {
          // Files by public https link only (Meta's servers fetch it), never ids of files stored
          // in the account.
          let url: URL | null = null;
          try {
            url = typeof part.file_url === "string" ? new URL(part.file_url) : null;
          } catch {
            url = null;
          }
          if (!url || !publicHttps(url) || keys.some((k) => k !== "type" && k !== "file_url")) {
            throw new HttpError(400, "invalid_request", "input_file takes a public https file_url only");
          }
          counts.files += 1;
          break;
        }
        default:
          throw new HttpError(400, "invalid_request", "Allowed parts: input_text, input_image, input_file");
      }
    }
  }
  if (counts.images > MAX_IMAGES || counts.files > MAX_FILES) throw new HttpError(400, "invalid_request", `At most ${MAX_IMAGES} images and ${MAX_FILES} files`);
  return counts;
}

/** Only web search may be used as a tool, only known fields pass, and outputs are bounded. */
export function validate(body: Record<string, unknown>): { images: number; files: number; searches: boolean } {
  if (typeof body.model !== "string" || !ALLOWED_MODELS.has(body.model)) {
    throw new HttpError(400, "model_not_allowed", `Allowed models: ${[...ALLOWED_MODELS].join(", ")}`);
  }
  const unknown = Object.keys(body).filter((k) => !ALLOWED_KEYS.has(k));
  if (unknown.length) throw new HttpError(400, "invalid_request", `Unsupported fields: ${unknown.join(", ")}`);
  if (body.stream !== undefined && body.stream !== false) throw new HttpError(400, "invalid_request", "Streaming is not supported on this route");
  if (body.tools !== undefined) {
    if (!Array.isArray(body.tools) || body.tools.length > 1 || body.tools.some((t) => typeof t !== "object" || t === null || (t as { type?: unknown }).type !== "web_search")) {
      throw new HttpError(400, "invalid_request", "Only the web_search tool is allowed");
    }
  }
  if (body.reasoning !== undefined) {
    const r = body.reasoning as { effort?: unknown };
    if (typeof r !== "object" || r === null || Object.keys(r).some((k) => k !== "effort") || !ALLOWED_EFFORTS.has(r.effort as string)) {
      throw new HttpError(400, "invalid_request", `reasoning.effort must be one of ${[...ALLOWED_EFFORTS].join(", ")}`);
    }
  }
  if (body.max_output_tokens !== undefined && (typeof body.max_output_tokens !== "number" || !(body.max_output_tokens > 0))) {
    throw new HttpError(400, "invalid_request", "max_output_tokens must be a positive number");
  }
  // Always bounded: without a limit the model's own would apply.
  body.max_output_tokens = Math.min(Math.floor((body.max_output_tokens as number | undefined) ?? MAX_OUTPUT_TOKENS), MAX_OUTPUT_TOKENS);
  return { ...checkInput(body.input), searches: Array.isArray(body.tools) && body.tools.length > 0 };
}

export async function responses(apiKey: string, body: Record<string, unknown>, reserve: Reserve): Promise<Response> {
  const counts = validate(body);
  body.store = false;
  const model = body.model as string;
  // The most the call can cost (its input, its full output, an allowance of searches) is reserved
  // first and settled once the usage is known: a request the client drops still counts.
  const text = JSON.stringify(body).replace(/data:image\/[^"]+/g, "");
  const input = (text.length / 4 + counts.images * TOKENS_PER_IMAGE + counts.files * TOKENS_PER_FILE) * inputRate(model);
  const searchAllowance = counts.searches ? SEARCHES_ALLOWANCE * USD_PER_SEARCH : 0;
  const reserved = input + sparkCost({ completion_tokens: body.max_output_tokens as number }, model) + searchAllowance;
  const settle = await reserve(reserved);
  let res: Response;
  try {
    res = await fetch(`${META_API}/responses`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (err) {
    settle(0);
    throw err;
  }
  if (!res.ok) {
    settle(0);
    throw await UpstreamError.from(res, "responses");
  }
  const json = (await res.json()) as { usage?: ResponsesUsage; output?: { type?: string }[] };
  const searches = (json.output ?? []).filter((o) => o.type === "web_search_call").length;
  if (json.usage) {
    const u = json.usage;
    const usage: ChatUsage = {
      prompt_tokens: u.input_tokens ?? 0,
      completion_tokens: u.output_tokens ?? 0,
      prompt_tokens_details: { cached_tokens: u.input_tokens_details?.cached_tokens ?? 0 },
    };
    settle(sparkCost(usage, model) + searches * USD_PER_SEARCH);
  } else {
    // No usage: the reservation stands, plus the searches beyond the allowance.
    settle(reserved + Math.max(0, searches - SEARCHES_ALLOWANCE) * USD_PER_SEARCH);
  }
  return Response.json(json);
}

// MARK: Source check

/** Hosts a link may never point at: local names, private zones and this Worker's own zone. */
const BLOCKED_SUFFIXES = [".local", ".internal", ".localhost", ".lan", ".home", ".arpa", ".corp", ".intranet", ".unveil.be"];
/** DNS names that resolve to any address written in them. */
const WILDCARD_DNS = [".nip.io", ".sslip.io", ".xip.io", ".localtest.me", ".lvh.me"];

/** A public https site by name: no IP literals, credentials, odd ports or local names. */
export function publicHttps(u: URL): boolean {
  if (u.protocol !== "https:" || u.username || u.password || (u.port !== "" && u.port !== "443")) return false;
  const host = u.hostname.toLowerCase().replace(/\.+$/, "");
  // IPv6 literals keep their brackets in `hostname`; IPv4 ones (also written as decimal or hex)
  // are normalised to dotted form by the URL parser.
  if (host.includes("[") || host.includes(":") || /^[\d.]+$/.test(host)) return false;
  if (!host.includes(".") || host === "localhost" || host === "unveil.be") return false;
  // The zone itself too ("localtest.me" resolves to 127.0.0.1 like its subdomains). Names that
  // resolve to private addresses anyway are stopped by Cloudflare: a Worker's fetch cannot reach
  // private ranges; this filter is the first line, not the only one.
  const inZone = (s: string) => host === s.slice(1) || host.endsWith(s);
  if (BLOCKED_SUFFIXES.some(inZone) || WILDCARD_DNS.some(inZone)) return false;
  // A name with an address inside it ("10.0.0.1.example.com").
  if (/(^|\.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(\.|$)/.test(host)) return false;
  return true;
}

const MAX_HOPS = 4;

/**
 * Checks that a document link really exists before Pip relies on it: a public https URL that
 * answers 200 with a PDF or a web page. Models can produce links that look right but do not
 * exist. Redirects are followed by hand so every hop is checked again.
 */
export async function checkSource(url: unknown): Promise<Response> {
  if (typeof url !== "string" || url.length > 2048) throw new HttpError(400, "invalid_request", "url must be an https link");
  let current: URL;
  try {
    current = new URL(url);
  } catch {
    return Response.json({ ok: false, pdf: false, reason: "not a valid link" });
  }
  for (let hop = 0; hop <= MAX_HOPS; hop++) {
    if (!publicHttps(current)) return Response.json({ ok: false, pdf: false, reason: "not a public https link" });
    let res: Response;
    try {
      res = await fetch(current.toString(), {
        method: "GET",
        headers: { Range: "bytes=0-1023", "User-Agent": "Mozilla/5.0 (Pip manual check)" },
        redirect: "manual",
        signal: AbortSignal.timeout(8000),
      });
    } catch {
      return Response.json({ ok: false, pdf: false, reason: "unreachable" });
    }
    if ([301, 302, 303, 307, 308].includes(res.status)) {
      const location = res.headers.get("location");
      await res.body?.cancel();
      try {
        if (!location) throw new Error("no location");
        current = new URL(location, current);
      } catch {
        return Response.json({ ok: false, pdf: false, reason: "bad redirect" });
      }
      continue;
    }
    const type = res.headers.get("content-type") ?? "";
    const answered = res.status === 200 || res.status === 206;
    const pdf = answered && type.includes("pdf");
    const ok = pdf || (answered && type.includes("html"));
    const range = res.headers.get("content-range");
    const bytes = range ? Number(range.split("/")[1]) : Number(res.headers.get("content-length") ?? 0);
    await res.body?.cancel();
    return Response.json({ ok, pdf, status: res.status, contentType: type, bytes: Number.isFinite(bytes) ? bytes : 0, finalUrl: current.toString(), host: current.hostname });
  }
  return Response.json({ ok: false, pdf: false, reason: "too many redirects" });
}
