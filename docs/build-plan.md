# Pip — build plan v1.1

30 October 2026, updated 31 October with what the first build taught us (§3, §5, §12, §15). **What:** `product-brief.md`. **Why these choices:** `research.md`, `spike-results.md`. **Constraints:** `hackathon-rules.md`.
Status: approved; v1.1 records the changes made while building.

---

## 1. What we are building

Pip is a native iPhone app. You point the camera at a physical task and talk to Pip like you would to an expert standing next to you. Pip:

- **sees** the scene: Meta SAM 3.1 finds the exact objects; Muse Spark understands which one matters and what state it is in;
- **talks and points at the same time**: it speaks one short instruction while an outline, arrow, ring or warning appears on the exact part, slightly before the words that name it, and stays attached to the part in 3D as you move;
- **guides a real procedure**: compiled from a manual or instructions, or drafted when there is none and clearly labelled. The procedure is stateful, step by step, with safety gates enforced in code;
- **watches and verifies**: it notices when you have done the step, checks it on camera, and says what it saw vs. what you told it;
- **remembers correctly**: the session state, your devices and past fixes. Every fact records where it came from, and nothing is kept across sessions without your consent.

The gap we fill: no product combines (a) AI-chosen annotations anchored on the exact part and timed to speech, (b) camera-verified stateful procedures with safety gates, and (c) provenance-aware memory of your own devices. See `research.md` §4.

## 2. Architecture

```
┌─────────────────────────── iPhone 15 Pro — Pip app (Swift, SwiftUI) ───────────────────────────┐
│ ARKit session (world tracking + LiDAR depth) ──► FrameSnapshot (image, pose, intrinsics, depth) │
│ Audio engine (voice processing / echo cancellation)                                            │
│   mic ─► ASR stream ───────┐          speech PCM + character timings ◄─ Speech scheduler      │
│                            ▼                                                   ▲               │
│ Conversation engine ─► Turn builder ─► Perception client ─► Cue stream parser ─┘               │
│        ▲                     │                                   │                             │
│ Procedure runtime ◄──────────┘                                   ▼                             │
│ (state machine, safety gates, verification)       Annotation engine (anchors + 2D renderer)    │
│ Memory store (session log, long-term, consent)    Trace recorder ("How Pip sees")              │
└────────────────────────────────────┬───────────────────────────────────────────────────────────┘
                                     │ HTTPS + WSS (app token)
┌────────────────────────────────────▼───────── Cloudflare Worker (TypeScript, Hono) ────────────┐
│ /v1/chat     → Muse Spark SSE pass-through (key injected, prompt cache key)                    │
│ /v1/segment  → SAM 3.1 (prompt variants in parallel) → parse masks → polygons, boxes, scores   │
│ /v1/asr      → WebSocket relay to Meta realtime ASR (key injected)                             │
│ /v1/transcribe → batch ASR fallback   /v1/speak → ElevenLabs speech + character timings        │
│ rate limits · spend cap · request logs (no images, audio or text)                               │
└────────────────────────────────────┬───────────────────────────────────────────────────────────┘
                                     ▼
     Meta Model API: muse-spark-1.3 · sam-3.1 · muse-voice-transcribe-1.0   ·   ElevenLabs (voice only)
```

**Code layout (monorepo):**

```
ios/            XcodeGen project.yml
  PipCore/      Swift package: domain types, procedure runtime, policy, memory, cue grammar + parser,
                prompt builders, API clients, SSE parser — no UIKit/ARKit; unit-tested; also used by eval
  PipApp/       SwiftUI app: AR view, annotation renderer, audio/speech, screens
  PipCore/Sources/pipeval  macOS command-line tool: runs PipCore perception on photos → test report
worker/         Cloudflare Worker (TypeScript, Hono, @meta-sam/parser), deployed at pip.unveil.be
docs/  spikes/  eval/ (datasets: our own photos + ground truth JSON)
```

**Language choices:**
- **Swift 5 language mode.** Swift 6 strict concurrency slows iteration.
- **TypeScript only in the Worker.** The SAM parser exists only in TypeScript, and a pass-through proxy is about 150 lines.
- **No Rust** (`research.md` §1).

## 3. The perception pipeline: one "look"

v1.0 planned set-of-marks on the whole frame: SAM first, then Spark picks a numbered mark. The first build showed two limits (measured in `spike-results.md`, day 1):
- dense small targets: a keyboard gives 105 SAM instances, too many numbers for Spark to read;
- every Spark call with an image takes 3–4 s (reasoning cannot be turned off), so plan-then-speak in two calls costs 7+ s.

**v1.1: one streamed Spark call, grounded in parallel.**

1. **Speak and point by position** (`/v1/chat`, stream, `minimal`). Spark sees the frame and starts with a short sentence without a cue ("That takes two keys."). Each later cue names its target by position, kind and printed text: `[[ring at=455,830 obj="key" text="alt gr" label="1"]]`.
2. **Ground each target as soon as its tag streams in** (`Grounder`, ~1.5–3 s, in parallel with speech):
   - SAM 3.1 on an enlarged crop around the point (small objects) and on the whole frame (large objects), plus a point prompt;
   - Apple Vision text recognition on the crop: the instance under the printed text wins (words only; single characters must match exactly, because OCR misreads small symbols);
   - otherwise the instance under the point; for look-alikes that the text cannot confirm, a short Spark check on a numbered, enlarged crop picks the right one, or answers "none", and then Pip does not point.
3. **Gate the speech.** A sentence is released when its targets are grounded (or after 6 s, without the cues). The tag-free first sentence covers the grounding time, so cues are never late and never on a guess.
4. **Anchor in 3D** (`AnchoredMark`): a plane is fitted to the LiDAR points around the object (orientation), moved to the object's own median depth (position); every outline point is the intersection of its camera ray with that plane. Fallback: a camera-facing plane at the median depth.

**Measured on test photos (Mac, home connection):** first word 3.0–4.0 s after the transcript; alt gr, the 0/à/@ key, breakers 10F and 11F grounded correctly; a point three keys off is refused.

**Marks mode** (fixed SAM prompts, every instance numbered on the frame, Spark answers with `m=N`) remains for the evaluation of large objects, such as rows of breakers.

## 4. The cue language: how Pip points

**Principle:** the model chooses the **meaning**; the renderer chooses the **visuals**. The model never picks colours, sizes or coordinates (except for `locate`).

**Grammar** (inline in the streamed text, stripped before speech):

```
[[outline m=13]]                 identify one object
[[ring m=7 label="T2"]]          tiny target (screw, LED, terminal)
[[candidates m=3,4]]             look-alikes / uncertain → numbered thin outlines + spoken question
[[move m=13 dir=up|down|left|right|in|out]]      push / pull / slide / insert (straight arrow)
[[rotate m=5 dir=cw|ccw amount=quarter|half|full]] rotate (curved arrow + label)
[[place m=9]]                    dashed outline "goes here"
[[seq m=2,5,8]]                  order preview (badges: current bright, next faded)
[[danger m=11 reason="…"]]       hazard zone (red/hatched, persists until resolved)
[[offscreen m=13]]               edge wedge toward a target outside the view
[[verified m=13]]                green check (only when the runtime has camera evidence)
[[clear]]                        remove transient cues
[[state …]] [[locate …]] [[need_view reason=… hint="closer"]]   structured side channel (not drawn)
```

**Targets in v1.1** (live): instead of `m=N`, a pointing cue names its target as `at=X,Y obj="kind" text="printed|alternatives"`, e.g. `[[ring at=455,830 obj="key" text="alt gr" label="1"]]`; the app grounds it (§3) and gives it a mark number. `m=N` remains for marks mode (eval). A `ring` with a step `label` stays until the step is done, so a sequence ("hold 1, then press 2") is visible as a whole.

**Validation by the runtime, before anything is drawn:**
- every `m` must exist and have SAM confidence ≥ the threshold;
- `outline` with low confidence is downgraded to `candidates`;
- `verified` is only allowed when the runtime holds camera evidence;
- `danger` always wins over everything else;
- at most **3 marks** on screen;
- an invalid tag is dropped and recorded in the trace.

**Visual rules** (from the HCI evidence):
- **Colour has meaning:**
  - one action colour (white or cyan with a dark halo);
  - red and hatched = danger only;
  - green = verified only;
  - every colour also has a distinct shape, so it works for colour-blind users.
- **How long a cue stays:**
  - a transient "this one" fades after about 3 s;
  - the mark for the current action stays until the step is verified;
  - a danger mark stays until it is resolved.
- **Two-stage reveal:** a soft ring appears at once, then morphs into the precise mask outline. The surroundings are dimmed slightly for `outline`.

## 5. Speech and pointing in sync

- Spark's stream is cut into sentences (`CueStreamParser`). Each sentence is rendered as soon as it is queued, so the next one is ready when the current one ends.
- **Voice: ElevenLabs Flash v2.5** through the Worker's `/v1/speak` (first audio ~0.25 s; Flemish voice Sharon for Dutch, Alice for English). Meta has no text-to-speech model; ElevenLabs is the only non-Meta model and is listed as third party. The iPhone voice is the fallback.
- **Timing:** ElevenLabs returns the start time of every character; the iPhone voice returns word markers (`byteSampleOffset` is a byte offset into the audio: 4 bytes per Float32 frame, measured).
- **Cue timing:**
  - a cue tag binds to the next word in the text (to the last word if it closes the sentence);
  - the cue fires **400 ms before** that word, plus the output latency;
  - this follows the research: show the cue 300–800 ms before the noun, never after it.
- Audio plays through the same `AVAudioEngine` as the microphone, with voice processing on, so echo cancellation lets the user talk over Pip.
- **Text style** (enforced by the prompt and checked in the eval):
  - one referent and one action per sentence;
  - the "one-breath test";
  - a distinguishing feature is named for look-alikes ("the third one, labelled 10F");
  - provenance words: *I see / you told me / the manual says / I'm not sure*.
- Text captions are always on screen.

## 6. Conversation engine

- **Listening:**
  - Hands-free by default: the realtime ASR runs through the Worker relay, with `ENDPOINTING`, `languageBias: ["English","Dutch"]`, and keywords taken from the procedure's object names. Silence is sent while idle.
  - A large mute/tap-to-talk button is always visible. Push-to-talk with batch ASR is the fallback mode.
- **Barge-in:** if the user starts speaking while Pip is talking:
  - Pip stops the audio immediately and cancels pending cues;
  - it truncates its own last message to the words actually spoken, so its memory matches what the user heard;
  - it then handles the new utterance.
- **Watching mode:** after an action instruction, Pip enters `awaiting_action`.
  - Every ~2.5 s it runs a light verification look (SAM on the target box + Spark `minimal`, expecting the step's check).
  - When the expected state is seen twice in a row, Pip confirms out loud and shows `verified`.
  - It times out after 60 s with a gentle prompt.
  - Cost is about $0.006 per check; the loop is capped per session.
- **Proactive correction:** if a look shows a **critical** deviation (wrong object touched, a danger sign), Pip interrupts within one look. Minor deviations are left until the user asks or the step check fails.
- **Repair ladder** when the user is confused:
  1. re-point with a stronger cue: dim and pulse;
  2. use a different landmark;
  3. "touch the one you mean": the next look checks the user's finger;
  4. ask for a closer view;
  5. pause or escalate.

## 7. Procedures

**Source → procedure compiler** (Spark `medium`, `json_schema`, ~10–30 s once):
- **Inputs:** the user's goal, plus an optional source: photos of instruction pages taken with the camera, a PDF, or text. With no source, Spark drafts from general knowledge, the procedure is marked `unverified`, and the stricter policy applies.
- **Output** `Procedure`:
  - `objects[]`: name, description, SAM prompt variants, expected count, size;
  - `steps[]`: instruction, targets, expected visible end state, check kind (camera / user / not verifiable), cautions, source reference.
- **Validated** for referential integrity and coverage of source references.

**Runtime** (`PipCore`, deterministic):
- step states: `pending → active → awaiting_action → verifying → done(camera_verified | user_confirmed | not_verifiable)`;
- navigation: back, skip, pause and resume. Questions never change the step;
- safety gates on step entry (e.g. "power isolated and tested" before touching anything electrical);
- the model can *suggest* advancing only through `[[state …]]`; the runtime decides.

**Scene scan** at the start (Spark `medium`, ~10–20 s, with a progress UI): maps the procedure's objects onto the scene, detects a model mismatch, and reads labels and serial numbers into memory.

## 8. Memory

| Layer | Contents | Lifetime | Written by |
|---|---|---|---|
| Working context | Current step, last turns *as heard*, active cues, latest observations | One turn | Turn builder |
| Session log | Append-only events: looks, cues shown, observations, user statements, step outcomes with evidence frame, safety state with expiry | One task session; resumable on the device | Runtime only |
| Long-term ("My places & things") | Assets (make, model, location, manual), maps (e.g. panel: breaker → circuit), past fixes, preferences (language, level of detail) | Persistent, **only after the user says yes** | Runtime, from validated session facts |

**Every fact records:**
- `source` (seen / said / manual / inferred);
- `time`, `confidence` and an `evidence` frame reference.

**Rules:**
- Conflicts → ask the user.
- Safety state never carries over between sessions.
- Summaries and hand-over reports are generated **only from the log**.
- The model never writes memory directly; it proposes through `[[state]]`, and the runtime validates.

**Privacy:**
- Stored on the device only (SwiftData).
- A memory screen lets the user view, edit and delete everything.
- Only structured facts and a few chosen stills are kept, never video.
- Relevant facts are sent to the model as context per request.

## 9. Safety policy (code-enforced)

- **Task classification at the start:** `allowed`, `allowed_with_gates` or `refused`. Medical/health, live mains wiring behind covers, gas work and structural/load-bearing work are refused, with a referral to a professional.
- **Hazard watch on every look:** smoke, fire, sparks, water near electricity, burn marks, an exposed conductor, or an injury mentioned. The result is `danger` + `stop` + escalation text (electrician / 112).
- **Not visually verifiable** (voltage, torque, gas-tightness) is always said out loud. For critical values the user reads the value aloud.
- **No-source procedures:** stricter gates; Pip refuses high-risk classes.

## 10. Screens

1. **Start:** "What do you want to do?" by voice or text, plus optional "Add instructions" (scan pages / PDF / skip). Recent tasks and assets come from memory.
2. **Guide:** a full-screen AR view and Pip's companion (states: listening, looking, speaking, waiting for you, unsure, stop). There is one caption line, a small step chip ("3/7, camera-verified ✓"), and mute, back and pause buttons.
3. **Steps sheet:** the procedure with status and source per step.
4. **Memory sheet:** what Pip knows and where it came from; edit and delete.
5. **How Pip sees** (trace): per turn the transcript, SAM instances, the marked image, Spark's stream with tags, the validation decisions, and timings per model.
6. **Summary:** what was done, what was seen vs. confirmed, and what remains. It can be shared with a professional.

## 11. Evaluation

- **Three to four domains**: electrical panel, household appliance, mechanical object, lift installation, with 10–15 held-out photos each and ground truth: target box, state, label.
- **`PipEval` (macOS)** runs the same PipCore pipeline through the Worker and measures:
  - target localisation;
  - state accuracy;
  - **confident wrong pointers (target 0)**;
  - candidate / better-view rate;
  - cue-tag validity;
  - one-referent-per-sentence rate;
  - latency per stage.
- **Live measurements** on the iPhone: end-of-speech → first word; cue lead time vs. the word; anchor drift after moving 0.5 m.
- **User test:** 2–3 people on one unfamiliar task (completion, stalls, help requests). Exploratory.
- Everything goes into `docs/test-report.md`, with real numbers only.

## 12. Schedule

Weekdays corrected in v1.1 (4 November is a Wednesday). Status on Saturday 31 October, evening.

| Day | Must be true by the end of the day | Status |
|---|---|---|
| **Fri 30 Oct** | Xcode, Apple ID, iPhone in Developer Mode; plan approved | ✅ (Xcode and signing on 31 Oct) |
| **Sat 31 Oct** | Worker live at pip.unveil.be; app on the iPhone: look → **outline anchored on the right object, spoken in sync** | ✅ plus, ahead of plan: realtime ASR relay, hands-free listening, barge-in, ElevenLabs voice, grounding v1.1 |
| **Sun 1 Nov** | Procedure runtime + compiler (photos/text) + verification looks; safety policy and gates; session log | |
| **Mon 2 Nov** | Watching mode; long-term memory with consent + memory screen; trace screen ("How Pip sees") | |
| **Tue 3 Nov** | Eval sets + `pipeval` report; user test; polish; README with architecture + "Built during the hackathon". **Feature freeze 20:00** | |
| **Wed 4 Nov** | Re-sign the build; script + video (together); write-up; **submit by 18:00 CET** (deadline 21:00 ET = 03:00 CET 5 Nov) | |

**Cut order** if behind (last to cut first): long-term memory UI → watching mode → rotate/place/seq cues → compiler from PDF (photos/text stay). **Never cut:** the anchored outline + synced speech + verification + safety gates.

## 13. What we need

| Need | Status / action |
|---|---|
| Full Xcode + iOS platform | ✓ Xcode 27.2 |
| Apple ID in Xcode (free Personal Team, 7-day signing) | ✓; re-sign on 3/4 Nov; installs over the cable |
| iPhone 15 Pro: Developer Mode, trust the Mac | ✓ (iOS 26.6.1) |
| XcodeGen (`brew install xcodegen`) | I install it |
| Cloudflare: Worker on `pip.unveil.be` + secrets | ✓ live; Workers Paid ($5/month), because decoding SAM masks needs more than the free plan's 10 ms CPU |
| ElevenLabs API key (text-to-speech only) | ✓ in `.dev.vars` and as a Worker secret |
| Meta API key | ✓ in `.dev.vars` |
| Physical test objects | Electrical panel, household appliance, mechanical object, lift installation ✓ |
| 2–3 test users | Mon 3 Nov |
| Budget | ~$0.01–0.02 per turn; $150 is ample. A spend cap in the Worker |

## 14. Risks

| Risk | Mitigation |
|---|---|
| Xcode/signing setup eats Friday morning | Install tonight; smoke-test the build first thing; a PWA 2D fallback reuses the Worker if blocked by noon |
| Coordinate bugs (sensor orientation, y-flip, intrinsics scaling) | Debug overlay from day 1 (draw raw SAM boxes on the snapshot next to the anchored version) |
| Depth unreliable on glossy panels | Vision 2D tracking + plane raycast fallback; padded outlines |
| Look-alike objects | SAM + Spark agreement, `candidates` + spoken distinguishing feature, never a solid outline below threshold |
| Latency > 5 s to the first word | Speculative segmentation at speech start, prompt caching, immediate acknowledgement, `minimal` effort |
| Realtime ASR relay complexity | Batch push-to-talk works first; realtime is added on Sunday |
| Model overclaims verification | `verified` only from runtime evidence; provenance wording; eval checks it |
| Banned category "simple image analyser" | The product is the closed loop: procedure → point → act → watch → verify → remember |

## 15. Decisions

1. **Platform:** native Swift app + TypeScript Worker, no Rust. ✅ Approved.
2. **Deploy:** I deploy the Worker to `pip.unveil.be` myself (`wrangler login` on this Mac). ✅
3. **Listening:** hands-free by default, with a mute button; push-to-talk as fallback. ✅
4. **Test domains:** electrical panel, household appliance, mechanical object, lift / technical installation (Verolift). ✅ Four domains are available; the eval uses at least three.
5. **Voice:** Meta has no text-to-speech model, so Pip speaks with ElevenLabs (Flash v2.5, through the Worker); every other model is Meta's. ✅ (31 Oct)
6. **Hosting:** Cloudflare Workers Paid ($5/month) for the CPU that SAM mask decoding needs. ✅ (31 Oct)
7. **Installs:** over the USB cable (Wi-Fi debugging did not connect). ✅ (31 Oct)
