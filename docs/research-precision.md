# Precise pointing, 3D lock and spatial memory: research, assumption audit, architecture

31 October 2026. Written after five research passes (state of the art 2024–2026, Meta's models and API, MultiSet in depth) and the device tests of 31 October. No code was changed for this document.

## 1. What we want

| Goal | Target |
|---|---|
| G1 Correct | Pip points at the right thing every time, and refuses when unsure. |
| G2 Precise | Millimetres on small parts (a 1.5 cm key on a remote), centimetres on larger items and places. |
| G3 Locked | The outline stays on the object in 3D, also while it moves (in the hand, picked up, turned), for any object: flat or 3D. |
| G4 Remembered | Places and items are found again across rooms and days, with correct directions. |

## 2. What the research says

**MultiSet** ([how it works](https://docs.multiset.ai/quick-access/getting-started/how-it-works.md), [object tracking](https://docs.multiset.ai/fundamentals/object-tracking.md), public SDK source):
- Precision is centimetres, never millimetres: "median positional error of about 6 cm in well-mapped spaces" (claim); their own indoor benchmark ~9.5 cm / 1.1° median.
- Maps are keyframe databases matched by image features ("searches the map's database of reference frames … then computes an exact pose using feature matching and geometry"). Joining maps is done by visual overlap, which their docs call "far more robust than … ICP".
- Every fix is gated: confidence ≥ 0.3 and an optional consistency vote (a disagreeing fix needs agreement from viewpoints ≥ 1.5 m / 10° apart). Re-fix every 30 s, after tracking breaks, after backgrounding; content is hidden while unaligned.
- Capture hygiene: only normal, settled tracking; blur check; frames before a loss are dropped; raw `sceneDepth` on purpose (smoothed depth lags).
- ModelSet (object tracking) needs a textured metric 3D model, objects of at least 1 ft, and "the object itself must stay put". It does not track moving objects.
- Lesson: two tiers. A centimetre home tier brings things into view; an object tier measured in the object's own frame gives millimetres. MultiSet only has the first; Pip needs both.

**Tracking objects live on the iPhone:**
- Meta's [EdgeTAM](https://arxiv.org/abs/2501.07256) is the only SAM-2-style video tracker (with memory) that runs on an iPhone: 15.7 FPS on an iPhone 15 Pro Max (model time, 1024², Core ML). Seeded with a mask it is close to SAM 2 (77.0 vs 77.6 J&F).
- Meta's own Core ML export is image-only. A community conversion with the full video path exists: [jutsuhq/edgetam-coreml](https://github.com/jutsuhq/edgetam-coreml) (Apache-2.0; encoder + initializer + memory encoder + propagator; ~49 ms per tracked frame on an M4; known Neural-Engine attention-mask issue, fixed by its `--mask-empty-slots` build; young, no Swift example).
- Apple Vision's box tracker gives boxes only; no published model-free 6-DoF object tracker runs on a phone (FoundationPose, BundleSDF and others need desktop GPUs; BOP 2024 model-free tracking had zero entries).
- iOS 27 adds ARKit `trackingObjects` for moving objects, but only for objects trained for hours in Create ML from a 3D model; the test iPhone runs iOS 26.6.1.

**What LiDAR can and cannot do:**
- The 256×192 depth map is filled in by machine learning from a few hundred laser points at ~15 Hz; absolute accuracy about ±1 cm on objects larger than 10 cm, worse on small, dark or glossy ones. A 1.5 cm key gets 0–1 real depth samples.
- Depth gives distance, scale and rough shape. Millimetres on small parts must come from the image (masks, image tracking). A depth error does not move the outline in the current frame (the point stays on its ray); it only shows when the camera moves.

**Meta's models and API** ([segmenting](https://dev.meta.ai/docs/sam/segmenting), [pricing](https://dev.meta.ai/docs/pricing-rate-limits)):
- `sam-3.1` takes images and video (`input_video`: MP4/MOV, prompts on frames, `propagation_direction`, ≤ 16 objects, confidence per frame). Video costs $0.20 per 1,000 frames (50 frames minimum) against $2.50 per 1,000 images. Latency on video is not documented.
- The API has no 3D, embedding, streaming or on-device models. SAM 3D Objects and Locate 3D exist as research code only.
- Muse models ground best from a short, dedicated pointing prompt with one output shape, on crops for small targets; chain-of-thought lowers pointing accuracy ([PointArena](https://arxiv.org/html/2505.09990v2)).

**Relocalisation and object memory:**
- ARKit relocalises a saved world map well indoors under steady light, can stay `.relocalizing` indefinitely elsewhere, and cannot merge saved maps. One map grown by walking through the home relocalises from any room it saw ([Apple DTS](https://developer.apple.com/forums/thread/744206)).
- Geometry-only registration (ICP) is under-constrained when large planes dominate and confuses look-alike rooms; hybrid pipelines take the pose from visual matches and refine it with ICP.
- Vision-language models fall to chance on haystacks of ~50 images and miss small details; object memories that store per-object sightings (position + appearance) do better than caption memories.

## 3. Assumption audit

Evidence: device sessions of 31 October (look recordings, `session.log`, `tracking.log`, `map.log`), the re-run of all 49 recorded pointing targets, unit and simulation tests, and the research above.

| # | Assumption | Evidence | Verdict | Action |
|---|---|---|---|---|
| 1 | The model's rough point + SAM + printed-text/description check finds the right object | 49 recorded targets: 45 right, 4 refused, 0 wrong | Holds | Keep. Add high-resolution crops for small targets. |
| 2 | LiDAR depth can place small parts to the millimetre | ±1 cm, ML-filled, 0–1 real samples on a key | Wrong | Millimetres from the image; depth for distance and prediction only. |
| 3 | A pointed object stays where it was | Handheld remote: corrections of 2.5–11 cm | Wrong for movable objects | An object tier that follows the object. |
| 4 | A runtime reference image locks a flat textured object | Device: locked in ~2 s, 0.5–0.9 mm in hand | Holds (flat, textured only) | Keep as the millimetre stage. |
| 5 | Apple's box tracker can follow a small button | Boxes only, no rotation or depth; jumped to neighbours | Wrong tool | Drop (ImageFollower). |
| 6 | "Wait until it lies still, then re-measure" keeps outlines right | Lock lost → 9.7 cm jump; systems fought | Wrong as main path | Drop as main path. |
| 7 | Re-measuring from new views and fusing rays firms up static objects | Static corrections 0.06–0.35 cm | Holds | Keep for static objects. |
| 8 | Smoothed depth is best | Smoothing lags moving objects (Apple; MultiSet uses raw) | Wrong for moving objects | Raw `sceneDepth` for moving objects. |
| 9 | Session pieces can be linked by gravity-aligned ICP | Device: 43 attempts, 0 links, median 10 % inliers | Failed | Drop as the primary map; one home world map. |
| 10 | Apple feature prints tell places apart | Every distance 0.65–0.90 | Weak | Hints and guidance only, never decisions. |
| 11 | Give up relocalising after 8 s | Relocalisation can take longer and needs the user to look at a known spot | Wrong policy | Keep trying with guidance; never overwrite the home map from an unrelocalised session. |
| 12 | A VLM over 4×4 contact sheets finds small lost items | Haystack research; 4× smaller tiles | Doubtful | SAM 3.1 concept search over the snapshots (video "reel"), VLM verifies the top few at full size. |
| 13 | The camera's x axis is "right" | It is the sensor's long side; up/down when upright | Was a bug | Fixed (67965b9); add floor-pointing fallback and hysteresis. |
| 14 | Capture hygiene (settled tracking, sharpness, drop frames before a loss) | Same as MultiSet's scanner | Holds | Keep. |
| 15 | One fix is enough to move content | MultiSet gates every fix | Wrong | Keep voting on corrections. |

## 4. The architecture this calls for

**Home tier (centimetres):** one home `ARWorldMap`, relocalised at every start and extended as the user walks; places and keyframes stored as anchors in it; saved only after a real relocalisation and with `.mapped` status, with a few versions kept; MultiSet's re-fix policy and voting; directions from gravity and the view.

**Object tier (millimetres, also while moving):**
1. Point: keep the current pipeline (rough point → SAM 3.1 → printed text or description → check on a numbered crop; refuse when unsure).
2. Lock:
   - flat textured faces: ARKit image tracking of a runtime reference image (measured 0.5–0.9 mm);
   - any object, flat or 3D, handheld or not: EdgeTAM on the iPhone (Core ML), seeded with the SAM 3.1 mask from the snapshot, a new mask every frame at 10–15 fps; the outline is drawn from the mask (exact on screen), its 3D position from raw depth inside the mask, filtered;
   - small parts on an object: follow the whole object (large, distinctive) and carry the part along through the image lock or a homography inside the object's mask.
3. Lost: hide the outline, re-acquire with SAM 3.1 (the last seconds as a short video, or a fresh frame).

**Memory tier (centimetres to metres):** stored snapshots with depth and pose in the home map; "where did I leave X" runs SAM 3.1 concept detection over them (as one video, the cheap path) and lifts hits to 3D with the stored depth; Muse Wonder checks only the top few at full resolution.

## 5. What to verify before building (spikes)

1. EdgeTAM video Core ML on the iPhone 15 Pro with ARKit running: frame time, heat, mask quality against SAM 3.1. Go/no-go for the object tier.
2. SAM 3.1 video API: latency for 2 s of frames and for a reel of 100 snapshots; how it behaves across cuts between unrelated snapshots.
3. ARKit relocalisation in the home: success and time per room, day and night, after a relaunch.

## 6. Realistic precision

| Object | Expected |
|---|---|
| Flat, textured (remote face, panel, keyboard) | 0.5–1 mm (measured with the image lock) |
| Textured, not flat (shaver, printed cup) | 1–3 mm on screen from masks; 3D position about ±1 cm |
| Plain 3D object (white bust) | outline from masks; 3D position about ±1 cm |
| Places in the home, after relocalisation | 1–5 cm in the same room, more further away (to measure) |
| Lost items from memory | depends on detection; position about 3–10 cm |

## 7. Spike results

### T2: SAM 3.1 on video (31 October, from the Mac, Meta's API in standard mode, `store: false`)

**Re-acquiring an object from the last seconds.** Two seconds of synthetic hand motion: a 720×960 window slides over a recorded look frame by up to ~20 px per frame, so the truth is known on every frame. Box prompt on frame 0 for a 50×26 px key (pixels of 960×1280).

| Clip | First frame back | All frames | Centre error (median / max) | Box IoU (median / min) |
|---|---|---|---|---|
| 60 frames at 30 fps, 720×960 | 2.6 s | 5.9 s | 1.1 / 1.8 px | 0.91 / 0.86 |
| 20 frames at 10 fps, 720×960 (billed as 50) | 4.0 s | 4.4 s | 1.1 / 1.8 px | 0.91 / 0.86 |
| 20 frames at 10 fps, 360×480 (billed as 50) | 2.6 s | 3.0 s | 1.4 / 2.2 px | 0.89 / 0.82 |

Very accurate, but about 3 s per answer: far too slow to follow a moving object (that needs 10 fps or more on the phone). It is the right tool to re-acquire a lost object and to check the on-device tracker in the background.

**Searching the visual memory (the "reel").** 61 recorded snapshots as one video (720×960, 3.9 MB inline), one concept per request (watch, glasses, pen, remote control):
- 4.0–4.7 s and $0.012 per concept. The same 61 snapshots as single images: 9.5–9.8 s at 8 in parallel (1.15 s per call median) and $0.15.
- It found every snapshot that single-image SAM found (watch 3 of 3, glasses 10 of 12), plus 2–4 more per concept. The video tracker carries an object across a cut into the next, unrelated snapshot, with the same object id and the same confidence. One or three grey frames between snapshots do not stop it.
- Confidence belongs to the object's track, not to a frame, so it cannot rank snapshots. Where both modes found the object, the boxes agree (IoU median 0.97–0.98).
- Longer reels: 122 frames 6.0–6.5 s, 244 frames 9.7–10.7 s, i.e. about 3 s plus 30 ms per frame.

The reel is the cheap first pass: it gives candidates. Every candidate is then checked on its own snapshot (single-image SAM in parallel, and Muse Wonder for the top few) before Pip answers. Assumption 12 holds in that form.

### T1: EdgeTAM, first on the Mac (M4)

Same 60-frame clip, seeded with SAM 3.1's mask of the 50×26 px key (`pipeval edgetam`):
- The key was found on all 60 frames. Median centre error 1.5 px.
- On 9 of 60 frames the mask spilled onto a neighbouring key: the centre was 10–21 px off and the minimum box IoU 0.45.
- Speed: 11.7 ms in the encoder plus 34.9 ms in the propagator and memory bank, or 21 fps of model time. This matches the conversion's own figure of 49 ms per frame on an M4.

**On the iPhone 15 Pro, with ARKit running** (31 October, 4 runs: a keyboard key, glasses, the steam slider and switch of an iron; 614 frames). Each kept frame was compared with SAM 3.1 tracking from the same seed over the same frames:
- **Presence:** EdgeTAM and SAM 3.1 agreed on all 77 kept frames about whether the object was in view.
- **Overlap:** box IoU median 0.87–0.94 per object, minimum 0.50 on one slider frame.
- **Centre:** 1.1–1.3 px median of 720×960, at most 4.4 px.
- **Speed:** 95–102 ms per frame, or 9–10 fps (frame preparation 10 ms, encoder 19–22 ms, propagator and bank 66–69 ms). The mask is about 150–180 ms behind the live frame.
- **Cost to ARKit and heat:** ARKit stayed at 60 fps; the phone went from cool to warm.
- **Since then:** frame preparation is bilinear instead of Lanczos (same accuracy on the Mac clip, 1.4 px median), and dense output arrays are copied in one go.

Quality: go. Speed is enough to carry the outline at 10 Hz, with ARKit's camera motion in between.

**3D steadiness on the iPhone.** The object's centre in the room is the mask's centre at the median raw LiDAR depth. Over 5 runs and 383 frames, the camera moved and the objects mostly lay still:
- **Between consecutive updates** (about 0.1 s): median 0.7–2.3 mm per run, p90 3.7–9.5 mm.
- **Over a whole run** (distance from the run's mean position): median 2.3–7.3 mm, p90 4.3–17 mm.

Most of this is the raw depth's noise. On screen it shows less, because the mask itself is right to about 1 px.

Not measured yet: objects that move. From build 23:19 on, every update logs the drawn outline's offset in millimetres ("edgetam check"). Smoothing the depth over time is the next step if those numbers call for it.

It follows the object reliably. Small parts spill onto look-alike neighbours, so they should be carried by their parent object (the plan in section 4) or gated on area. The iPhone test decides the rest:
- speed with ARKit running;
- heat;
- real hand motion;
- the mask against SAM 3.1.

The app now has this test built in: `EdgeTAMSpike` (since 1 Nov `EdgeTAMFollower`), `Documents/edgetam.log`, and one frame per second kept for comparison.

### T3: the home map, automatic

The user never maps on purpose; Pip maps while it is used (`Relocalisation`, `Documents/relocalise.log`):
- At launch ARKit gets the map of the room used last. If it does not recognise it within 6 s, Pip tries the saved room with the most places and views, then maps the room as a new piece.
- A session extends the map of the room it recognised as the user walks, into new rooms too. Rooms therefore join by being walked through.
- A map is saved only when ARKit calls it `.mapped` or `.extending`, and never while the saved room is still being recognised. It is saved every two minutes when the map has grown, and when the app goes to the background.
- Pip says when the mapping needs the user's help, at most every three minutes:
  - "move a little slower", when ARKit reports excessive motion for 1.5 s;
  - "point at the room", when ARKit sees too few features for 3 s;
  - "look around", once per start, while recognition takes longer than 4 s.
- ICP linking of pieces is off (43 tries, 0 links).

Device results are pending.
