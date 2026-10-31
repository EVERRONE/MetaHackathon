// Checks whether realtime transcription ends turns in a given mode, through the live relay.
// Streams a WAV (16 kHz mono 16-bit) four times in real time with 6 s of silence in between and
// prints every event except audio progress. A healthy mode shows speechStart → speechComplete
// per turn; diarization should also show speaker labels.
// Usage: PIP_APP_TOKEN=… MODE=DIARIZATION|ENDPOINTING node scripts/asr-modes.mjs <speech.wav> [seconds]
import { readFileSync } from "node:fs";

const [wavPath, secs = "35"] = process.argv.slice(2);
const mode = process.env.MODE ?? "ENDPOINTING";
const base = (process.env.PIP_URL ?? "https://pip.unveil.be").replace(/^http/, "ws");
if (!process.env.PIP_APP_TOKEN || !wavPath) {
  console.error("Usage: PIP_APP_TOKEN=… MODE=DIARIZATION|ENDPOINTING node scripts/asr-modes.mjs <speech.wav> [seconds]");
  process.exit(2);
}
const pcm = readFileSync(wavPath).subarray(44);
const ws = new WebSocket(`${base}/v1/asr`, { headers: { Authorization: `Bearer ${process.env.PIP_APP_TOKEN}` } });
ws.binaryType = "arraybuffer";
const t0 = Date.now();
const t = () => ((Date.now() - t0) / 1000).toFixed(1).padStart(5);
let turns = 0;
ws.onopen = () => ws.send(JSON.stringify({ audioEncoding: "PCM_16KHZ", mode, partialMode: "CUMULATIVE", languageBias: ["Dutch", "English"] }));
ws.onmessage = (e) => {
  const s = typeof e.data === "string" ? e.data : "(binary)";
  let j = {};
  try { j = JSON.parse(s); } catch {}
  if (j.type === "audioProgress") return;
  if (j.type === "speechComplete") turns++;
  console.log(t(), s.slice(0, 180));
};
ws.onclose = (e) => {
  console.log(t(), "closed", e.code, e.reason, `· ${turns} turns ended in ${mode}`);
  process.exit(turns > 0 ? 0 : 1);
};
ws.onerror = (e) => console.log(t(), "error", e.message);

const chunk = 640; // 20 ms
const silence = Buffer.alloc(chunk);
const schedule = [];
for (let k = 0; k < 4; k++) {
  for (let o = 0; o < pcm.length; o += chunk) schedule.push(pcm.subarray(o, o + chunk));
  for (let i = 0; i < 300; i++) schedule.push(silence);
}
let i = 0;
const timer = setInterval(() => {
  if (ws.readyState !== 1) return;
  if (i < schedule.length && (Date.now() - t0) / 1000 < Number(secs)) {
    ws.send(schedule[i++]);
  } else {
    clearInterval(timer);
    ws.send(JSON.stringify({ type: "endStream" }));
  }
}, 20);
