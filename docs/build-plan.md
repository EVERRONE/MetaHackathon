# Pip — technical build plan

Version 0.4 (draft), 30 October 2026. **What** we build: `product-brief.md`. Constraints: `hackathon-rules.md`.

## 1. Deliverables

1. **Pip engine + PWA** at `pip.unveil.be`: a generic visual task-guidance engine, usable on an iPhone.
2. **"How Pip sees"**: a trace of the model calls, decisions and timings for each turn.
3. **Evaluation**: a runner plus `docs/test-report.md` with measured results on at least 3 task domains.
4. **Submission material**: a public repo, an English README with an architecture diagram and a "Built during the hackathon" section, a 3-minute video (script later), and the write-up.

## 2. Architecture

```
iPhone PWA (React + Vite)                  Cloudflare Worker (Hono) — pip.unveil.be           Meta Model API
┌──────────────────────────────┐  HTTPS  ┌───────────────────────────────────────┐        ┌──────────────────────┐
│ camera (+torch), WAV recorder│───────▶ │ POST /api/transcribe                  │──────▶ │ muse-voice-transcribe│
│ guidance runtime (state m.)  │         │ POST /api/compile  source → procedure │──────▶ │ muse-spark-1.3       │
│ overlay renderer, speech     │ ◀───────│ POST /api/look     perceive + guide   │──────▶ │ sam-3.1              │
│ session store (localStorage) │  JSON   │ POST /api/ask      Q&A on current step│        └──────────────────────┘
│ trace panel                  │         │ POST /api/report   hand-over summary  │
└──────────────────────────────┘         │ policy, validation, limits, secrets   │
                                         └───────────────────────────────────────┘
```

Principles:
- **Models perceive, compile and explain; code decides.** Progress, verification outcomes and safety stops live in a deterministic runtime. Model output is schema-constrained (`json_schema`) and validated before use.
- **A stateless server.** The client sends the procedure, the session state and the frame; the server validates and answers. Progress is stored on the device.
- **Standard API mode** (not Contributor), so user photos are not used for training. The key is in `.dev.vars` locally and in a Worker secret in production.
- **Stack:** TypeScript strict throughout; React + Vite as a PWA; Hono on Cloudflare Workers; one shared package for types, schemas and the runtime; Vitest.

## 3. Core data model (`src/shared`)

```
Procedure  { id, title, goal, source: {kind: pdf|images|text|none, ref, verified: bool},
             objects: ObjectSpec[], steps: Step[], cautions: string[], language }
ObjectSpec { id, name, description, sam_prompt, expected_count?, size_mm? }
Step       { id, instruction, why?, targets: objectId[], tools?: string[],
             expect: Check[], cautions?: string[], source_ref? }
Check      { kind: visual|user_confirm, object?: objectId, state: string, description }
Session    { procedure, stepIndex, events: Event[], scene: SceneMap?, lang }
Event      { t, type: look|highlight|clarify|verified|user_confirmed|question|stop|back|pause, data }
```

## 4. Engine components

**4.1 Compiler** (`/api/compile`)
- **Input:** a goal plus an optional source (PDF, up to N instruction photos, or text).
- **Muse Spark** (higher reasoning effort, PDF and image input, `json_schema`) produces the `Procedure`.
- **Validation:**
  - every target and check refers to a defined object;
  - every step has a `source_ref` when a source exists;
  - the number of steps stays within bounds;
  - the policy pass runs on the result (§4.5).
- **No source:** `verified: false`, a stricter policy applies, and the UI labels the procedure as such.
- **Latency budget:** under 30 s, once per task, with a progress indicator.

**4.2 Perception** (inside `/api/look`), given a frame and the object specs that matter for the current step:
1. **SAM 3.1** runs text prompts for each relevant `sam_prompt`, in parallel. It returns instances (box, mask, confidence).
2. **Muse Spark** receives the frame, the instance list and the step. It returns per instance which object it is (or none), its visible state, any label text and a confidence, plus hazard signals and image-quality issues.
3. **Fusion:** an object counts as found only when SAM and Spark agree. Spark can also propose a box that SAM missed; SAM then refines it with a box prompt.

The spike compares three ways of tying Spark to the instances: numbered boxes on the 0–1000 grid as text, set-of-marks drawn on the image, and cropped instances sent as multiple images.

**4.3 Guidance runtime** (shared; runs on the client and is validated on the server)
- **Per step:** look → highlight the target(s) → user acts → verify.
- **Result of a look:**
  - `highlight`: one confident match for each target;
  - `clarify`: several plausible matches, numbered; the user taps one;
  - `better_view`: not enough evidence; nothing is drawn;
  - `stop`: the policy fired.
- **Verification:**
  - each `visual` check is evaluated on a fresh frame and results in `verified`, `not_yet` or `unclear`;
  - each `user_confirm` check is asked for explicitly;
  - the step completes only when all checks pass or the user overrides, and an override is logged as such.
- **Navigation:** questions (`/api/ask`) never change the step. `back`, `pause` and `resume` are always available. After a resume, Pip asks for a fresh look before it points at anything.

**4.4 Scene mapping:** at the start, a look at the object maps the procedure's objects to what is visible. If key objects are missing or do not match, Pip warns about a possible wrong model or manual and asks for confirmation.

**4.5 Policy** (`src/shared/policy`)
- **Classification:** goal and procedure are classified into `allowed`, `allowed_with_cautions` or `refused`. Refused covers medical and health, work on live mains or gas, and anything behind safety covers.
- **Hazards during a look:** hazard signals from Spark, plus keywords in the transcript, lead to `stop` with escalation text.
- **No-source procedures:** stricter rules, and Pip refuses whenever the risk class is high.

**4.6 Voice and speech:** the client records 16 kHz mono PCM, encodes it as WAV and sends it to `/api/transcribe` (Muse Voice Transcribe, `PUSH_TO_TALK`). Answers are spoken with the browser's `speechSynthesis`, unlocked on the first tap.

**4.7 Trace:** every API response includes a `trace`:
- each model call, with its model, its latency and a compact form of its input and output;
- the fusion decisions and the policy decisions.

The trace panel renders it, including Spark's box and SAM's mask on top of each other.

## 5. Evaluation

- **Domains:** at least 3 very different tasks, chosen from what we can physically access, for example an electrical panel, a household appliance and a mechanical assembly. For each: a source (our own text, or a manual we are allowed to use) and 10–15 held-out photos with ground-truth boxes and states, never used for tuning.
- **Metrics:**
  - target localisation (precision/recall);
  - state verification accuracy;
  - **confident wrong pointers (target 0)**;
  - clarify and better-view rate;
  - compiler validity: schema pass rate and source-reference coverage;
  - latency (median and p90 per stage).
- **Runner:** `eval/run.ts` calls the same server code. It writes `docs/test-report.md` with real numbers only.
- **Plus:** a short user test with 1–2 people on one task.

## 6. Schedule

| Day | Date | Goal | Exit criterion |
|---|---|---|---|
| 0 | Thu 30 Oct | Plan agreed; repo scaffold (PWA + Worker + shared); key verified | Each of the 3 models answers from the Worker |
| 1 | Fri 31 Oct | **Capability spike**: perception fusion (3 methods) on photos from 3 domains; compiler on 2 sources; WAV transcription; iPhone camera, torch and speech over HTTPS; first deploy | Measured go/no-go per capability; one correct highlight on the iPhone |
| 2 | Sat 1 Nov | Runtime + `/api/look` + verification + clarify; compiler wired into the UI; guidance screen | One task completed end to end on the phone |
| 3 | Sun 2 Nov | Policy and stops; no-source mode; scene mapping; Q&A; trace panel; report; Dutch | A second and third domain run on the same engine without code changes |
| 4 | Mon 3 Nov | Eval sets + report; latency tuning; UI polish (Pip's states); README + diagram + "Built during the hackathon" | Feature freeze in the evening; demo scenario chosen |
| 5 | Tue 4 Nov | Video (script by us together), write-up, final checks; **submit by 18:00 CET** | Submitted |

Priority if time runs short: perception + pointing + verification > runtime > compiler from a source > policy > trace > no-source mode > Dutch.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Confusing look-alike objects | SAM + Spark agreement is required; clarify instead of guessing; measured |
| Compiler output is wrong or unusable | Schema + reference validation; procedure visible to the user; sources preferred over no-source |
| Unsafe guidance on unknown tasks | Policy classification, code-enforced stops, stricter no-source mode, refusal list |
| "Simple image analyser" perception by judges | The demo shows the full loop: compile → point → act → verify → finish, plus the trace |
| Latency | Downscaled frames, parallel SAM, low reasoning effort per look, timing per stage |
| iOS Safari quirks | Tested on the iPhone 15 Pro on day 1 |
| Rights to manuals and images | Our own photos; only usable sources committed; otherwise referenced |
