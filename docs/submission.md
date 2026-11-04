# Submission texts

For the form at https://cerebralvalley.ai/e/meta-ai-developer-hackathon/hackathon/submit. Deadline Wed
4 Nov 2026, 21:00 ET (5 Nov, 03:00 CET); our own target is 4 Nov, 18:00 CET.

- **Project name:** Pip
- **Track:** Indie Developer
- **Theme:** Build for Your World
- **Repository:** https://github.com/EVERRONE/MetaHackathon
- **Demo video:** https://www.youtube.com/watch?v=zzNGSxwbZ0k
- **Team:** every member added on the submission

## One-liner

An iPhone guide you talk to while you work with your hands: it points at exactly what to touch,
stays locked on it in 3D, checks what you did, and remembers where you left things.

The answers below are the texts as entered in the form.

## Project description

Everyone knows the feeling. Someone is trying to help you over the phone. "The button on the left." "Which left?" "The small one." "There are three small ones." Or you pause a video for the fifth time, searching your own machine for what the person in the video has on theirs. The knowledge exists. It just never reaches the spot where your hands are.

So we give up, wait for someone, or guess. And guessing with your hands costs broken parts, lost hours, and sometimes real danger.

Pip closes that gap. You talk to it while you work. It looks through your iPhone, finds the manual for your exact model, and outlines the exact part as it names it, locked to it in 3D. You move, it stays. You act, it checks. Something's unsafe, it stops. And it remembers where things are, in this room and the next.

AI has learned to see and to talk. Pip makes it point. Not a description, not a box on a screen: this one, here.

It would rather say "I'm not sure" than guess. Across 49 recorded targets: 45 right, 4 refused, 0 wrong.

Today, Pip is an iPhone app built on Meta's models. Tomorrow, it's on your glasses: an expert at your side for anything you do with your hands.

## Describe your use of Meta products to build the submitted project

Meta's models do the core of Pip: they hear you, understand the scene, find the exact part, follow it as you move and remember your home. A Cloudflare Worker keeps the API keys off the phone and sends every chat, responses and SAM request to the Meta Model API with store: false.

Muse Wonder 1.0 is the brain of every turn. Each question is one streamed call that answers in speech with inline cue tags (outline, ring, move, rotate, place, danger, landmark and more), so Pip finds its targets while the sentence is still streaming. Wonder also compiles a step-by-step plan from the official manual, or from paper instructions held up to the camera, with a source reference per step. It searches the phone's own snapshots ("where did I leave my keys?") and describes a remembered object from its reference photo.

Muse Spark 1.3 does the fast, focused checks. It points a second time on a zoomed crop for small targets, picks the right one from numbered outlines when there are look-alikes, checks your work every few seconds in watching mode (two positive checks in a row turn a step green) and ticks off shopping-list items it sees in the basket.

Meta's web search tool, called through Spark, finds the manufacturer's manual or support page for the exact model, read from the type plate. The Worker checks that the link exists; the app shows the source on screen, with a warning when it is not the manufacturer's.

SAM 3.1 turns a pointing cue into pixels: every candidate instance and its mask, by concept and by point, on an enlarged crop and on the whole frame. The Worker decodes the masks with @meta-sam/parser; the app lifts each outline onto the LiDAR surface and anchors it in 3D.

Muse Voice Transcribe 1.0 makes Pip hands-free: realtime speech recognition with endpointing, in English and Dutch. Pip starts working on its answer as soon as you stop talking.

On the phone, two Meta research models run in Core ML. EdgeTAM follows the pointed-at object at 9-10 fps on an iPhone 15 Pro while ARKit stays at 60 fps, with a gate that never lets the outline jump to a look-alike. DINOv2 ViT-S/14, laid onto the LiDAR surfaces, links a session to earlier ones across a change of light, so Pip knows which room you are in. Asked from the bathroom where the pen was, Pip pointed the way at once, "about seven metres", and found it on sight within 5 cm of where it had been carried.

Together: Wonder decides what to say and what to point at, Spark and SAM make the pointing exact, EdgeTAM keeps it there, Voice Transcribe keeps your hands free and DINOv2 gives Pip a memory of your home. On 49 targets recorded with the iPhone: 45 right, 4 refused rather than guess, 0 wrong.

## Why are Meta's models important to your solution?

Pip exists to point at the exact part, in 3D, and Meta's models are what make that possible. Pip's own work, placing things in the room, keeping them there and remembering them, is built on what these models give it. Without them, Pip could only describe what it sees.

They answer with places, not only words. Muse Wonder answers in speech with pointing cues in the same stream, so Pip knows what to point at while the sentence is still being spoken. SAM 3.1 turns each cue into an exact mask of the object. That mask is the foundation of Pip's 3D placement: Pip lays it on the LiDAR surface and anchors it in the room. A 3D outline is only as good as the 2D mask under it; starting from SAM's mask, it holds still to within a millimetre or two between updates.

They let Pip be sure, or say it is not. A guide that points at the wrong switch is worse than none. SAM 3.1 returns every instance of a concept, not one box, so Pip sees all the look-alikes. Muse Spark then looks again at small parts on a zoomed crop and chooses between numbered outlines. When it cannot tell them apart, Pip refuses. On 49 recorded targets: 45 right, 4 refused, 0 wrong.

They keep the object, on the phone. EdgeTAM is a Meta model from the same family as SAM and starts from SAM 3.1's mask: the cloud finds the object, the phone follows it at 9-10 fps, and the 3D anchor moves with it. DINOv2 keeps Pip's 3D memory valid over time: it recognises a room after the light has changed, where corner matching found almost nothing, so places stored in an earlier session are found again. Both are open, which is what lets them run on the device.

They tie each step to the truth. Spark with Meta's web search finds the manual for the exact model on the type plate. Wonder turns it into a plan with a source for every step, and Spark checks your work through the camera every 3 seconds.

They keep your hands free. Muse Voice Transcribe hears you in Dutch and English and knows when you have finished speaking, so you talk to Pip without touching the phone.

What makes them important together is that they form one chain: hearing, understanding, finding, following and recognising, in one API and two open models that fit onto it. SAM's mask feeds EdgeTAM, Wonder's cues feed SAM, Spark checks what they found. Pip adds the third dimension and the memory; Meta's models make every point in it the right one.

## Feedback on partner technologies (Fireworks, Modal, ...)

Not used: Pip calls the Meta Model API directly, through our own Cloudflare Worker.

## How likely are you to recommend Muse Code?

Not used for this project.

## What was the biggest obstacle your team hit while building this project?

Our biggest obstacle was look-alikes: making Pip point at the right key or breaker when the one next to it looks exactly the same, often less than two centimetres away.

Pip's whole promise is "this one", so close was not good enough. And no single model solved it for us. Muse Spark understood what was meant, but its own point for a small key could be a key off. SAM 3.1 drew exact masks, but sometimes merged neighbouring breakers into one. EdgeTAM followed the object well, but in our first test its mask spilled onto a neighbouring key on 9 of 60 frames. Each time, Pip would have pointed confidently at the wrong switch.

We got past it by making the models check each other. SAM 3.1 finds every candidate, Pip numbers them, and Spark only chooses which number is meant, on an enlarged crop for small targets. EdgeTAM starts from SAM's mask, and a gate stops the outline from ever jumping to a look-alike. When Pip still cannot confirm the target, it refuses and asks for a closer view.

The result: of 49 recorded targets, 45 right, 4 refused, 0 wrong. What we learned is that for a guide in the physical world, refusing is better than guessing.

## Compared with other AI models your team has used for the same kind of work, how did Meta's models perform on this project?

In Pip we compared Meta's models head to head with the alternatives we had on the iPhone itself, Apple's on-device vision and classic computer vision. Where precision mattered, Meta's models made the difference.

Following an object: Apple's box tracker gives only a box and jumped to the neighbouring button. EdgeTAM, started from SAM 3.1's mask, follows the object's exact shape at 9-10 fps on the phone, with the 3D outline holding still to within a millimetre or two.

Recognising a room: classic corner matching found almost nothing once daylight had turned into evening lamps. DINOv2 did link across a change of light: in an afternoon session linked under evening lamps, 21 of its 25 view links came from DINOv2.

Pointing: rather than trusting any model's box, Pip lets SAM 3.1 find every instance with an exact mask and lets Muse Spark choose between them. That combination gave 45 right, 4 refused and 0 wrong on 49 recorded targets.

Honesty: when Spark was not sure, it said "unclear" instead of guessing. In our first test, listing 14 circuit breakers at low effort, it got 8 right, called 6 unclear and got none wrong; at medium effort, 14 of 14. For a guide that must never point at the wrong switch, that matters more than speed.

Voice: Muse Voice Transcribe understood Dutch as well as English, and ended a turn 0.2-0.4 s after the user stopped speaking.

Compared with the camera assistants we looked at, which describe the scene or draw a box at best, Meta's models let Pip go further: the exact part, as a mask, placed in 3D and kept there.

## If your team took this project to production, what would most likely stop you from using Meta's models?

Not the quality of the models: they are why Pip works. What would most likely stop us is what a product needs around them.

1. Stability. Pip is a live, hands-free conversation, so it depends on every part behaving the same tomorrow as today. During the hackathon, realtime transcription in diarization mode stopped ending turns, with no change on our side, and Pip went silent until we switched to endpointing. In production we would need versioned behaviour, notice before changes, and a status page we can rely on.

2. Latency. A guide has to answer while your hands are still on the task. Even at minimal effort, Spark still reasons for a few hundred tokens before it answers. A true no-reasoning mode, or a faster small model for short checks, would make the first word come sooner.

3. Data handling. Pip sees the inside of people's homes. We already send every chat and SAM request with store: false, but before real users, especially in Europe, we would need clear terms on retention, processing location and use for training.

4. A complete stack. We added a separate voice provider and used a community conversion to run EdgeTAM's video tracking on the iPhone. Text-to-speech and official on-device builds (Core ML, a Swift SDK) would let us stay entirely with Meta.

None of these is about what the models can do. Solve them, and we would build Pip's production version on Meta's models.

## Built during the hackathon

- The repository started on 30 Oct 2026. Over 140 commits followed, all written during the
  hackathon.
- It contains the iPhone app, a Swift package with the perception and its 195 tests, an evaluation
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
