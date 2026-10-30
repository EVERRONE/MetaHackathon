# Pip — product brief

**Pip** (Personal Interactive Partner) looks at a problem through your phone camera, points at exactly what to touch, checks what happened, and walks you through it safely.

Version 1.0 (draft), 30 October 2026. This brief fixes **what** we build for the Meta Global AI Developer Hackathon; `build-plan.md` covers **how**.
It replaces the assembly-task scenario in `productdefinitie-visuele-taakbegeleider.md`. That document's principles still apply: verified procedures, explicit step progression, no fake answers, no overclaiming.

## 1. The problem

**The power goes out at home.** The lights are off, the freezer is silent, and the heating pump has stopped. Somewhere in the hallway or the basement there is a panel full of identical switches.

- Most people cannot tell the main switch from a residual-current device (RCD, *verliesstroomschakelaar*) or a circuit breaker.
- They do not know that a tripped RCD means an appliance somewhere is leaking current, so resetting it blindly fails again.
- Nor do they know the safe procedure for finding the faulty circuit.

What they do instead:
- **Wait and pay:** an emergency electrician call-out, often for a fault they could have isolated themselves in five minutes.
- **Call someone:** a family member or neighbour, and try to describe a panel over the phone.
- **Do something unsafe:** open the cover, force a lever, or keep resetting a device that keeps tripping.

The people hit hardest are older people living alone, tenants, people new to the country who cannot read the labels, and anyone alone at night with children.

**OPEN:** we need 2–3 credible numbers for the write-up, for example on electrician call-outs, how many people do not know their panel, and accidents caused by unsafe DIY. We only use figures we can source.

## 2. What Pip does

You open Pip and point the camera at the panel. Pip:
1. **Recognises the panel.** It identifies the main switch, the RCDs and the circuit breakers, and reads their labels.
2. **Finds what tripped.** It highlights the device whose lever is down and explains it in plain words, for example: "This is your residual-current device. It switched off because something is leaking current. We'll find out what, safely."
3. **Runs a safety check first.** If there is a burning smell, water near the panel or visible damage, Pip stops and tells you to call an electrician, or 112 if there is fire or smoke. These rules are enforced in code, not just in a prompt.
4. **Guides the isolation procedure step by step.** For each step it points at the exact switch and checks the result on a new camera frame:
   - switch off all breakers under the tripped RCD;
   - reset the RCD;
   - switch the breakers back on one at a time;
   - the one that trips it again is the faulty circuit, so leave it off;
   - unplug the appliances on that circuit and try again.
5. **Restores what it can.** Power comes back on every healthy circuit, so you are no longer in the dark.
6. **Hands over.** Pip writes a short summary for the electrician: what tripped, which circuit is faulty, and what was tried. This makes the call-out shorter and cheaper.

The simpler case is also covered: a single breaker tripped because of overload, for example a kettle and a heater on one circuit. Pip guides you to reduce the load and reset it.

Pip only guides what a layperson may do: operate switches, levers and test buttons on the front of the panel. **It never tells anyone to open a cover or touch wiring.**

## 3. Why this is a strong fit for the technology

| Pip has to… | Meta model doing it |
|---|---|
| Hear the question, hands-free, in English or Dutch | Muse Voice Transcribe |
| Find every switch in a dense row of identical devices | SAM 3.1 (instance segmentation of every device) |
| Tell which device is which, read its state (lever up or down) and read the labels | Muse Spark 1.3 (vision, grounding, reading), checked against the SAM instances |
| Decide the next safe step, explain it and write the electrician summary | Muse Spark 1.3 (reasoning, structured output) inside a code-enforced procedure |
| Verify that the action happened | SAM + Spark on a fresh frame: "breaker 3 is now up" |

The procedures are generic: RCDs and breakers behave the same in every European home. So Pip works on **any standard panel** without needing a manual per product. A one-time **panel scan** lets you confirm Pip's map of your panel (labels and grouping); it is stored only on your device, so it is ready before an emergency.

## 4. Scope

**In scope**
- An installable iPhone web app (PWA) at `pip.unveil.be`.
- Live camera, voice and text input, and spoken answers.
- Recognition of the panel's devices and their states, with overlays that point at the exact switch.
- The safety gate, tripped-RCD isolation, the tripped-breaker overload case, and a stop/escalation path.
- Verification of every action on a fresh frame, plus explicit user confirmation.
- An optional panel scan and confirmation, stored on the device.
- The electrician hand-over summary.
- The "How Pip sees" panel, showing the models at work.
- English by default, with a Dutch option.

**Out of scope**
- Anything behind the cover.
- Fuse-type (screw-in) panels; we may detect them and explain that they are not supported.
- Wiring diagnosis, the water and heating scenarios, glasses, accounts, and native apps.

**Hard safety rules**, enforced in code:
- Never instruct opening the panel, touching conductors, or bypassing or taping a device.
- Stop and escalate on smell, smoke, heat, water, sparks or visible damage.
- Stop and escalate if the RCD trips again with all circuits off.
- Never claim an installation is safe. Pip only reports what it can see.

## 5. Demo and video story (about 3 minutes)

1. **Cold open, 0:00–0:25.** Evening, the lights go out. A person stands in front of a panel with a phone torch: "Which one is it?" One sourced statistic on screen.
2. **Pip, 0:25–1:50.** A real run on a real panel:
   - Pip highlights the tripped device and explains it;
   - it runs the safety check;
   - it guides the circuits on one by one, verifying each switch;
   - the faulty circuit is found;
   - the power comes back on;
   - the summary for the electrician appears.

   For the trip, we press the RCD's own test button or create a real overload on one circuit. No fake states are used.
3. **How Pip sees, 1:50–2:30.** The same run, showing how the three models work together and check each other, with real latency and accuracy numbers.
4. **Impact and vision, 2:30–3:00.** Who this helps, and the same engine for water leaks and heating. Then professionals: onboarding technicians in skilled trades, such as new lift technicians at Verolift.

## 6. Success criteria for the hackathon build

- The full scenario (tripped RCD → isolation → restore → summary) works live on a real panel, on fresh frames.
- It is honest under uncertainty: if Pip cannot see a lever clearly, it asks for a better view instead of guessing.
- Measured on held-out photos of real panels:
  - device detection rate;
  - accuracy of lever-state reading;
  - **zero confident wrong "this one" pointers**;
  - median latency.
- A short test with 1–2 people who do not know their panel.

## 7. Open questions

1. **The panel.** Where is the panel we will film, at home or at work, and which brand and type is it? How many RCDs does it have, and are the circuits labelled? Photos would help a lot.
2. **The person on screen**, and whether the video uses English voice-over or Dutch with subtitles.
3. **Belgian specifics** to check: a 300 mA main RCD plus a 30 mA RCD for wet rooms, and the main switch near the meter.
4. **Low light.** Whether Safari can switch on the phone torch from the app; otherwise the user holds a light.
