# Pip — product brief

**Pip** (Personal Interactive Partner) looks at a physical task through your phone camera, points at exactly what to touch, checks what happened, and guides you step by step until it is done.

Version 2.0 (draft), 30 October 2026. This brief fixes **what** we build; `build-plan.md` covers **how**, and `hackathon-rules.md` the constraints.
It generalises `productdefinitie-visuele-taakbegeleider.md`. Its principles stay: verified sources, explicit progress, no fake answers, no overclaiming.

## 1. The problem Pip addresses

People get stuck on physical tasks every day. The knowledge usually exists, in a manual, a procedure or someone else's head. What fails is **applying it to the real situation in front of you**:
- which part does the manual mean;
- which of these identical switches, valves or screws is it;
- did I do it right;
- where was I?

The cost is wasted call-outs, waiting, errors, damage and unsafe improvisation. It also means skilled people repeating the same explanations. The problem is the same at home (appliances, the fuse box, the boiler, assembly) and at work (technicians on unfamiliar equipment, new staff learning a procedure).

The demo scenario and the story are chosen later. The technology must work for **any** hands-on task with a visible object.

## 2. What Pip does, for any task

1. **Understands the goal.** You say or type what you want to do, for example "the power is out" or "descale this coffee machine".
2. **Builds a procedure.**
   - From a source you give it: a PDF manual, photos of instructions, or a text procedure. Pip compiles it into a structured, step-by-step procedure, with a reference back to the source for every step.
   - Without a source, it drafts one from general knowledge, clearly marked as *not from a verified source* and limited by a stricter safety policy.
3. **Maps the procedure to your scene.** Pip looks at the object, finds the parts the procedure talks about, and flags a mismatch, for example "this does not look like the model in the manual".
4. **Points.** For the current step it outlines the exact object or part in the camera frame and gives one short instruction, spoken and on screen. When several candidates are plausible it asks you to choose; when it cannot see well enough it asks for another view. It never points confidently at a guess.
5. **Checks.** After you act, Pip looks again and verifies the expected visible result, for example "the lever is up now" or "the panel is seated". What it cannot see, it asks you to confirm, and it records the difference.
6. **Guides to the end.** Progress changes only through explicit confirmation. You can ask questions at any point without losing your place, and go back, pause or resume.
7. **Stops when it must.** Global hard rules, enforced in code, plus the cautions from the procedure. Pip escalates instead of improvising.
8. **Reports.** It produces a summary of what was done, what was seen and what remains, to hand to a professional.

## 3. Why the Meta models matter

| Capability | Meta model |
|---|---|
| Hearing the user, hands busy, in many languages | Muse Voice Transcribe |
| Reading a manual (PDF/images) and compiling a structured procedure | Muse Spark 1.3: long context, PDF input, structured output |
| Finding every candidate object precisely | SAM 3.1: text and box prompts → instance masks |
| Deciding which object is meant, reading states and labels, verifying results | Muse Spark 1.3: vision, grounding, reasoning |
| Explaining, answering questions, writing the hand-over | Muse Spark 1.3 |

The models perceive, compile and explain. A deterministic runtime owns progress and safety, so a model cannot skip a step or override a stop.

## 4. Scope for the hackathon

**In scope**
- Native iPhone app (Swift, ARKit + LiDAR) with hands-free voice, spoken answers and annotations anchored on the objects in 3D; a small server at `pip.unveil.be` keeps the API key safe.
- The procedure compiler (from PDF, images, text, or no source).
- Scene mapping, pointing with overlays, clarify and better-view paths, and step verification.
- The guided runtime: steps, questions, back, pause and resume, all stored on the device.
- Global safety policy and stops, and the hand-over summary.
- "How Pip sees": a trace of every model call per turn.
- English by default, with a Dutch option.
- Evaluation across at least 3 different task domains.

**Out of scope**
- Android, glasses, accounts, a marketplace or sharing of procedures.
- Continuous video monitoring.
- Medical and health tasks (excluded by policy).

**Global safety policy** (code-enforced; extended per procedure):
- No medical or health guidance.
- No work behind covers on mains electricity or on gas.
- Stop and escalate on smoke, fire, sparks, burning smell, gas smell, water near electricity, or injury.
- Never claim something is safe: Pip reports what it saw and what the user confirmed.

## 5. Where Pip stands apart

No existing product combines, with no authoring, on a phone:
- **(a)** meaningful AI-chosen annotations (outline, motion arrow, target state, danger) anchored on the exact part and timed to speech;
- **(b)** a stateful procedure with camera-verified steps and safety gates;
- **(c)** a memory of the user's own devices that records where every fact came from.

General assistants (Gemini Live, ChatGPT) draw at most a box. Enterprise tools need authored content or a remote human expert. See `research.md` §4.

## 6. Success criteria

- One engine, no task-specific code. A new task needs only a source (or none), not new code.
- It works live on fresh camera frames on an iPhone 15 Pro, with no scripted answers.
- Measured on held-out photos from at least 3 domains: object localisation, state verification, **zero confident wrong pointers**, and latency.
- A user who does not know the task completes it with Pip.
