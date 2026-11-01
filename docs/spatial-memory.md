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
   to; descriptors that hold across light (learned corners and matchers on the Neural Engine) are the
   next lever.
8. **Beyond home**: within one visit (a shop) the session's own snapshots already answer "where did I
   see…"; across visits the same linking, per place on earth.
