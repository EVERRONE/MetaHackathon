# Demo video: production plan (2:55)

One continuous story in a garage: a person whose lights went out, a washing machine, a bottle seen on
the way, and the someone who stands beside them. Every interaction with Pip is real and live; Pip's
answers are not scripted and vary from take to take. Waiting is cut and marked on screen ("⏩ 18 s"),
never hidden. The point of the video is the vision: what Pip is for, and why it matters.

## The story, beat by beat

A = Pip's own take: its screen (camera, outlines, captions, cards) with its voice and yours, recorded
by Pip itself (see "Recording").
B = a second camera filming the person, the phone in hand, the fuse box and the machine.

| Time | Beat | Picture | Sound | On screen |
|---|---|---|---|---|
| 0:00-0:15 | **The human opening** | B: a wide shot of the garage: the fuse box, the washing machine; a hand hesitating at the panel. Calm, warm light. | Voice-over, slow: "Think of someone who made you feel capable. Someone who stood beside you, showed you where to start, and gave you the confidence to try. We all need that someone sometimes." Soft piano under it. | — |
| 0:15-0:45 | **The lights are off** | A, with B for the hand: at the fuse box, "Pip, my lights are off. How do I turn them on again?" Pip asks you to come closer: hold the phone about 30 cm from the row, the row across the screen. The outline and the arrow on the breaker that is down; you push it up; the light comes back (B). | Your voice; Pip's real answers. | small: *real interaction, waiting cut and marked* · lower third: *Muse Wonder sees which breaker is down · SAM 3.1 finds that exact one · locked in 3D on the LiDAR surface* |
| 0:45-0:55 | **On the way** | A and B: you walk to the washing machine past the blue bottle on the shelf; the phone looks at it for two seconds. Nothing is said. | Footsteps, the room. | — |
| 0:55-1:50 | **The washing machine** | A: "Pip, walk me through setting this machine for a cotton wash." Show the type plate (the rim inside the door). The search card: the manufacturer's manual for this exact model. The ring on the dial (turning arrow), the temperature, the spin; the green check when Pip has seen it; Start. | Pip's real answers; you: "Yes." | ⏩ *the search* · lower thirds: *Muse Spark + Meta web search: the manual for this exact model* · *Muse Spark checks the camera image* |
| 1:50-2:15 | **Where was it?** | A: "Pip, where's the blue cleaning product?" Pip looks back through what it saw; the arrow at the screen's edge points the way; as you turn, the outline on the bottle. Let the last words stand. | Pip's real answer. | ⏩ *Pip searches what it saw* · lower third: *Muse Wonder searched the snapshots on the phone* |
| 2:15-2:40 | **Why Pip** | A montage of the moments: the arrow on the breaker, the ring on the dial, the green check, the outline on the bottle. | Voice-over: "Not everyone has that someone. A parent who lives alone. A newcomer who can't read the manual. Anyone afraid to break something. The knowledge is there, in every manual. Pip brings it to the thing in front of you: it sees what you see, points at exactly what to touch, and checks that you got it right. So everyone can take care of their own home, with confidence." | *Built on Meta's models: Muse Wonder 1.0 · Muse Spark 1.3 · SAM 3.1 · Muse Voice Transcribe · Meta web search · and on the phone, EdgeTAM and DINOv2* |
| 2:40-2:55 | **Back to the beginning** | B: the opening wide shot, the machine running, the light on, you walking out. | Voice-over: "We all need that someone sometimes. Pip can be that someone." | **Pip** · *points at exactly what to touch* · github.com/EVERRONE/MetaHackathon · team |

## Why each beat is there

- The first 15 seconds say who it is for; the product is on screen by 0:15.
- Judges compare with assistants that only talk about what they see. The video shows what they do
  not: the one breaker that is down among identical ones, the manual for **this exact model** with
  its source, the ring **on** the dial and staying there when the phone moves, the check **by the
  camera**, and the way back to something it saw in passing.
- The vision carries it: not everyone has someone beside them; Pip brings the knowledge in every
  manual to the thing in front of you.
- Each Meta model is named at the moment it does its part, and all of them at the end.
- Marked time jumps show it is live and honest.

## Before the shoot

**The app**
- The build of the day, opened once for two minutes after installing.
- English. Memory consent already given (the question would interrupt a take).
- Before each take: the reset button (arrow), so earlier questions do not come back.
- Developer lines only behind the eye button: leave it off.

**The phone**
- Charged, Do Not Disturb, brightness up, auto-lock off, sound up, silent mode off.
- Pip's settings (the brain), Demo video: "Record takes for the video" on (see "Recording").

**The set**
- Garage lights on plus one warm lamp for the opening; no light behind the machine.
- Glass door of the machine at an angle so it does not mirror the lamp.
- Nothing personal in view (post, screens, other people).
- The blue bottle on a shelf on the way to the machine, at chest height, in good light, a few
  metres from the machine and out of its view, so that at the end Pip first shows the way.
- One breaker switched off for the scene, and a light on that circuit in view of B.

**The second camera**
- A second phone on a tripod: 4K, 30 fps, HDR video off (Settings, Camera, Record Video), so its
  colours match the take's.
- Exposure and focus locked (long press), landscape.
- For the fuse box and the dial, a helper films over your shoulder.

## The shoot (in this order)

1. **A first run, recorded:** the whole story once. Every run is a take, so a good one is kept.
2. **B-roll, 10 minutes:** the wide shots, the hand at the panel and the dial, the drum.
3. **The whole story, 2-3 complete takes, A and B at once.**
   - Start B first, then close Pip's settings: the take starts. Open them again to end it.
   - One clap in view of B at the start: the check on the lining up (it is done by the sound).
   - Stay in Pip during a take: another app or the lock button ends it.
   - The fuse box: when Pip asks, come close, about 30 cm from the row, the row across the screen;
     from further away the model can point a breaker beside the one that is down.
   - The bottle: on the way, the phone on it for two seconds; say nothing.
   - The machine: show the type plate (the rim inside the door), so the manual is this model's.
   - Do the whole interaction in one go, as it comes; ask for the bottle at the end, from the
     machine.
   - Keep the best take whole and cut only the waiting.
   - Between takes: the breaker off again, the bottle back in its place.
4. **The closing B-roll.**
5. **The voice-over** in a quiet, soft room (a wardrobe works).
   - Phone 20 cm from the mouth.
   - Three takes, slow, warm, as if to one person.

## Recording

iOS's own screen recording does not do: Pip's voice processing (which keeps Pip from hearing
itself) keeps a call's audio out of it, so it has no sound, and it shows the red dot. Pip records
its takes itself:

- **What:** Pip's screen through ReplayKit inside the app (no red dot, no status bar; HEVC, 30 fps),
  Pip's voice as it is played (digital, without the room), and the microphone after voice
  processing (your voice without Pip's), all on one clock, with what was said and shown when.
- **When:** while "Record takes for the video" is on, from closing the settings until opening them
  again or leaving Pip. With the switch on at launch, the take opens on Pip's launch screen.
- **iOS asks** to allow screen recording in Pip ("Record Screen") the first time, and again after
  eight minutes without.
- **On the Mac** (the takes show the home: they stay out of the repository):
  - `python3 ios/scripts/takes.py pull` copies them to ~/Movies/Pip takes.
  - `python3 ios/scripts/takes.py build <take>` makes `<take>.mp4` (the screen at 30 fps with both
    voices, levelled), each voice alone (`-pip.wav`, `-you.wav`), subtitles for each
    (`-pip.srt`, `-you.srt`) and a timeline of what was said and shown when (`-timeline.txt`).
  - `python3 ios/scripts/takes.py sync <take> <B clip> --write` finds where B lies on the take by
    its sound and makes `<clip>-synced.mp4`, which starts with the take: both go at 0:00.

## Editing

- **Format:** 16:9, 1920×1080 (or 4K).
  - B full frame, with A as a phone-shaped window on the right.
  - At the key moments, A full screen and zoomed in: the arrow on the breaker, the ring on the dial,
    the green check, the outline on the bottle.
- **Captions:** lower third for each Meta model at its moment (the timeline gives the moments);
  clean subtitles for your words and Pip's (the take's .srt files); ⏩ marks for every jump.
- **Music:** soft piano under the opening and the end only (YouTube Audio Library or another source
  free of rights). Under speech: off or very low.
- **Sound:** the take's voices under A and B (clean and level); B's own sound only for the room
  (the machine, low). The whole about -14 LUFS for YouTube.
- **Length:** 2:50-2:58, never over 3:00.
- **Export:** H.264, 1080p, high bitrate.
- **Upload:** YouTube unlisted.
  - Title: *Pip, points at exactly what to touch (Meta AI Developer Hackathon)*.
  - Description: the repo link and the models.
  - Open the link in a private window to check it plays.
- Made on the Mac from the takes (pulled and built with scripts/takes.py), the B clips (AirDropped
  to ~/Movies/Pip takes/B), the voice-over (Voice Memos, AirDropped) and the music, if any.

## If a take goes wrong

- **Pip points at the wrong thing:** "No, the other one". Keep it if Pip corrects itself, otherwise
  retake.
- **Pip asks for the type plate:** keep it; it shows it reads this exact machine.
- **The check does not come:** hold the phone 30-50 cm from the dial, steady. Pip asks you to
  confirm after two tries; keep that or retake.
- **The search finds no manual from the manufacturer:** the card says so in yellow; retake, or keep
  it if Pip says it honestly.
- **Pip talks over you:** tap the microphone button once.
- **The outline on the wrong breaker:** come closer to the row and ask again: "Which one is it?"
- **Pip does not find the bottle:** walk past it again with the phone on it for two seconds, then ask
  again.

## Schedule

**Tuesday evening**
- A full rehearsal of the wash and the keys, not filmed.
- Then the logs: time per step, the source found, the outlines, the check.
- What goes wrong is fixed and installed that night.

**Wednesday evening (the deadline is Thursday 03:00 CET, 21:00 ET)**
- 19:45-21:00 shoot; 21:00 voice-over.
- 21:30-01:00 edit; about 01:30 upload.
- The form (docs/submission.md); submitted by 02:00 CET at the latest.
