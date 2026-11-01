import { Hono, type Context, type Next } from "hono";
import { bodyLimit } from "hono/body-limit";
import { HTTPException } from "hono/http-exception";
import { relayAsr, transcribe, wavDurationSeconds } from "./asr";
import { chat, type Reserve } from "./chat";
import { asrCost, samCost } from "./cost";
import { HttpError } from "./http";
import { meter } from "./meter";
import { ObjectPromptError } from "@meta-sam/parser";
import { MAX_PROMPTS, segment, type SegmentRequest } from "./segment";
import { checkSource, responses } from "./responses";
import { speak, type SpeakRequest } from "./speak";
import { UpstreamError } from "./upstream";

export { Meter } from "./meter";

const VERSION = "0.1.0";
const MB = 1024 * 1024;

type AppEnv = { Bindings: Env };
const app = new Hono<AppEnv>();

async function sha256(s: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
}

/** Constant-time check of the app token (hashing first makes the lengths equal). */
async function validToken(given: string, expected: string): Promise<boolean> {
  if (!expected) return false;
  const [a, b] = await Promise.all([sha256(given), sha256(expected)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

function charger(c: Context<AppEnv>) {
  return (usd: number, calls = 1) => c.executionCtx.waitUntil(meter(c.env).add(usd, calls));
}

/**
 * Reserves the most a call can cost before it is made (refused at the cap, see Meter.reserve);
 * the returned function settles it with the real cost, once.
 */
function reserver(c: Context<AppEnv>): Reserve {
  return async (usd: number) => {
    if (!(await meter(c.env).reserve(usd))) throw new HttpError(402, "spend_cap", "Spend cap reached");
    let settled = false;
    return (actual: number) => {
      if (settled) return;
      settled = true;
      const delta = actual - usd;
      if (Number.isFinite(delta) && delta !== 0) c.executionCtx.waitUntil(meter(c.env).add(delta, 0));
    };
  };
}

app.use("*", async (c, next) => {
  const t0 = Date.now();
  await next();
  // Metadata only: never images, audio or text.
  console.log(JSON.stringify({ method: c.req.method, path: c.req.path, status: c.res.status, ms: Date.now() - t0 }));
});

app.get("/", (c) => c.text("Pip API. See github.com/EVERRONE/MetaHackathon\n"));
app.get("/v1/health", (c) => c.json({ ok: true, service: "pip", version: VERSION }));

async function overCap(env: Env): Promise<{ over: boolean; today: number; total: number }> {
  const spend = await meter(env).status();
  return { ...spend, over: spend.today >= Number(env.DAILY_CAP_USD) || spend.total >= Number(env.TOTAL_CAP_USD) };
}

app.use("/v1/*", async (c: Context<AppEnv>, next: Next) => {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!(await validToken(token, c.env.PIP_APP_TOKEN))) throw new HttpError(401, "unauthorized", "Missing or invalid app token");

  const { success } = await c.env.LIMITER.limit({ key: "app" });
  if (!success) throw new HttpError(429, "rate_limited", "Too many requests; slow down");

  // The app can always read its own spend, also once the cap is reached.
  if (c.req.path !== "/v1/usage") {
    const spend = await overCap(c.env);
    if (spend.over) {
      throw new HttpError(402, "spend_cap", `Spend cap reached (today $${spend.today.toFixed(2)}, total $${spend.total.toFixed(2)})`);
    }
  }
  await next();
});

/** Parses a JSON object body; anything else is a 400. */
async function jsonObject<T>(c: Context<AppEnv>): Promise<T> {
  const body = await c.req.json<unknown>().catch(() => {
    throw new HttpError(400, "invalid_json", "Body must be JSON");
  });
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw new HttpError(400, "invalid_json", "Body must be a JSON object");
  return body as T;
}

app.get("/v1/usage", async (c) => c.json(await meter(c.env).status()));

app.post("/v1/chat", bodyLimit({ maxSize: 24 * MB }), async (c) => {
  const raw = await c.req.text();
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "invalid_json", "Body must be JSON");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw new HttpError(400, "invalid_json", "Body must be a JSON object");
  // Inline images are priced per image in the estimates, not as text.
  const textBytes = raw.replace(/data:image\/[^"]+/g, "").length;
  return chat(c.env.MODEL_API_KEY, body as Record<string, unknown>, textBytes, reserver(c));
});

app.post("/v1/segment", bodyLimit({ maxSize: 12 * MB }), async (c) => {
  const req = await jsonObject<SegmentRequest>(c);
  if (typeof req.image !== "string" || req.image.length < 100) throw new HttpError(400, "invalid_request", "image is required");
  if (req.prompts !== undefined && !Array.isArray(req.prompts)) throw new HttpError(400, "invalid_request", "prompts must be an array");
  if (req.objects !== undefined && !Array.isArray(req.objects)) throw new HttpError(400, "invalid_request", "objects must be an array");
  const prompts = (req.prompts ?? []).filter((p) => typeof p === "string" && p.trim().length > 0);
  if (prompts.length > MAX_PROMPTS) throw new HttpError(400, "invalid_request", `At most ${MAX_PROMPTS} prompts`);
  if (prompts.some((p) => p.length > 80)) throw new HttpError(400, "invalid_request", "Prompts are short noun phrases");
  const objects = req.objects ?? [];
  if (objects.length > 16) throw new HttpError(400, "invalid_request", "At most 16 objects");
  if (objects.length && !(typeof req.width === "number" && typeof req.height === "number" && req.width > 0 && req.height > 0)) {
    throw new HttpError(400, "invalid_request", "width and height (numbers) are required with objects");
  }
  if (!prompts.length && !objects.length) throw new HttpError(400, "invalid_request", "Give prompts or objects");
  validateObjects(objects);

  // One SAM call per concept prompt, one for all the objects.
  const settle = await reserver(c)(samCost(prompts.length + (objects.length ? 1 : 0)));
  try {
    return c.json(await segment(c.env.MODEL_API_KEY, { ...req, prompts, objects }, (calls) => settle(samCost(calls))));
  } catch (err) {
    settle(0);
    if (err instanceof ObjectPromptError) throw new HttpError(400, `invalid_objects_${err.code}`, err.message);
    throw err;
  }
});

app.post("/v1/responses", bodyLimit({ maxSize: 24 * MB }), async (c) => {
  return responses(c.env.MODEL_API_KEY, await jsonObject<Record<string, unknown>>(c), reserver(c));
});

app.post("/v1/source-check", bodyLimit({ maxSize: 4096 }), async (c) => {
  const body = await jsonObject<{ url?: unknown }>(c);
  return checkSource(body.url);
});

app.post("/v1/transcribe", bodyLimit({ maxSize: 32 * MB }), async (c) => {
  const wav = await c.req.arrayBuffer();
  const list = (q: string | undefined) => q?.split(",").map((s) => s.trim()).filter(Boolean);
  // Its length is known before the call: reserved then (a dropped request still counts).
  const settle = await reserver(c)(asrCost(wavDurationSeconds(wav) ?? 0));
  try {
    const { json, seconds } = await transcribe(c.env.MODEL_API_KEY, wav, {
      mode: c.req.query("mode"),
      languageBias: list(c.req.query("languages")),
      keywords: list(c.req.query("keywords")),
    });
    settle(asrCost(seconds));
    return c.json(json as object);
  } catch (err) {
    settle(0);
    throw err;
  }
});

app.post("/v1/speak", bodyLimit({ maxSize: 64 * 1024 }), async (c) => {
  return speak(c.env.ELEVENLABS_API_KEY, await jsonObject<SpeakRequest>(c), reserver(c));
});

/** Object prompts as the app sends them: an id, a box or a few points, numbers only. */
function validateObjects(objects: unknown[]): void {
  const num = (v: unknown) => typeof v === "number" && Number.isFinite(v);
  for (const o of objects as { id?: unknown; box?: unknown; points?: unknown }[]) {
    if (typeof o !== "object" || o === null || !Number.isInteger(o.id)) throw new HttpError(400, "invalid_request", "Each object needs an integer id");
    if (o.box !== undefined && !(Array.isArray(o.box) && o.box.length === 4 && o.box.every(num))) {
      throw new HttpError(400, "invalid_request", "box is [left, top, right, bottom]");
    }
    if (o.points !== undefined) {
      const pts = o.points as { x?: unknown; y?: unknown; negative?: unknown }[];
      if (!Array.isArray(pts) || pts.length > 8 || pts.some((p) => typeof p !== "object" || p === null || !num(p.x) || !num(p.y))) {
        throw new HttpError(400, "invalid_request", "points are at most 8 {x, y}");
      }
    }
    if (o.box === undefined && o.points === undefined) throw new HttpError(400, "invalid_request", "Each object needs a box or points");
  }
}

app.get("/v1/asr", (c) => {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") throw new HttpError(426, "upgrade_required", "Expected a WebSocket upgrade");
  return relayAsr(c.env.MODEL_API_KEY, {
    charge: (seconds) => charger(c)(asrCost(seconds)),
    overCap: async () => (await overCap(c.env)).over,
  });
});

app.notFound(() => Response.json({ error: { code: "not_found", message: "No such route" } }, { status: 404 }));

/** Upstream error text never carries a key, and auth or server failures upstream say no more than that. */
function upstreamMessage(err: UpstreamError, env: Env): string {
  if (err.status === 401 || err.status === 403) return `The ${err.service} service refused the server's credentials`;
  if (err.status >= 500) return `The ${err.service} service failed (HTTP ${err.status})`;
  let message = err.message;
  for (const secret of [env.MODEL_API_KEY, env.ELEVENLABS_API_KEY, env.PIP_APP_TOKEN]) {
    if (secret && secret.length >= 8) message = message.split(secret).join("…");
  }
  return message.slice(0, 300);
}

app.onError((err, c) => {
  if (err instanceof HttpError) {
    return Response.json({ error: { code: err.code, message: err.message } }, { status: err.status });
  }
  if (err instanceof HTTPException) {
    // Hono's own errors, e.g. a body over the route's limit (413).
    return Response.json({ error: { code: err.status === 413 ? "too_large" : "invalid_request", message: err.message || "Request rejected" } }, { status: err.status });
  }
  if (err instanceof UpstreamError) {
    if (err.status === 401 || err.status === 403 || err.status >= 500) console.error(JSON.stringify({ upstream: err.service, status: err.status, error: err.message.slice(0, 300) }));
    return Response.json({ error: { code: `upstream_${err.service}`, message: upstreamMessage(err, c.env), upstreamStatus: err.status } }, { status: err.appStatus });
  }
  console.error(JSON.stringify({ error: String(err), stack: (err as Error).stack?.slice(0, 500) }));
  return Response.json({ error: { code: "internal", message: "Internal error" } }, { status: 500 });
});

export default app satisfies ExportedHandler<Env>;
