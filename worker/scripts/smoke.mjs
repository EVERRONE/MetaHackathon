// End-to-end smoke test against a running Worker, with real model calls (costs a few cents).
// Usage: PIP_URL=http://localhost:8787 PIP_APP_TOKEN=… node scripts/smoke.mjs <image.jpg> <speech.wav> [sam prompt]
import { readFileSync } from "node:fs";

const base = process.env.PIP_URL ?? "http://localhost:8787";
const token = process.env.PIP_APP_TOKEN;
const [imagePath, wavPath, prompt = "breaker"] = process.argv.slice(2);
if (!token || !imagePath || !wavPath) {
  console.error("Usage: PIP_URL=… PIP_APP_TOKEN=… node scripts/smoke.mjs <image.jpg> <speech.wav> [sam prompt]");
  process.exit(2);
}
const auth = { Authorization: `Bearer ${token}` };
let failures = 0;

async function step(name, fn) {
  const t0 = performance.now();
  try {
    const info = await fn();
    console.log(`ok   ${name.padEnd(28)} ${String(Math.round(performance.now() - t0)).padStart(6)} ms  ${info ?? ""}`);
  } catch (err) {
    failures++;
    console.log(`FAIL ${name.padEnd(28)} ${err.message}`);
  }
}

function expect(cond, message) {
  if (!cond) throw new Error(message);
}

async function ok(r) {
  if (!r.ok) throw new Error(`status ${r.status}: ${await r.text()}`);
  return r;
}

await step("health", async () => {
  const r = await fetch(`${base}/v1/health`);
  expect(r.ok, `status ${r.status}`);
  return JSON.stringify(await r.json());
});

await step("rejects missing token", async () => {
  const r = await fetch(`${base}/v1/usage`);
  expect(r.status === 401, `expected 401, got ${r.status}`);
});

await step("chat (stream)", async () => {
  const t0 = performance.now();
  const r = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "muse-spark-1.3",
      reasoning_effort: "minimal",
      stream: true,
      messages: [{ role: "user", content: "Reply with exactly: Found it. This is [[outline m=3]] the switch." }],
    }),
  });
  await ok(r);
  let text = "";
  let firstToken = null;
  let usage = null;
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of r.body) {
    buf += decoder.decode(chunk, { stream: true });
    const lines = buf.split("\n");
    buf = lines.pop();
    for (const line of lines) {
      if (!line.startsWith("data: {")) continue;
      const j = JSON.parse(line.slice(6));
      const delta = j.choices?.[0]?.delta?.content;
      if (delta) {
        firstToken ??= performance.now() - t0;
        text += delta;
      }
      if (j.usage) usage = j.usage;
    }
  }
  expect(text.includes("[[outline"), `no cue tag in: ${text}`);
  expect(usage, "no usage chunk");
  return `first token ${Math.round(firstToken)} ms · ${JSON.stringify(text)}`;
});

const image = `data:image/jpeg;base64,${readFileSync(imagePath).toString("base64")}`;
let firstInstance = null;
let size = null;

await step(`segment "${prompt}"`, async () => {
  const r = await fetch(`${base}/v1/segment`, {
    method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ image, prompts: [prompt, "switch"] }),
  });
  await ok(r);
  const j = await r.json();
  expect(j.instances.length > 0, "no instances");
  firstInstance = j.instances[0];
  size = { width: j.width, height: j.height };
  const points = j.instances.reduce((n, i) => n + i.polygons.reduce((m, p) => m + p.length / 2, 0), 0);
  const merged = j.instances.filter((i) => i.prompts.length > 1).length;
  const contains = j.instances.filter((i) => i.contains).length;
  return `${j.instances.length} instances (${merged} found by both prompts, ${contains} containing others), ${points} outline points, calls ${JSON.stringify(j.calls)}`;
});

await step("segment (box prompt)", async () => {
  expect(firstInstance, "needs the previous step");
  const r = await fetch(`${base}/v1/segment`, {
    method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ image, objects: [{ id: 7, box: firstInstance.box }], ...size }),
  });
  await ok(r);
  const j = await r.json();
  expect(j.instances.length === 1 && j.instances[0].objectId === 7, `unexpected ${JSON.stringify(j.instances.map((i) => i.objectId))}`);
  return `objectId 7 → box ${JSON.stringify(j.instances[0].box)} (prompted ${JSON.stringify(firstInstance.box)})`;
});

const wav = readFileSync(wavPath);

await step("transcribe", async () => {
  const r = await fetch(`${base}/v1/transcribe?languages=English,Dutch`, {
    method: "POST",
    headers: { ...auth, "Content-Type": "audio/wav" },
    body: wav,
  });
  await ok(r);
  const j = await r.json();
  return JSON.stringify(j.transcript ?? j);
});

await step("realtime asr relay", async () => {
  // PCM after the 44-byte header; the test files are 16 kHz mono.
  const pcm = wav.subarray(44);
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/v1/asr`, { headers: auth });
  ws.binaryType = "arraybuffer";
  const events = [];
  const done = new Promise((resolve, reject) => {
    ws.addEventListener("message", (e) => {
      if (typeof e.data !== "string") return;
      const j = JSON.parse(e.data);
      events.push(j.type ?? "ack");
      if (j.type === "error") reject(new Error(j.message));
      if (j.type === "speechComplete") resolve(j.transcript);
    });
    ws.addEventListener("close", (e) => reject(new Error(`closed ${e.code} ${e.reason}`)));
    ws.addEventListener("error", () => reject(new Error("socket error")));
  });
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve);
    ws.addEventListener("error", () => reject(new Error("could not connect")));
  });
  ws.send(JSON.stringify({ audioEncoding: "PCM_16KHZ", mode: "ENDPOINTING", partialMode: "CUMULATIVE", languageBias: ["English", "Dutch"] }));
  const frame = 16_000 * 2 * 0.08; // 80 ms
  const silence = new Uint8Array(frame);
  const timer = (async () => {
    for (let o = 0; o < pcm.length; o += frame) {
      ws.send(pcm.subarray(o, o + frame));
      await new Promise((r) => setTimeout(r, 80));
    }
    // Trailing silence lets endpointing close the turn.
    for (let i = 0; i < 25 && ws.readyState === WebSocket.OPEN; i++) {
      ws.send(silence);
      await new Promise((r) => setTimeout(r, 80));
    }
  })();
  const transcript = await Promise.race([done, new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout; events ${events.join(",")}`)), 20_000))]);
  await timer;
  ws.send(JSON.stringify({ type: "endStream" }));
  ws.close(1000);
  return `${JSON.stringify(transcript)} · events ${[...new Set(events)].join(",")}`;
});

await step("usage", async () => {
  const r = await fetch(`${base}/v1/usage`, { headers: auth });
  expect(r.ok, `status ${r.status}`);
  const j = await r.json();
  return `today $${j.today.toFixed(4)}, total $${j.total.toFixed(4)}`;
});

process.exit(failures ? 1 : 0);
