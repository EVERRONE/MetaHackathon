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

## Talking while pointing (streaming test)

**Goal:** Pip speaks and draws annotations at the same moment.

**Native tool calling while streaming.** Spark streams a sentence, emits `point(mark=13, style=outline)`, and then **ends its turn** (`finish_reason: tool_calls`). Interleaving speech with tool calls would cost a full model round trip per annotation, which is too slow.

**Inline cue tags in the streamed text** (`reasoning_effort: minimal`, one call). First token after **2.9 s**; the complete answer arrived 0.06 s later. Spark picked the correct mark and the correct direction:

```
Found it.
This is [[outline:13]] the 10F breaker.
It's off right now.
Flip [[arrow:13:up]] it upward to switch it back on.
```

**Design consequences:**
- Pip's speech is one streamed text with cue tags.
- The client parses the tags while streaming, speaks the clean text sentence by sentence, and shows each annotation at the moment its words are spoken. On iOS this is driven by the speech synthesizer's word-range callbacks.
- Tool calls are reserved for actions that change state (for example "request a new look"), which go through the runtime.

## Day 1 (31 October): measurements from the first build

Test media: the breaker photo above and ["Cherry G85-23000FR"](https://commons.wikimedia.org/wiki/File:Cherry_g85-23000FR-2_S7301761.jpg) (Wikimedia Commons, Free Art License), a French AZERTY keyboard on which @ is on the 0/à key. Neither image is committed. Runs from the Mac through the live Worker.

| Test | Result |
|---|---|
| Worker on Cloudflare free plan | Refused: decoding 22 SAM masks costs ~30–40 ms CPU, the free limit is 10 ms → Workers Paid |
| SAM concept "key" on the whole keyboard | 105 instances; set-of-marks with that many numbers is unreadable for Spark |
| Spark plan call (image, JSON, `minimal`), 1.3 vs 1.2 | 3.2–4.0 s vs 2.7–4.1 s: no faster model; ~550 reasoning tokens even at `minimal` |
| Spark's own point for a key (0–1000 grid) | Typically ½–1½ keys off; never usable alone for small look-alikes |
| Spark answering "how do I type @" on the 1024 px frame | Answered from memory once (Belgian layout: é/2); fixed by 1280 px and "read the legends, layouts differ" |
| Apple Vision OCR on key legends | Reads words ("alt gr", "entrée", "10F", "F10"), misses or misreads single symbols ("^" → "00") |
| SAM "breaker" on a 2.5× enlarged crop | 0 instances (22 on the whole frame) → SAM looks at both |
| Grounding (crop + whole frame + OCR) | alt gr ✓ (text), 10F ✓ / 11F ✓ (text), 0/à/@ ✓ via Spark check on a numbered crop (one key off → moved), three keys off → refused |
| Grounding time per target | 1.2–2.5 s; 3–5 s when the Spark check runs. The first OCR on a Mac loads models (~25 s once); the app warms it up at launch |
| Full look, v1.1 (one streamed call) | First sentence 3.0–4.0 s after the transcript; the cue sentences follow when their targets are grounded |
| Realtime ASR through the relay | Ready in ~1 s; final turn 0.2–0.4 s after the audio ends (Dutch and English, correct) |
| ElevenLabs Flash v2.5 / Turbo v2.5, streaming with timestamps | First audio ~0.25 s; character times are absolute within the sentence and the characters match the text exactly |
| `AVSpeechSynthesisMarker.byteSampleOffset` | A **byte** offset into the synthesised audio (Float32, 4 bytes per frame), not a sample index |

**Design changes:** the look became one streamed Spark call that points by position + printed text, grounded in parallel on the device (`build-plan.md` §3); the voice became ElevenLabs (§5); cues wait for their grounding instead of guessing.

### Review correction (31 October, evening)

A code review found that the prompt's examples used positions from the two test photos (alt gr, breaker 10F), so full-look results on those photos were partly flattered. The examples now use made-up devices. Honest re-run with the clean prompt:

| Look | Result |
|---|---|
| Breakers: "Which is 10F, is it on?" / "Welke is 7F, hoe zet ik die uit?" | Correct outline via the printed text in ~1.5 s; state read correctly |
| Close-up keyboard (keys ≈ 95 px): @, %, entrée | alt gr + 0/à/@, shift + ù/%, entrée: all correct (Spark check on a numbered crop); first sentence 1.7–3.0 s, cue sentences 4.8–6.3 s |
| Whole keyboard from afar (keys ≈ 45 px) | Spoken answer right; Spark's points up to two keys off, refused by the check, so no pointer |
| Apple Vision accurate text recognition after a pause | ~25 s to reload its models (fast pass: 0.05 s). Both passes now run within a budget, and the app keeps the accurate one warm |

