import { Hono, type Context, type Next } from "hono";
import { bodyLimit } from "hono/body-limit";
import { relayAsr, transcribe } from "./asr";
import { chat } from "./chat";
import { asrCost, samCost } from "./cost";
import { HttpError } from "./http";
import { meter } from "./meter";
import { MAX_PROMPTS, segment, type SegmentRequest } from "./segment";
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
  return (usd: number) => c.executionCtx.waitUntil(meter(c.env).add(usd));
}

app.use("*", async (c, next) => {
  const t0 = Date.now();
  await next();
  // Metadata only: never images, audio or text.
  console.log(JSON.stringify({ method: c.req.method, path: c.req.path, status: c.res.status, ms: Date.now() - t0 }));
});

app.get("/", (c) => c.text("Pip API. See github.com/EVERRONE/MetaHackathon\n"));
app.get("/v1/health", (c) => c.json({ ok: true, service: "pip", version: VERSION }));

app.use("/v1/*", async (c: Context<AppEnv>, next: Next) => {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!(await validToken(token, c.env.PIP_APP_TOKEN))) throw new HttpError(401, "unauthorized", "Missing or invalid app token");

  const { success } = await c.env.LIMITER.limit({ key: "app" });
  if (!success) throw new HttpError(429, "rate_limited", "Too many requests; slow down");

  const spend = await meter(c.env).status();
  if (spend.today >= Number(c.env.DAILY_CAP_USD) || spend.total >= Number(c.env.TOTAL_CAP_USD)) {
    throw new HttpError(402, "spend_cap", `Spend cap reached (today $${spend.today.toFixed(2)}, total $${spend.total.toFixed(2)})`);
  }
  await next();
});

app.get("/v1/usage", async (c) => c.json(await meter(c.env).status()));

app.post("/v1/chat", bodyLimit({ maxSize: 24 * MB }), async (c) => {
  const raw = await c.req.text();
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "invalid_json", "Body must be JSON");
  }
  return chat(c.env.MODEL_API_KEY, body, raw.length, charger(c));
});

app.post("/v1/segment", bodyLimit({ maxSize: 12 * MB }), async (c) => {
  const req = await c.req.json<SegmentRequest>().catch(() => {
    throw new HttpError(400, "invalid_json", "Body must be JSON");
  });
  if (typeof req.image !== "string" || req.image.length < 100) throw new HttpError(400, "invalid_request", "image is required");
  const prompts = (req.prompts ?? []).filter((p) => typeof p === "string" && p.trim().length > 0);
  if (prompts.length > MAX_PROMPTS) throw new HttpError(400, "invalid_request", `At most ${MAX_PROMPTS} prompts`);
  if (prompts.some((p) => p.length > 80)) throw new HttpError(400, "invalid_request", "Prompts are short noun phrases");
  const objects = req.objects ?? [];
  if (objects.length > 16) throw new HttpError(400, "invalid_request", "At most 16 objects");
  if (objects.length && !(Number(req.width) > 0 && Number(req.height) > 0)) {
    throw new HttpError(400, "invalid_request", "width and height are required with objects");
  }
  if (!prompts.length && !objects.length) throw new HttpError(400, "invalid_request", "Give prompts or objects");

  const calls = prompts.length + (objects.length ? 1 : 0);
  try {
    return c.json(await segment(c.env.MODEL_API_KEY, { ...req, prompts, objects }));
  } finally {
    charger(c)(samCost(calls));
  }
});

app.post("/v1/transcribe", bodyLimit({ maxSize: 32 * MB }), async (c) => {
  const wav = await c.req.arrayBuffer();
  const list = (q: string | undefined) => q?.split(",").map((s) => s.trim()).filter(Boolean);
  const { json, seconds } = await transcribe(c.env.MODEL_API_KEY, wav, {
    mode: c.req.query("mode"),
    languageBias: list(c.req.query("languages")),
    keywords: list(c.req.query("keywords")),
  });
  charger(c)(asrCost(seconds));
  return c.json(json as object);
});

app.post("/v1/speak", bodyLimit({ maxSize: 64 * 1024 }), async (c) => {
  const req = await c.req.json<SpeakRequest>().catch(() => {
    throw new HttpError(400, "invalid_json", "Body must be JSON");
  });
  return speak(c.env.ELEVENLABS_API_KEY, req, charger(c));
});

app.get("/v1/asr", (c) => {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") throw new HttpError(426, "upgrade_required", "Expected a WebSocket upgrade");
  return relayAsr(c.env.MODEL_API_KEY, (seconds) => charger(c)(asrCost(seconds)));
});

app.notFound(() => Response.json({ error: { code: "not_found", message: "No such route" } }, { status: 404 }));

app.onError((err) => {
  if (err instanceof HttpError) {
    return Response.json({ error: { code: err.code, message: err.message } }, { status: err.status });
  }
  if (err instanceof UpstreamError) {
    const status = err.status >= 500 ? 502 : err.status;
    return Response.json({ error: { code: `upstream_${err.service}`, message: err.message, upstreamStatus: err.status } }, { status });
  }
  console.error(JSON.stringify({ error: String(err), stack: (err as Error).stack?.slice(0, 500) }));
  return Response.json({ error: { code: "internal", message: "Internal error" } }, { status: 500 });
});

export default app satisfies ExportedHandler<Env>;
