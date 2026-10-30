# Capability spike — day 0 (30 October 2026)

First measurements against the Meta Model API, run from a Mac on a home connection, in standard mode. The scripts are in `spikes/day0/`.
Test image: ["MCB Circuit breakers for DIN rail"](https://commons.wikimedia.org/wiki/File:MCB_Circuit_breakers_for_DIN_rail.jpg) from Wikimedia Commons, 1280×960. It has 14 labelled breakers (1F–13F2) whose states alternate on/off, which gives us a known ground truth. The image is not committed to this repo.

These are single runs on one image, so they show direction, not reliability. The real evaluation follows the build plan.

## Results

| Test | Result | Latency |
|---|---|---|
| Muse Spark text, `reasoning_effort: minimal` | Works | ~2 s |
| SAM 3.1, prompt "circuit breaker" | **0 instances** | 1.6 s |
| SAM 3.1, prompt "breaker" | 22 instances: all breakers, plus false positives (terminal blocks); confidence 0.52–0.73 | 1.3 s |
| SAM 3.1, prompt "switch" / "label" | 17 / 27 instances, mixed quality | 1.2–1.5 s |
| SAM 3.1, prompts "lever", "black lever", "red indicator" | 0 instances | ~1 s |
| Spark, list all 14 breakers (label, state, box), effort `low` | 8/14 correct, 6 "unclear", 0 wrong | 19 s |
| Spark, the same task, effort `medium` | **14/14 labels and states correct** | 21 s |
| Spark's own boxes (0–1000 grid) | Approximate; some boxes cover the neighbouring breaker | — |
| SAM "breaker" + numbered marks drawn on the image (set-of-marks) + Spark, all devices, effort `minimal` | Most correct; errors where SAM merged two neighbouring breakers | 11 s |
| **Set-of-marks + one focused question** ("which mark is 10F, on or off?"), effort `minimal` | **3/3 correct mark and state** | **2.7–3.9 s** |
| Muse Voice Transcribe, WAV 16 kHz, English | Correct (one word repeated) | 3.6 s |
| Muse Voice Transcribe, WAV 16 kHz, Dutch | Perfect | 1.6 s |

## What this changes in the design

1. **Never draw Spark's own boxes.** All pointing uses SAM geometry; Spark *chooses* between numbered SAM instances (set-of-marks). This avoids confident pointers at the wrong neighbour.
2. **SAM prompts are fragile.** The compiler generates 2–3 noun-phrase variants per object. The engine runs them in parallel (~1.5 s, $0.0025 each), merges overlapping instances, and lets Spark reject false positives.
3. **Ask focused questions.** A look asks only about the current step's targets: about 3 s at `minimal` effort. A full scene scan (all objects and states) takes 11–21 s. It is used once, with a progress indicator, or split into parallel focused calls.
4. **Effort levels:** `minimal` for looks and verification, `medium` for scene scans and for compiling a procedure.
5. **Expected per-look latency:** transcription ~2 s + SAM ~1.5 s + Spark ~3 s ≈ **6–7 s**, within the 8 s target. Measured end to end on the iPhone on day 1.
6. **Honesty works in our favour.** At lower effort, Spark answers "unclear" rather than guessing. The runtime maps "unclear" to *better view* or *clarify*.
7. **Dense rows of identical objects are the hardest case.** SAM can merge neighbours. Mitigations: a second SAM pass with a box prompt per Spark-chosen region, and a clarify step when Spark's choice spans two instances.
