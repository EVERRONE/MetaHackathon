# Pip — technical build plan

**Pip** (Personal Interactive Partner): a visual AI companion that looks along with you, points at the right thing, and guides you through a physical task one step at a time.

Version 0.2 (draft), 30 October 2026. Companion to `productdefinitie-visuele-taakbegeleider.md` (product definition, Dutch).
This plan covers the technical build for the Meta Global AI Developer Hackathon. Items marked **OPEN** still need a decision.

## 1. What we deliver

1. **Pip on iPhone**, live at `pip.unveil.be`. You point the camera, ask a question by voice, and Pip highlights the exact part, says what to do, and tracks your progress. It works on fresh camera frames, not on scripted answers.
2. **Overlays that stay on the object.** When you move the phone, the highlight stays on the part. This is the depth-aware anchoring that will later drive the glasses view.
3. **Pip for Meta Ray-Ban Display**: a glasses heads-up view built as an official Ray-Ban Display web app. It is demonstrated in Meta's own Display Simulator and labelled as a simulation.
4. **"How Pip sees"**: a live trace of the three Meta models working together, as a panel in the app and as a scene in the demo video.
5. **Evidence**: a test report with measured accuracy, latency and a small user test.
6. **Submission package**: a public repo with an English README and architecture diagram, a demo video of about 3 minutes, and the write-up.

## 2. Hackathon constraints

| Item | Value |
|---|---|
| Track / theme | Indie Developer ("creativity, technical ambition, and whether it works") / Build for Your World |
| Submission deadline | 4 Nov 2026, 21:00 ET = **5 Nov 2026, 03:00 CET**. Internal target: **4 Nov, 18:00 CET** |
| Judging | 4–8 Nov, live finals, winners 9 Nov |
| Budget | $150 Meta Model API credits (plus partner credits: Modal, Baseten, Fireworks) |

Judging weights reported by several public sources: **Impact 30%**, **creative use of Meta AI tooling 25%**, **demo, live + video, 25%**, **technical depth 20%**. The official rules are not visible on the public event page.
**OPEN:** copy the rules and the submission form from the participant dashboard or Discord. We need the video length, whether a public URL is required, the repo rules, and the policy on pre-existing code.

## 3. Model capability check

What the official documentation says, and what we still have to prove on our own object in the day-1 spike.

| Need | Model | Documented capability | Verdict / what we test |
|---|---|---|---|
| Understand the question, the scene and the task; choose the next action | **Muse Spark 1.3** (`muse-spark-1.3`) | Multimodal input (image, video, audio, PDF), 1M context, reasoning effort levels, JSON-schema structured output combined with images, up to 50 images per request | Strong fit. To test: latency at low effort, and quality in English and Dutch |
| Find the part in the frame | **Muse Spark 1.3** grounding | Returns boxes and points on a 0–1000 grid, and counts by pointing | A good fit for the semantics, for example "the long panel with three holes". Box precision is not pixel-exact. To test: hit rate on our parts |
| Precise outline of the part | **SAM 3.1** (`sam-3.1`) | Text noun-phrase, box and point prompts on images and video. Returns pixel boxes and masks with confidence. 3,000 RPM, $2.50 per 1,000 images | Strong fit for refining a box into a mask. Weak spot: look-alike hardware such as dowels and screws, so the semantic choice stays with Spark. To test: mask quality, plus the text prompt per part |
| Voice input | **Muse Voice Transcribe** (`muse-voice-transcribe-1.0`) | Recordings through `/v1/asr/transcribe`, WAV only, up to 10 minutes. Also a realtime WebSocket. Dutch is supported | Fit. Safari records AAC, so we encode WAV ourselves. To test: Dutch accuracy and latency |
| Distance to the part | No hosted depth model in the Meta Model API | Muse Spark can estimate it from the image; SAM 3D Objects (open weights) includes depth, but would have to be self-hosted | Primary: **geometry from known part dimensions** (section 5). Backup: the Spark estimate. SAM 3D on Modal only as an optional experiment |
| Speech output | — | No Meta text-to-speech model. Browser `speechSynthesis` works on iPhone and on Ray-Ban Display | Fit |
| Companion visuals | **Muse Image** (`muse-image-1.0`) | Image generation, $0.01 per image | Optional: Pip's character states. No generated assembly images |

Conclusion: the hosted models cover everything we need for v1, except metric depth, which we solve with geometry. The real uncertainty is quality on *our* parts and latency. Day 1 is a measured go/no-go on exactly that.

## 4. Glasses: what is possible today

| Device | Display | Camera for developers | World-locked AR | Usable now |
|---|---|---|---|---|
| **Meta Ray-Ban Display** (newest Meta glasses with a display) | 600×600 additive display in one lens, small field of view, head-locked | Not in web apps. The native iOS/Android **Device Access Toolkit** streams the glasses camera to a phone app, but cannot draw on the display | No SLAM; web apps only get device orientation (IMU) | Yes: web apps + the official **Display Simulator** (Chrome extension with a live webcam background) + the `meta/meta-wearables-webapp` AI toolkit |
| Meta VR Glasses (announced at Connect 2026) | 70×66° per eye, Quest OS | Through the Quest platform SDKs | Yes, on the Quest platform | Ships spring 2027. SDKs and WebXR exist, but no hardware |
| iPhone 15 Pro (Safari) | Phone screen | Yes (getUserMedia) | No WebXR in iOS Safari, and LiDAR is not reachable from the web | Our test device |

The honest conclusion is that no Meta glasses available today can pin a graphic exactly onto a real object. Ray-Ban Display can still point visually, in two ways:
- show the analysed frame with the outlined part as a small heads-up card;
- show a direction cue ("look down-left") that turns into a marker once the part is inside the display area.

Architecture for real glasses:
1. A phone app with the Device Access Toolkit sends glasses camera frames to Pip's server.
2. Pip's Ray-Ban Display web app shows the guidance on the glasses.
3. Both connect to the same session.

For the hackathon, the iPhone camera stands in for the glasses camera, and the glasses web app runs in Meta's simulator. We present this explicitly as a simulation. The Ray-Ban Display hardware and the Device Access Toolkit phone app come after the hackathon.

## 5. Depth and anchoring (the "it stays on the object" feature)

The aim is for the highlight to stay on the part when the camera or head moves. This is the same mechanism the glasses view needs.

1. **Direction.** When a frame is captured, the target's pixel position and the camera's field of view give a 3D ray from the camera. The field of view is calibrated once for the iPhone 15 Pro main camera.
2. **Depth.**
   - Primary: the task pack stores the real dimensions of each part, for example a 40 cm panel or an 8 mm dowel. The apparent size of the SAM mask, using the pinhole model, gives a metric distance.
   - Fallback: Muse Spark's estimate of the distance, with a lower confidence.
   - Depth turns the ray into a 3D point.
3. **Motion.** iPhone Safari and Ray-Ban Display both expose `DeviceOrientationEvent` (permission-gated). Rotation is applied to the 3D point and the overlay is projected again at about 30 Hz.
   - Rotation alone does not need depth.
   - Depth matters for small translations, and on glasses for the offset between camera and display. This is the reason it is in the design.
4. **Correction.** While the overlay is live, Pip runs SAM again on a new frame every 1–2 seconds ($0.0025 per frame). This corrects drift and translation.
   - If the part is not found, or the confidence drops, the overlay fades and Pip asks for a new look.
   - A stale highlight never stays on screen.
5. **On glasses** the same 3D point is projected into the display area. If it falls outside, Pip shows a direction cue.

This replaces the "frozen frame only" rule from the product definition with a stricter one: an overlay is shown only while its position is backed by fresh detection.
Fallback if anchoring is not stable by the end of day 3: overlays stay on the frozen frame, which is the behaviour of product definition v1.

## 6. Architecture

```
iPhone Safari (React)                      Cloudflare Worker (Hono) at pip.unveil.be         Meta Model API
┌────────────────────────────┐   HTTPS    ┌─────────────────────────────────────┐          ┌───────────────────────┐
│ camera, WAV recorder       │──────────▶ │ /api/transcribe                     │────────▶ │ muse-voice-transcribe │
│ session state machine      │            │ /api/turn: Spark → SAM refine        │────────▶ │ muse-spark-1.3        │
│ overlay + anchoring (IMU)  │ ◀──────────│ /api/track: SAM re-detect            │────────▶ │ sam-3.1               │
│ "How Pip sees" trace panel │            │ validation against the task pack     │          └───────────────────────┘
└────────────────────────────┘            │ session relay (Durable Object, WS)   │
                                          │ static assets, secrets, rate limits  │
Ray-Ban Display web app (600×600) ◀───────│                                     │
(in Meta's Display Simulator)    WS       └─────────────────────────────────────┘
```

- **A stateless turn API.** The client sends the session context with each request; the server validates it against the task pack. Progress only changes through explicit user actions.
- **Session relay.** A Durable Object holds a WebSocket per session, so the glasses view mirrors the phone. The two are paired with a short code.
- **Standard mode for model calls**, not Contributor mode, so user photos are not used for model training. Estimated cost is about $0.01–0.02 per turn.
- **Secrets.** `MODEL_API_KEY` lives in `.dev.vars` locally (gitignored) and as a Worker secret in production.
- **Abuse protection.** Rate limiting per IP and a daily spend cap. An access code for judges is optional.

## 7. The core turn

1. The client captures a frame (JPEG, long side ~1280 px, about 1,400 tokens) and records voice as 16 kHz WAV. The voice recording is transcribed; typed text skips this step.
2. **Muse Spark** receives the frame, the question, the current step, the part catalogue with dimensions, and a short history. It returns structured JSON: `intent`, `reply`, `targets[]` (`part_id`, box on the 0–1000 grid, point), `confidence`, `needs_better_view`, `clarification`, `source_ref`, and `distance_estimate_cm`.
3. **SAM 3.1** refines each target with a **box prompt**, which gives a precise mask. For counting or "which one" questions it runs a text prompt per part, in parallel.
4. **Validation and selection.** The server checks that each `part_id` exists in the step and that the Spark box and the SAM mask agree. The result is one of:
   - **highlight**: one clear match;
   - **clarify**: several plausible matches, numbered for tap-to-select;
   - **better_view**: no reliable match, so no arrow is drawn.
5. **Depth** comes from the mask size and the known dimensions. The response contains the overlays (mask outline, label, 3D anchor), the reply text, the source reference, and timings per stage for the trace panel.
6. The client draws the overlay, speaks the reply, and starts anchoring.

The latency target is a median of 8 seconds or less from releasing the talk button to the answer. Every stage is measured.

## 8. Task pack

`taskpacks/<id>/pack.json` plus images. It is authored from the official manual and checked by hand.

- **parts**: id, name (en/nl), `sam_prompt`, `dimensions_mm`, `expected_count`, `reference_image`.
- **steps**: id, title and instruction (en/nl), parts, tools, `source_ref` (manual page or figure), `reference_image`, `check` (`visible_criteria`, `not_visually_verifiable`), and `cautions`.

The format is generic, so a second task only needs data, not code.

## 9. "How Pip sees": showing the models at work

A collapsible panel in the app, also used as a scene in the video, shows each turn:
- the transcript;
- Spark's structured decision: target, step, confidence;
- Spark's box and the SAM mask on top;
- the distance estimate and its method;
- what was validated;
- the latency per model.

This makes the "creative use of Meta tooling" criterion visible: three models with distinct roles, combined, and checked against each other.

## 10. Evaluation

- **Accuracy:** about 20 held-out photos of the real object, never used for tuning, each with a ground-truth part box. We measure correct highlights, clarifications, and wrong confident highlights. Targets: at least 80% correct and 0 wrong confident highlights.
- **Anchoring:** how far the overlay drifts after rotating and moving the phone, in pixels, with and without re-detection.
- **Latency:** median and p90 per stage.
- **User test:** 1–2 people who have never seen the object build it with Pip. We note completion, where they got stuck and how often they asked for help. The result is exploratory.
- Everything goes into `docs/test-report.md`. Only measured numbers are reported.

## 11. Schedule

| Day | Date | Goal | Exit criterion |
|---|---|---|---|
| 0 | Thu 30 Oct | Plan agreed; repo scaffold; key verified | Spark, SAM and Transcribe each answer from the Worker |
| 1 | Fri 31 Oct | **Capability spike** on our own object photos: Spark grounding, SAM box/text prompts, Dutch transcription, latency. End-to-end on the iPhone over HTTPS. Object chosen, pack started | Measured go/no-go per model; one correct overlay on the iPhone |
| 2 | Sat 1 Nov | Task pack complete; state machine; guidance UI; clarification; deployed on `pip.unveil.be` | A whole task can be walked through on the public URL |
| 3 | Sun 2 Nov | Anchoring (IMU + depth + re-detection); trace panel; step check; Dutch | The overlay stays on the part while the phone moves, or we fall back to frozen frames |
| 4 | Mon 3 Nov | Ray-Ban Display web app + session relay, in the simulator; eval set; user test; polish | Glasses view mirrors the phone; test report filled in. Feature freeze in the evening |
| 5 | Tue 4 Nov | Demo video, write-up, README, final checks. **Submit by 18:00 CET** | Submitted |

Priority if time runs short: core phone loop > trace panel > anchoring > glasses view > Dutch.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Look-alike parts | Spark makes the semantic choice, SAM refines the shape, the expected count comes from the pack, and the app asks for clarification instead of guessing |
| Latency | Low reasoning effort, downscaled frames, parallel SAM calls, timing per stage |
| Anchoring drift | Re-detection every 1–2 s, the overlay fades when confidence drops, and frozen-frame fallback |
| iOS Safari: orientation and motion permission, audio unlock, speech synthesis | Tested on the iPhone 15 Pro on day 1; permissions requested on the first tap |
| Glasses claims judged as overstated | The simulation is labelled clearly; the limits of each device are stated in the README and the video |
| Rules differ from our assumptions | Confirm from the participant dashboard before day 2 |

## 13. Open questions

1. **The demo object**, physically available with its manual: 5–10 steps and visually distinct parts, ideally with one pair of parts that look alike.
2. **Official rules and submission form**, from the dashboard or Discord.
3. **Handover with the unveil.be Claude**: I deliver a Wrangler project with a Durable Object; the route `pip.unveil.be` gets bound on the existing zone.
4. **Story choices for the video**: who is the user on screen (an older person, someone who reads poorly, a new technician)? And do we show the professional angle, such as onboarding new lift technicians, as the vision?
