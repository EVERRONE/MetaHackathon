# Pip — technical build plan

Version 0.3 (draft), 30 October 2026. **What** we build is in `product-brief.md`; this document covers **how**.
Items marked **OPEN** still need a decision.

## 1. Deliverables

1. **Pip PWA** at `pip.unveil.be`: an installable iPhone web app that runs the power-outage scenario live on a real panel.
2. **"How Pip sees"**: an in-app trace of the three Meta models per turn.
3. **Test report**: measured detection accuracy, lever-state accuracy, wrong-pointer rate and latency on held-out panel photos, plus a short user test.
4. **Submission package**: public repo, English README with architecture diagram, demo video of about 3 minutes, and the write-up.

Not delivered: native apps, glasses, and the water and heating scenarios. These appear in the vision only.

## 2. Hackathon constraints

| Item | Value |
|---|---|
| Track / theme | Indie Developer / Build for Your World |
| Deadline | 4 Nov 2026, 21:00 ET = **5 Nov, 03:00 CET**. Internal target: **4 Nov, 18:00 CET** |
| Judging (public sources) | Impact 30%, creative use of Meta AI tooling 25%, demo (live + video) 25%, technical depth 20% |
| Budget | $150 Meta Model API credits |

**OPEN:** the official rules and the submission form. They are not on the public page, so they must be copied from the participant dashboard or Discord.

## 3. Model capability check (to be measured on day 1)

| Need | Model | Documented | Risk on our task | Day-1 test |
|---|---|---|---|---|
| Find every device on the DIN rail | SAM 3.1, text prompt (e.g. "circuit breaker") | Instance boxes and masks with confidence | Adjacent identical devices merge or get split | Count accuracy on 10 panel photos |
| Device type, lever state, label | Muse Spark 1.3 (vision + grounding, 0–1000 coordinates) | Detection, pointing, reading text, structured output | Small levers; handwritten labels; glare | Per-device state and label accuracy |
| Which device is meant | Spark reasoning over the SAM instances | Structured output with images | Choosing the wrong neighbour | Wrong-pointer rate (target: 0) |
| Voice input | Muse Voice Transcribe | WAV, Dutch supported | Safari records AAC | WAV encoding; transcript quality in English and Dutch |
| Speed | All | — | Two sequential model calls per turn | Median and p90 per stage |

Approaches compared in the spike for tying Spark to the SAM instances:
- **(a)** the image plus a text list of numbered SAM boxes on the 0–1000 grid;
- **(b)** an image with numbered marks drawn on it ("set-of-marks");
- **(c)** cropping each device and classifying the crops in one multi-image request.

We pick whichever measures best.
**Go/no-go:** if lever-state accuracy is too low, the fallback is to ask the user to confirm the state ("I think breaker 3 is down, is that right?"), and to keep pointing based on positions only.

## 4. Architecture

```
iPhone PWA (React, Vite)                   Cloudflare Worker (Hono) — pip.unveil.be          Meta Model API
┌─────────────────────────────┐  HTTPS   ┌──────────────────────────────────────┐        ┌───────────────────────┐
│ camera + torch, WAV recorder│────────▶ │ POST /api/transcribe                 │──────▶ │ muse-voice-transcribe │
│ procedure engine (state m.) │          │ POST /api/look   → SAM + Spark        │──────▶ │ sam-3.1               │
│ overlays, speech output     │ ◀────────│ POST /api/summary → Spark             │──────▶ │ muse-spark-1.3        │
│ panel map (localStorage)    │   JSON   │ schema validation, safety rules       │        └───────────────────────┘
│ "How Pip sees" trace        │          │ rate limit, spend cap, secrets        │
└─────────────────────────────┘          └──────────────────────────────────────┘
```

- **The procedure is code, not a prompt.** A deterministic state machine (`shared/procedures/`) defines the steps, the expected device states, the transitions and the hard stops. The models only perceive and explain. They never change the step or override a safety rule.
- **A stateless server.** Each request carries the procedure state and the panel map; the server validates them.
- **Standard API mode** (not Contributor), so home photos are not used for training. The key is kept in `.dev.vars` locally and as a Worker secret in production.
- **Stack:** TypeScript, React + Vite (PWA manifest + service worker), Hono on Cloudflare Workers, one shared package (types, JSON schemas, procedures), and Vitest.

## 5. The "look" turn

1. The client captures a frame (JPEG, long side about 1280 px) with the torch on if available. Voice is recorded as 16 kHz WAV and transcribed; typed text skips this step.
2. **SAM 3.1** segments all panel devices, which gives instances (box, mask, confidence).
3. **Muse Spark 1.3** receives:
   - the frame, the instances (using the method chosen in §3), the question and the current procedure step;
   - the panel map, if one was scanned.

   It returns structured JSON:
   - `devices[]`: instance id, type (`main_switch`, `rcd`, `breaker`, `other`), state (`on`, `off`, `tripped`, `unclear`), label text and confidence;
   - `answer` and `target_instance`;
   - `hazard_signals[]` and `needs_better_view`.
4. **Server checks:**
   - schema and instance ids;
   - device states against what the current step expects;
   - hazard keywords in the transcript and in Spark's output, which trigger a stop.

   The result is one of: `highlight` (one device), `clarify` (show the candidates, the user taps one), `better_view`, or `stop`.
5. The client draws the mask outline and label on the frozen frame and speaks the answer. The trace panel shows the output of each model and the timings.
6. **Verifying a step** is a new `look` with `expect: {instance, state}`. The step only completes when the state is seen as expected *and* the user confirms. If the state is unclear, the user's confirmation is recorded as "confirmed by user", not as "seen".

The latency target is a median of 8 s or less per turn, measured per stage.

## 6. Procedures

`shared/procedures/` is typed data plus transition logic, with unit tests.

- **`safety_gate`**: smell, smoke, heat, water, damage, sparks → `stop` with escalation (electrician; 112 for fire or smoke).
- **`identify`**: map the panel and find the tripped device(s).
- **`breaker_trip`**: reduce the load → reset the breaker → verify → if it trips again, leave it off and go to the summary.
- **`rcd_trip`**:
  1. switch off every breaker under that RCD;
  2. reset the RCD (if it trips again with all breakers off → `stop`);
  3. switch the breakers back on one at a time, verifying each;
  4. the breaker that causes a trip is the faulty circuit: leave it off;
  5. optionally, unplug the appliances on that circuit and retry.
- **`summary`**: Spark writes the electrician hand-over from the recorded event log only. It cannot invent events.

Every step has `back`, `pause` and resume, with the state kept on the device.

## 7. Panel map (optional scan)

A first scan stores the devices in left-to-right, row-by-row order, with type, the label read from the panel and the RCD grouping. The user can correct each entry. The map is stored in `localStorage`, can be deleted, and never leaves the device except as context for a request.
Without a map, Pip works from the live frame only.

## 8. Evaluation

- **Dataset:** about 25 held-out photos of real panels (the demo panel at different angles and in different light, plus other panels if we can get them), with ground-truth device boxes, types and states. They are never used for prompt tuning.
- **Metrics:**
  - device recall;
  - type and state accuracy;
  - label reading;
  - **confident wrong pointers (target 0)**;
  - clarification rate;
  - latency (median and p90).
- **Runner:** `eval/run.ts` calls the same pipeline as the app and writes `docs/test-report.md`.
- **User test:** 1–2 people who do not know the panel. We record completion, where they got stuck and how often they asked for help. The result is exploratory.

## 9. Schedule

| Day | Date | Goal | Exit criterion |
|---|---|---|---|
| 0 | Thu 30 Oct | Brief and plan agreed; repo scaffold; key verified | Each model answers from the Worker |
| 1 | Fri 31 Oct | **Capability spike** on 10–15 photos of the real panel (approaches a/b/c); WAV transcription; iPhone camera, torch and speech on HTTPS; deployed to `pip.unveil.be` | Measured go/no-go; one correct highlight on the iPhone |
| 2 | Sat 1 Nov | Procedure engine + `look` turn + verification; full `rcd_trip` and `breaker_trip` flows | A full outage scenario runs end to end on the real panel |
| 3 | Sun 2 Nov | Safety gate and stops; summary; panel scan; trace panel; Dutch | Every path works, including stop and clarify |
| 4 | Mon 3 Nov | Eval set + report; user test; UI polish (Pip's states); README + diagram | Feature freeze in the evening |
| 5 | Tue 4 Nov | Film and edit the video, write-up, final checks; **submit by 18:00 CET** | Submitted |

Priority if time runs short: `rcd_trip` + verification > safety gate > trace panel > summary > panel scan > Dutch.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Lever state misread | Fresh-frame verification, `unclear` → clarify, user confirmation recorded separately, measured in eval |
| Wrong neighbour pointed at | SAM instances + Spark choice + panel-map order; clarify when confidence is low |
| Low light / glare | Torch via camera constraints if Safari supports it, otherwise ask for light; tested on day 1 |
| Unsafe advice | Procedures and stops in code; the model cannot change the step; no instructions behind the cover |
| Latency | Downscaled frames, low reasoning effort, per-stage timing, parallel calls where possible |
| Demo needs a real trip | RCD test button or a real overload on one circuit; no simulated states |
| Rules differ from our assumptions | Confirm from the dashboard before day 2 |
