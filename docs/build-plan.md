# Build plan — Visual AI Task Guide

Version 0.1 (draft), 30 October 2026. Companion to `productdefinitie-visuele-taakbegeleider.md` (product definition, Dutch).
This document covers the technical build for the Meta Global AI Developer Hackathon. Items marked **OPEN** need a decision before or during the build.

## 1. Hackathon constraints

| Item | Value |
|---|---|
| Event | Meta Global AI Developer Hackathon (Cerebral Valley), remote |
| Track | Indie Developer: "creativity, technical ambition, and whether it works" |
| Theme | Build for Your World |
| Submission deadline | 4 Nov 2026, 21:00 ET = **5 Nov 2026, 03:00 CET** |
| Internal deadline | **4 Nov 2026, 18:00 CET**: submission sent, nine hours of buffer |
| Judging | 4–8 Nov, live finals, winners 9 Nov |
| Required | Built on Meta models (Meta Model API and/or open weights) |
| Budget | $150 Meta Model API credits |

Judging weights reported by several sources (the official rules sit behind the participant login, **OPEN: confirm**):

| Criterion | Weight | What it means for us |
|---|---|---|
| Impact | 30% | A clear real-world problem; show a stranger finishing a task they could not do from the manual alone. |
| Creative use of Meta AI tooling | 25% | Three Meta models with distinct, non-trivial roles: Muse Spark reasons, SAM 3.1 localizes, Muse Voice Transcribe listens. They are combined, not just called. |
| Demo (live + video) | 25% | It must work live on fresh camera frames, with acceptable latency. The 2–3 minute video is planned from day 1. |
| Technical depth & execution | 20% | Clean architecture, typed contracts, validation, an evaluation script with real numbers, and documentation. |

Expected submission contents (**OPEN: confirm** against the official form): a public repo with setup instructions, a public demo URL, a demo video of about 3 minutes, and a short write-up covering the problem, the users, how Meta's models are used, and what comes next.

## 2. Scope for the hackathon

**In scope (v1)**
- iPhone Safari web app over HTTPS: live camera, frame capture, push-to-talk, text input.
- One complete, hand-verified task pack: one small assembly object with 5–10 steps.
- Ask → look → highlight → explain loop on fresh frames, with overlays bound to the captured frame.
- Clarification when the target is ambiguous: multiple candidates, plus tap-to-select.
- Explicit step progression: only the user confirms a step. Includes back, pause and resume (stored on the device).
- An optional visual check of the current step against the expected result, worded carefully: what is visible, not what is guaranteed.
- Spoken answers with browser speech synthesis, with text always shown as well.
- English UI and voice by default, with a Dutch option.
- An evaluation script and a short test report with real accuracy and latency numbers.

**Out of scope**: accounts, payments, App Store, live 2D tracking, automatic manual ingestion, multiple task packs in the UI, continuous recording, and native glasses integration.

**Stretch (only after the core is done)**: companion character art made with Muse Image; a glasses-style "heads-up" presentation mode in the browser, clearly labelled as a simulation; a pack-authoring helper that drafts a task pack from a manual with Muse Spark, followed by human review.

## 3. Architecture

```
iPhone Safari (React SPA)                 Cloudflare Worker (Hono)                 Meta Model API
┌───────────────────────────┐   HTTPS    ┌──────────────────────────────┐        ┌─────────────────────────┐
│ Camera + frame capture    │──────────▶ │ POST /api/transcribe         │──────▶ │ muse-voice-transcribe   │
│ PCM recorder → WAV        │            │ POST /api/turn               │──────▶ │ muse-spark-1.3          │
│ Session state machine     │ ◀──────────│  ├ validate against pack     │──────▶ │ sam-3.1                 │
│ Overlay renderer (canvas) │   JSON     │  ├ orchestrate Spark + SAM   │        └─────────────────────────┘
│ Speech synthesis          │            │  └ select / clarify target   │
│ localStorage (progress)   │            │ Static assets (SPA, packs)   │
└───────────────────────────┘            │ Secrets, rate limit, logs    │
                                         └──────────────────────────────┘
```

Key decisions:
- **One Cloudflare Worker** serves the static app and the API, on a subdomain of unveil.be (**OPEN**: name, for example `guide.unveil.be`). HTTPS is required for camera access. The API key exists only as a Worker secret.
- **A stateless server.** Each request carries the session context: pack id and version, current step, confirmed steps, a short history. The server validates it against the pack and never changes progress. Progress belongs to the client state machine and changes only on explicit user actions.
- **Structured model output.** Muse Spark is called with `response_format: json_schema`. Every response is validated again on the server, for example that a `part_id` exists in the pack and the step matches.
- **Standard mode, not Contributor mode.** User photos of their home are not shared for model training. The cost is low, about $0.01 per turn, so $150 covers thousands of turns.
- **Stack.** TypeScript throughout: Vite + React for the client, Hono on Workers, and one shared package for the types, schemas and task-pack format. A single repository, built and deployed with Wrangler.

## 4. The core turn: "where is X / what do I do now?"

1. The client captures the frame: a JPEG with its long side at about 1280 px, sent with orientation and crop metadata so overlays map back exactly.
2. Voice is recorded as 16 kHz mono PCM through Web Audio and encoded as WAV. Safari's MediaRecorder only produces AAC/MP4, and the transcription endpoint only confirms WAV. It goes to `POST /api/transcribe` → `muse-voice-transcribe-1.0` (`/v1/asr/transcribe`, `PUSH_TO_TALK`). Typed text skips this step.
3. `POST /api/turn` runs two calls **in parallel**:
   - **Muse Spark** receives the frame, the question, the current step from the pack, the part catalogue and a short history. It returns JSON: `intent`, `reply`, `target_part_ids`, an approximate `target_point` per part, `needs_better_view`, `clarification`, and `source_ref`.
   - **SAM 3.1, speculative**: segments the parts expected in the current step, using the noun-phrase prompts from the pack, with confidence enabled. This saves a full round trip in the common case.
4. **Target selection** in the server:
   - Match each SAM instance to Spark's `target_point` and the expected count from the pack.
   - If the target was not part of the speculative call, run SAM once more with that part's prompt.
   - Result: one clear match → `highlight`. Several plausible matches → `clarify`: number them and ask the user to tap one. No match, or low confidence → `better_view`: ask for another angle and draw no arrow.
5. The response contains the reply text, overlays (box or mask outline in normalized coordinates, a label, and a type: highlight, pointer or schematic), clarification options, and the source reference. Each overlay is tied to the frame id it was computed on.
6. The client draws the overlays on the frozen frame, speaks the reply, and clears every overlay as soon as the live view returns.

**Fallback if accuracy is not good enough** (to decide after the spike): add a set-of-marks verification. The client draws numbered SAM candidates onto the frame and Muse Spark picks the right number. This costs one extra call, so only when the result is ambiguous.

**Latency budget** (target: median ≤ 8 s from release of the talk button to the answer on screen): upload ≤ 0.5 s, transcription ~1 s, Spark and SAM in parallel ~3–4 s, selection < 50 ms, speech starts right away. Spark runs at low reasoning effort for turns and higher effort only for checks. Measured per stage and logged.

## 5. Task pack format

`taskpacks/<pack-id>/pack.json` plus images. It is authored by us from the official manual and checked by hand.

```
pack: id, version, title{en,nl}, product, source (manual + edition), languages
parts[]: id, name{en,nl}, sam_prompt (English noun phrase), expected_count, reference_image, notes
steps[]: id, title{en,nl}, instruction{en,nl}, parts[], tools[], source_ref (manual page/figure),
         reference_image (manual figure), check{prompt, visible_criteria[], not_visually_verifiable[]},
         cautions[]
```

The SAM prompts are tuned on our own photos during the spike. The format is generic, so a second pack only requires data, no code.

## 6. Client state machine

States: `select_task` → `permissions` → `live` ⇄ `capturing` → `thinking` → `answer` (frozen frame + overlays) → `live` …; plus `clarify`, `checking`, `paused`, `done`.

- Progress events come only from the user: `confirm_step`, `previous_step`, `pause` and `resume`. A model response never triggers them.
- On resume, the app restores the last confirmed step and asks the user to show the current situation first.
- When the user goes back to an earlier step, the app asks which actions were already done.
- Error paths: microphone denied → text input; network or model error → the pack instruction stays readable and the user can retry; camera denied → an instruction screen.

## 7. Repository layout

```
docs/                product definition, build plan, test report, architecture diagram
src/client/          React app (screens, camera, recorder, overlay, state machine, i18n)
src/worker/          Hono routes, Meta API clients (spark, sam, transcribe), selection logic
src/shared/          types, JSON schemas, task-pack schema + validator
taskpacks/<id>/      pack.json + reference images
eval/                held-out photos + ground-truth boxes, eval runner → report
```

Quality bar, kept proportionate: TypeScript strict mode, unit tests for the selection logic, pack validation and the state machine, one eval script, a README with setup and an architecture section, and no secrets in the repo. Commits are authored by Emilien Verrone.

## 8. Evaluation

- **Accuracy:** about 20 held-out photos of the real object that were never used for prompt tuning, each with a ground-truth box for the asked part. We measure correct highlights, clarifications and wrong confident highlights. Targets from the product definition: at least 8 of 10 correct, and 0 wrong confident highlights.
- **Latency:** per-stage timings logged per turn, with the median and p90 reported.
- **User test:** a walkthrough with 1–2 people who have not seen the object. We note completion, where they got stuck, and how often they asked for help. The results are labelled exploratory.
- All numbers go into `docs/test-report.md` and the submission. Only measured results are reported.

## 9. Schedule

| Day | Date | Goal | Exit criterion |
|---|---|---|---|
| 0 | Thu 30 Oct | Plan agreed, repo scaffolded, API key verified with one call to each model | Spark, SAM and Transcribe all answer from the Worker |
| 1 | Fri 31 Oct | **Technical spike on the iPhone**: capture → Spark + SAM → one correct overlay; WAV recording → transcript; speech output. Object chosen, parts photographed, SAM prompts tuned | End-to-end on the real iPhone over HTTPS; go/no-go on the approach |
| 2 | Sat 1 Nov | Task pack complete; session state machine; guidance screen; clarification flow | A full task can be walked through, still rough |
| 3 | Sun 2 Nov | Step check; error paths; Dutch option; deployed on the unveil.be subdomain; eval set + first numbers | Public URL works; first accuracy and latency numbers |
| 4 | Mon 3 Nov | Companion states and UI polish; latency tuning; user test; README, architecture diagram, test report | Feature freeze at the end of the day |
| 5 | Tue 4 Nov | Record and edit the demo video; write-up; final checks; **submit by 18:00 CET** | Submitted |

Stretch items only start once the exit criterion of day 3 is met.

## 10. Risks

| Risk | Mitigation |
|---|---|
| SAM confuses look-alike parts (dowels, screws) | Prompts per part tuned on real photos; Spark's point plus expected count; set-of-marks verification; clarification instead of guessing |
| Latency above 8 s | Parallel speculative SAM, low reasoning effort, downscaled frames, per-stage timings |
| iOS Safari quirks (camera orientation, audio unlock, speech synthesis needing a user gesture) | Tested on the real iPhone on day 1; speech unlocked on the first tap |
| Transcription format or Dutch quality | WAV encoding on the client; typed input as permanent fallback; Dutch tested on day 1 |
| Credit abuse on a public URL | Rate limiting in the Worker per IP and a daily cap, with an optional access code given to judges in the submission |
| Official rules differ from our assumptions | Confirm via the participant portal / Discord before day 2 |

## 11. Open questions

1. **Demo object**: which assembly object is physically available, with its manual? It should have 5–10 steps and visually distinct parts, plus at least one look-alike pair to show clarification.
2. **Official rules**: the submission form and the exact requirements (video length, public URL, repo visibility, use of pre-existing code). Visible in the participant portal or on Discord.
3. **Subdomain** and the handover with the Claude that runs unveil.be: I deliver a Wrangler project, and who binds the route?
4. **Meta glasses**: do you own Ray-Ban Meta or Meta Ray-Ban Display glasses? This only decides whether the heads-up simulation stretch is worth it.
5. **Device**: the iPhone model and iOS version used for testing and the demo.
6. **API key handling**: put the key in `.dev.vars` in this folder (gitignored), not in the chat.
