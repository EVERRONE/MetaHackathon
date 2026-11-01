# Spatial memory: one picture of the home across sessions

Goal: things Pip pointed at or saw are pinned in the home, found again in a later session, and Pip
knows where the user is. Built step by step; each step is measured before the next.

## Principles

- **The live session is never restarted.** Every session starts fresh (ARKit, gravity up) and
  tracks in coordinates of its own. Recognising a saved room with ARKit's world map kept tracking
  in its relocalising state for up to 45 s and restarted it twice, which moved outlines by a key
  or three and dropped them (1 Nov); it recognised the room about once in ten. Memory is a layer on
  top of the live session, worked out in the background.
- **Sessions are linked by what they saw, not by their surfaces.** A snapshot of each session,
  matched by described corners (FeatureMatcher), each match lifted to the room at its LiDAR depth
  in both sessions; gravity is shared, so a link is a turn about the vertical and a shift (four
  unknowns), fitted with RANSAC (PipCore `SessionLink`). Laying LiDAR surfaces onto each other
  linked 0 of 43 times (31 Oct): walls and floors slide along themselves.
- **A link is taken only when independent views agree.** Weak fits can be wrong by metres.
- **Things are carried by the views that saw them.** A session's own coordinates are not rigid:
  the same statue, lifted from two snapshots of one session a few seconds apart, landed 11-12 cm
  apart (a tracking break, or ARKit correcting itself). Carried by the link of the snapshot that
  saw it, it landed 0.7-3.2 cm from where the other session saw it; by another snapshot's link,
  9-13 cm.
- **Three levels of where.** Far: carried by the session's links (about 10 cm: enough for an arrow
  and a direction). Near: carried by the links of the snapshot that saw it (centimetres). In view:
  found again by the grounder at that place, then held by the live trackers (millimetres). An
  outline is drawn only when the object is confirmed on sight; in doubt Pip says when and where it
  was last seen, with the snapshot.

## Measured on the user's snapshots (31 Oct - 1 Nov, 344 snapshots, 11 sessions)

- `pipeval relocalise` / `pipeval links` (Sources/pipeval/Relocalise.swift).
- Two morning sessions (11:05 and 11:26): linked by 6 views with 840 agreeing matches, each view
  link to 0.4-0.8 cm; 14 more view links differ only by the sessions' drift, none conflicts.
- Two afternoon sessions (14:06, 15:08): four view links (the best 77 matches), all to one snapshot
  of the second session: one view is not independent evidence, so not linked offline; live, the
  session keeps adding views.
- Daylight against evening lamps: almost nothing matches (the light changes what the corners look
  like).
- No link between sessions that do not belong together.
- The statue test: the larger golden statue outlined by the grounder in two snapshots of each
  morning session and lifted at its depth; see the principle above.
- Live, simulated (`pipeval livelink`: one session's snapshots in the order they were taken play
  the live views): the 11:26 session was linked at its second view (10 s in) against the 11:05
  one; the other way round at view 31 (210 s, when the user reached the coffee table); the 15:08
  session at the 14:06 one's fourth view (62 s), one view link rejected. Live views come every
  1.5 s, more often than stored snapshots (every 25 cm or 20°), so linking is quicker live.
- The evening session (17:01) does not link to the morning ones: other light, and other
  viewpoints too (the laptop on the lap and the room from the couch, against the coffee table from
  above). Linking needs a place seen from about the same side.
- Local light normalisation before describing corners (each pixel against the brightness and
  contrast round it): every link was lost, also in the same light. Not used.

## Steps

1. **Within one session**: what Pip pointed at or saw is found again ("where did I leave…": the
   visual memory search over the last 30 minutes, the grounder in the snapshot, the outline in the
   room) and held when back in view. Mostly in place (GuideModel+Find); the remaining work is that
   found things are confirmed and held on sight like pointed-at ones.
2. **Linkable snapshots**: each stored snapshot's described corners with their room points
   (computed in the background, kept in memory).
3. **Linking, offline**: every pair of stored sessions; rules tuned to zero wrong links (done:
   `SessionLink` settings, `pipeval links`).
4. **The picture of the home**: sessions joined by their links; things carried by the views that saw
   them (`SessionLink.carry`, nearest evidence first).
5. **Linking live**: a background linker matches the live session's views against stored snapshots
   of sessions at the same place; a session is linked when two live views agree; links are kept up
   (a tracking break in the live session re-checks them).
6. **Things across sessions**: snapshots of a linked session become searchable and pointable in the
   live room (their poses carried by the links); remembered places of a linked session come back on
   anchors of their own, found again on sight.
7. **Light**: snapshots of every session are kept, so mornings and evenings both get views to link
   to, more with every session: the practical path. Local normalisation did not help (see above).
   Meta's DINOv2 (small, 22 M parameters, its 14-pixel patch features matched both ways and lifted at
   their depth, the same four-unknown fit; run on the Mac from the published weights): on the two
   morning sessions it finds the same links as the corners, coarser (1.3-2.6 cm against 0.4-0.8 cm,
   the turn less sure: -6° to -14° where the corners say -17° to -21°); across daylight and evening
   lamps it finds what the corners do not (14:06 against 17:01: 12 view links, the best 36 matches
   at 1.7 cm), but their turns spread from -12° to -25°: never within the 2° the rules ask (10° is
   50 cm at 3 m). So DINOv2 can say which stored view shows the same place across light; pinning it
   down needs a finer matcher on top (a dense one, or learned corners), with a Core ML conversion.
   Not in the app.
8. **Beyond home**: within one visit (a shop) the session's own snapshots already answer "where did I
   see…" (the last 30 minutes are kept in full, located in the live session). Across visits the same
   linking, per place on earth: the linker only matches sessions mapped at the same place
   (`SpaceLinker.keepOnly`, from the location of each session).

## Status (1 Nov, evening)

Steps 1-6 and 8 are in the app; 7 as far as accumulating views (DINOv2 measured, not enough alone). To be shown on the device: a session
linked to an earlier one (the log says "space: linked to the session of …"), things of the earlier
session found and pointed at here, remembered places back and corrected on sight.
