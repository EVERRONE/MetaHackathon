# Pip — research summary

30 October 2026. Consolidated findings behind `build-plan.md`. Our own measurements are in `spike-results.md`.

## 1. Platform: native iOS, not Rust, not web

| | Native Swift + TS Worker | PWA (TypeScript) | Rust-based |
|---|---|---|---|
| Annotations that stay on the object | **Yes**: ARKit world tracking + LiDAR depth (iPhone 15 Pro), ~1–3 cm at 0.3–2 m | 2D only: drifts, loses lock off-screen; no WebXR on iOS Safari | Webview options (Tauri, Dioxus) = PWA limits; native still needs Swift |
| Voice ↔ annotation sync | Sample-accurate word markers (`AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:)`) | Word boundaries only | Same as its UI layer |
| Hands-free conversation (barge-in) | Voice processing / echo cancellation on `AVAudioEngine` | Fragile: open WebKit bugs (ducking, mic muted by `speak()`) | — |
| Dev speed for us | Good | Fastest | Slowest (toolchain, FFI, less agent fluency) |
| Install | Full Xcode + free Apple ID (7-day signing) | A URL | Xcode **and** the Rust toolchain |

**Rust verdict:** latency is dominated by 2–4 s cloud model calls. Reprojecting a few hundred points per frame is trivial in Swift with `simd`. Rust would add toolchain friction and save milliseconds; it only makes sense later for a cross-platform core.

**Rules check:** a public URL is not required; the submission needs the public repo and the video. A native app is fine.

Key references: [ARDepthData](https://developer.apple.com/documentation/arkit/ardepthdata), [ARCamera.projectPoint](https://developer.apple.com/documentation/arkit/arcamera), [ARKit depth accuracy ~4 cm RMSE](https://arxiv.org/pdf/2310.14437), [Vision TrackObjectRequest](https://developer.apple.com/documentation/vision/trackrectanglerequest), [AVSpeechSynthesizer write+markers](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:tomarkercallback:)), [no WebXR on iPhone](https://abratabia.com/webxr-games/webxr-device-support.php).

## 2. Meta Model API facts that shape the design

- **Tool calling** works on Chat Completions, Responses and Messages, but a client tool call **ends the response**: text → call → round trip → text. Therefore pointing uses **inline cue tags in the streamed text**, which we verified gives the correct mark and direction, with the first token after 2.9 s.
- **Reasoning cannot be turned off.** At `minimal` it still adds an initial delay. No time-to-first-token figures are published, so we measure our own.
- **Prompt caching** is an automatic prefix cache. Cached input is $0.15 per 1M tokens against $1.25 uncached. To benefit we put stable content first (the system prompt, the procedure, the cue grammar) and send a `prompt_cache_key`.
- **Realtime speech recognition** (`wss://api.meta.ai/v1/asr/realtime`) has server-side endpointing, cumulative partial transcripts, `speechStart` and `speechComplete` events, and a `languageBias` list (by language name, Dutch included).
  - Keyword biasing is available.
  - The key goes in the first message, and must stay on a server.
  - Silence must still be sent, otherwise the stream is closed after 10 s.
  - Third-party measurement (Pipecat): p99 ≈ 1.9 s from the end of speech to the final transcript.
  - Price: $0.18 per hour.
- **There is no Meta text-to-speech model.** Meta's own iOS cookbook uses `AVSpeechSynthesizer` on the device.
- **SAM 3.1:**
  - Box and point prompts use pixel-coordinate tokens; up to 16 objects per request.
  - Masks use a custom base85 encoding with arithmetic coding. The parser exists **only in TypeScript and Python** (`@meta-sam/parser` → `decodeMaskToSVGPath`), so our Worker decodes the masks into polygons.
  - Video tracking only works on uploaded files, not live, so on-device tracking (ARKit / Vision) has to bridge between model calls.
- **Muse Spark video input** is MP4 only. Using it to verify an action is unproven; before/after stills are probably faster.
- **No Swift SDK.** The API is compatible with the OpenAI SDK; on iOS we use `URLSession` with our own SSE parser.
- **Limits (standard mode):** Spark 3,000 RPM and 4M TPM; SAM 3,000 RPM; speech recognition 256 concurrent streams.

Docs index: https://dev.meta.ai/llms.txt (add `.md` to any docs page to get its markdown).

## 3. What good visual guidance looks like (HCI evidence)

- On-object AR instructions cut assembly errors by 82% ([Tang 2003](https://researchwith.njit.edu/en/publications/comparative-effectiveness-of-augmented-reality-in-object-assembly/)).
- A pointer alone did not beat video; cues that show motion and shape did. Cues that fade after about 3 s worked better than cues that stay ([Fussell 2004](https://collablab.northwestern.edu/CollabolabDistro/nucmc/Fussell_Gestures_HCI_2004.pdf)).
- Each extra cue raises mental effort ([Kim 2019](https://opus.lib.uts.edu.au/handle/10453/139912)), so we show at most 3 marks at once.
- For targets outside the view, a wedge at the screen edge works best ([Gustafson 2008](https://dx.doi.org/10.1145/1357054.1357179); [Apple HIG AR](https://developer.apple.com/design/human-interface-guidelines/augmented-reality)).
- A consistent visual grammar helps users learn faster (Microsoft Guides: outline = pick, dashed = place, red = avoid, hatched = caution) ([MS Learn](https://learn.microsoft.com/en-us/dynamics365/mixed-reality/guides/hololens-app-styles)).
- **Timing of the highlight against speech:**
  - Speakers start a gesture about 0.75 s before the word it goes with ([Krauss 1998](https://www.ffri.hr/~ibrdar/komunikacija/seminari/Krauss,%201998%20-%20Why%20do%20we%20gesture%20when%20we%20speak.pdf)).
  - Listeners find an object faster when the gaze cue comes about 1 s before the noun, and a **wrong** cue hurts more than no cue ([Staudte & Crocker 2011](https://jahrbib.sulb.uni-saarland.de/bitstream/20.500.11880/23602/1/dissMariaStaudte.pdf)).
  - → Show the cue 300–800 ms **before** the noun; if unsure, draw nothing.
- **Shared view matters.** Without a shared view, pairs took twice as long; without being able to watch each other they made 8× more errors. Helpers answer "this one?" immediately ([Clark & Krych 2004](https://www.coli.uni-saarland.de/~masta/WS13/ClarkKrych_04.pdf)).
- **How expert guides behave** ([HoloAssist, ICCV 2023](https://openaccess.thecvf.com/content/ICCV2023/papers/Wang_HoloAssist_an_Egocentric_Human_Interaction_Dataset_for_Interactive_AI_Assistants_ICCV_2023_paper.pdf)): they correct critical errors within 5 s, leave minor ones alone, and name distinguishing features when objects look alike.
- **Trust:**
  - First-person uncertainty ("I'm not sure, but…") reduces over-reliance ([Kim, FAccT 2024](https://arxiv.org/abs/2405.00623)).
  - Long explanations inflate trust ([Steyvers 2025](https://arxiv.org/abs/2401.13835)).
  - → Keep explanations short and say where each claim comes from: *I see / you told me / the manual says / I'm guessing*.
- **Memory:** users expect to see, edit and delete what an assistant remembers, and to be asked before anything is kept across sessions.

## 4. Competitors and the gap

| Product | Does | Does not |
|---|---|---|
| Gemini Live visual guidance / Guided Vision (Oct 2026) | Box or dot on objects, reframing cues | No motion/rotate/target-state/danger cues, no step state, no verified procedures, no device memory |
| ChatGPT voice + video | Talks about the camera view | No on-object drawing |
| Meta Ray-Ban Display / Muse | Step lists in the lens | No marks anchored on objects |
| Dynamics 365 Guides / Remote Assist | Authored holographic procedures | **End of support 31 Dec 2026** |
| Vuforia Chalk, TeamViewer Frontline, Augmentir, Taqtile, TechSee, Aquant | Human-drawn annotations or authored enterprise workflows | Authoring-heavy, enterprise-only, or a human expert in the loop |

**The gap Pip owns:** no product combines, with no authoring, on a phone:
- **(a)** meaningful AI-chosen annotations, anchored on the exact part and timed to speech;
- **(b)** a stateful procedure with camera-verified steps and safety gates;
- **(c)** a memory of the user's own devices that records where each fact came from.

## 5. Impact evidence (for the story later)

| Fact | Source | Strength |
|---|---|---|
| 14% of truck rolls are unnecessary; 33% of service queries need no professional | [Aquant 2025](https://www.aquant.ai/resources/post/2025-service-benchmark-report-insights) | Moderate (vendor) |
| First-time fix: 86% at the best performers vs 53% at the worst | Same | Moderate |
| EU: €12bn/year lost by replacing instead of repairing; 35 Mt of waste | [EPRS 2024](https://www.europarl.europa.eu/RegData/etudes/ATAG/2024/760425/EPRS_ATA(2024)760425_EN.pdf) | Strong |
| 26% of adults (OECD) at literacy level ≤1; Flanders 19% | [OECD PIAAC 2023](https://www.oecd.org/en/publications/survey-of-adults-skills-2023-country-notes_ab4f6b8c-en/belgium_7187249a-en.html) | Strong |
| Only 28% of EU 65–74-year-olds have basic digital skills | [Eurostat 2023](https://ec.europa.eu/eurostat/web/products-eurostat-news/w/ddn-20240222-1) | Strong |
| Lift technicians: 4–5 years of apprenticeship; vacancy rates above 8% | Industry reports (see the earlier search) | Moderate |
| US manufacturing: 1.9M jobs may go unfilled by 2033 | [Deloitte 2024](https://www2.deloitte.com/us/en/pages/about-deloitte/articles/press-releases/us-manufacturing-could-need-new-employees-by-2033.html) | Strong |
