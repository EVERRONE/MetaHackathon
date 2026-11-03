# Submission texts

For the form at https://cerebralvalley.ai/e/meta-ai-developer-hackathon/hackathon/submit. Deadline Wed
4 Nov 2026, 21:00 ET (5 Nov, 03:00 CET); our own target is 4 Nov, 18:00 CET.

- **Project name:** Pip
- **Track:** Indie Developer
- **Theme:** Build for Your World
- **Repository:** https://github.com/EVERRONE/MetaHackathon
- **Demo video:** _the unlisted link, also added to README.md_
- **Team:** every member added on the submission

## One-liner

An iPhone guide you talk to while you work with your hands: it points at exactly what to touch,
stays locked on it in 3D, checks what you did, and remembers where you left things.

## Description

People get stuck on hands-on tasks every day: a coffee machine that will not start, a fuse box, a
lift installation, a pen put down somewhere. The knowledge exists. What fails is applying it to the
thing in front of you.

Pip looks through the iPhone camera while you talk to it. For each question one streamed Muse Wonder
call answers in speech with inline pointing cues. The targets are found while the sentence streams:
SAM 3.1, on-device text recognition, a second pointing by Muse Spark for small parts, and a choice
between look-alikes. Pip refuses rather than guess. Each outline is laid on the LiDAR surface and
anchored in 3D, and it appears on the word it belongs to. On-device EdgeTAM keeps it on the object
while the phone and the object move.

For a device, Spark with Meta's web search finds the manufacturer's manual for that exact model and
shows the source on screen. Pip then guides step by step: a deterministic runtime owns the progress,
the camera checks each step, and safety rules in code stop the task.

Pip also remembers. It links each session to earlier ones by what they saw, with Meta's DINOv2 on the
phone laid onto the LiDAR surfaces, so it recognises a room in any light within seconds. From the
bathroom it says where you left your pen in the bedroom, about seven metres to your right. On sight it
finds that very pen again, not the one beside it.

## Meta models and tools

- **Muse Wonder 1.0:**
  - every look (speech with pointing cues);
  - plans compiled from a manual or from paper instructions;
  - searching the phone's own snapshots;
  - describing remembered objects.
- **Muse Spark 1.3:**
  - pointing again at small parts;
  - choosing between look-alikes;
  - checking steps through the camera;
  - the shopping basket;
  - looking up the exact model's manual.
- **SAM 3.1:** every candidate instance and its mask, by concept and by point.
- **Muse Voice Transcribe 1.0:** realtime, hands-free speech recognition in English and Dutch.
- **Meta's web search tool:** official manuals and support pages.
- **EdgeTAM**, on device (Core ML): following the pointed-at object.
- **DINOv2 ViT-S/14**, on device (Core ML): recognising rooms across a change of light.

The voice is ElevenLabs, the only non-Meta model, because Meta has no text-to-speech model.

## Built during the hackathon

- The repository started on 30 Oct 2026. Over 120 commits followed, all written during the
  hackathon.
- It contains the iPhone app, a Swift package with the perception and its 188 tests, an evaluation
  tool that replays recordings from the phone, and a Cloudflare Worker with 28 tests.
- No code comes from earlier projects. The README lists every third-party component and its licence.

## Measured

- **Pointing:** 49 recorded targets, 45 right, 4 refused, 0 wrong.
- **Tracking:**
  - EdgeTAM runs at 9-10 fps on an iPhone 15 Pro while ARKit stays at 60 fps.
  - The outline moves by a median of 0.7-2.3 mm between updates.
- **Look-alikes:** of three pens side by side, the remembered one was found again from its photo 3
  of 3 times.
- **Spatial memory:**
  - Remembered places brought into a new session were found on sight 2.3-5.0 cm from where Pip
    pointed.
  - Recognising a room went from 12.6-25.6 s down to 5.8-7.9 s in replays of real sessions.

## What's next

- Pip on Meta's glasses, hands free.
- Importing your own manuals.
- Sharing a home's memory between the people who live there.
- A technician mode for installations such as lifts, where "which one of these" costs the most.
