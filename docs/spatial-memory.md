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
- Replayed through the app's code (`pipeval livelink`, each session against all others, fingerprints
  first): the two morning sessions link to each other, at the moment their views overlap (174 s and
  219 s in); the other four sessions tried link to nothing, and nothing links wrongly.
- DINOv2 patches sharpened by laying LiDAR surfaces onto each other (point-to-plane, four unknowns,
  started from DINOv2's fit): the turns pulled together to a few degrees, but on the laptop (see
  Design): with the room rules, there was no cross-light link left in these sessions.

## Design

One core in PipCore decides; the app and the offline replay run it unchanged:

- `SessionLink`: two views → a view link (corners matched both ways, lifted at trusted depth,
  four-unknown RANSAC fit, at least 20 agreeing matches within 3 cm, median under 1.5 cm); several
  view links → a session link (`consensus`: two live views that agree to 4 cm and 2°, 80 matches,
  evidence over at least 1 m of the room) and the view links within drift that may carry points.
- Room, not contents: only points at least 0.8 m from the camera count. On 1 Nov the laptop, on the
  desk at 15:08 and on the lap at 17:01, gave six view links that agreed to a few degrees, perfect
  fits of the laptop, not of the room. Held things are near the camera, and a moved thing gives its
  evidence in one spot: the depth rule and the 1 m of evidence keep both out.
- `TrustedDepth`: the one rule for depth at a corner (five samples or more within 5 cm, the median),
  for stored snapshots and live views alike.
- `LinkBook`: per live session, the evidence per earlier session since the last tracking break, the
  links (linked, linked again after a break, strengthened) and carrying (a point by the links nearest
  it; a view by its own link first).
- `LinkSchedule` and `ViewPrint`: which stored views a live view is matched with. Matching costs a
  millisecond or two per pair, so each live view tries 60 of them: first the 20 that look most like
  it (Apple Vision's feature print), then the hot ones (stored views that linked lately and their
  neighbours), then the rest in turn. Measured: of 13 live views that link, the stored view they link
  to came first by fingerprint for 11, within 10 for 12, within 40 for all. Without the fingerprints,
  replayed through the app's own code, one of the two morning sessions never linked: each live view
  saw a fifth of the stored views.
- App `SpaceLinker`: describes the stored snapshots in the background (corners, depth, fingerprint),
  takes a sharp live view every 1.5 s, and reports to `GuideModel.spaceLinked` (snapshots carried,
  places back) and to the screen (status line "space").

## The home graph: one set of coordinates

A remembered thing has the 3D coordinates of the session that saw it. Once the live session is linked
to that session, the arrow points at those coordinates carried into the live ones. The home graph
(PipCore `HomeGraph`) makes that work also when the live session never saw the same place as that
session: every session link the live session makes is kept (`Documents/memory/home-graph.json`,
with the memory consent), and a thing is carried along the strongest chain of links. Each pair keeps
its strongest link; a link that closes a loop is checked against the chain it bypasses (20 cm and 8°:
two sessions' drift) and refused beyond; a link made afresh after the live session's tracking broke
replaces the old one. When that fresh link differs from the old one by more than a loop may, the break
moved the live coordinates, and every link of the live session from before the break goes (one of
them would refuse the fresh links as a broken loop); each comes back as its session links again.
A session linked to the live one directly is carried by its own view links (nearest evidence), never
by the chain: the chain is one rigid link and centimetres coarser away from its evidence.

Measured on the user's four coffee-table sessions (`pipeval home`): the five session links join them,
every loop within tolerance. The larger golden statue, outlined in the session that remembered it and
carried through the graph into the morning session it was never linked to directly (three links):
2.1 cm from where that session saw it (7.3 cm from another snapshot); into the other morning session
(two links): 3.5 and 3.8 cm. Within one session the same statue, lifted from two snapshots, lands
7-12 cm apart (a small shiny object: LiDAR sometimes measures the table behind it), so the chain is as
good as the measurements themselves.

## How to read a device test

- `space: N snapshots of M earlier sessions to link this one to`, then `space: … described (X ms
  each)`: what there is to link to, and the cost.
- `space: linked to the session of …: K live views agree (… matches, over … m of the room)`: a link,
  with its evidence.
- `space: … live views in the last minute, … view links; X ms per live view`: every minute.
- `space: N snapshots of that session can be pointed at here; places back: …`.
- `mark N reentry: corrected X cm`: a remembered place (or a thing found in memory) carried by a link
  and then found again on sight: X is how far the link carried it from where it really is.
- `space: the tracking break moved this session's coordinates; its links from before it are dropped`:
  a relink after a break that moved the live session (see the home graph).
- `space: the link to … disagrees with the home's other links by X cm; not kept in the home graph`:
  a refused loop (a look-alike place, or a drifted session).
- `space: N earlier sessions are of this place after all; linked to again`: a later location fix
  re-admitted sessions an older one had ruled out.
- `space: carried again by the link's evidence nearer to them: the pen by X cm`: a place brought
  back and not found on sight yet moves when the link gets evidence nearer to it (see below).
- `mark N: found again on sight (method); its stored place no longer counts`, or `mark N not found
  again (reentry: no pen where expected …)`: a stored thing found again by its description, or
  left where the link put it rather than moved onto another object.
- `the sighting of … is the remembered place …: pointed at that`: a memory search found the thing a
  place already holds; no second outline.

## Finding a stored thing again (2 Nov)

The device test of 2 Nov linked a session started in the bathroom to the one at the desk 7 m away;
the remembered pen came back 15 cm off (two walks of 7 m, about 1 %), on the ink bottle beside it.
Pip then took the ink bottle for the pen, "moved". Three rules since:

- **Carried again while the link grows.** A place brought back is carried anew, by the link's
  evidence nearest to it, every time the link gets stronger (`ARController.recarry`), until it is
  found on sight. Before, it kept the carry of the first link, made in the bathroom.
- **Found again by what it is, never by what lies there.** A stored thing (`ARController.carried`)
  is looked for in a wider region (half the frame), pointed at again by the model's own words for
  it (stored with the place: "the grey pen in the middle"), and taken only as an object of its kind
  or one the model pointed at (`Grounder.refinding`). Replayed on the desk photo with the expected
  point on the ink bottle: the old rule took the bottle, the new one the grey pen (3 of 3), and
  without a description it takes nothing rather than the bottle.
- **One object, one outline.** A memory search that confirms a sighting where a remembered place of
  that name already lies points at the place.

## Linking across light (2 Nov)

DINOv2 alone said which stored view shows the same place across light, but its fits were a few
degrees off (1 Nov: -12° to -25°). Laid onto the LiDAR surfaces from there they settle to under a
centimetre: walls, floors and furniture are where they were whatever the light.

- **What is held close is left out.** On 2 Nov most DINOv2 links were on the laptop, which the user
  had turned between the sessions: they laid perfectly (0.5 cm) and said 20°, the room 4°. Points
  nearer than 0.8 m to the camera count on neither side, as for the corners.
- **The surfaces decide.** A link is kept when at least 30 % of the stored view's surface lies within
  1.5 cm of the live one's, at 1 cm root mean square across it, and the depth corrected DINOv2's fit
  by at most 12° and 35 cm. Each match the depth kept counts as three corners in the session link
  (`DinoLink.Settings.evidenceWeight`): two or more live views must agree (4 cm, 2°) over a metre.
- **Drift with distance.** A link from another part of the home may differ from the agreeing core by
  20 cm plus 6 cm per metre between their evidence (`SessionLink.Settings.driftPerMetre`) and still
  carry what lies near it: the day and low-sun links differed by 30 cm at the desk, 5 m from the hall
  views of the core, and the pen at the desk is carried by the desk's own links.

Measured with `pipeval dinolinks` (the app's code, the Core ML model on the Mac):

| Sessions | Light | Corners | DINOv2 + depth |
|---|---|---|---|
| 2 Nov 15:22 → 15:31 | same | linked live (bathroom) | linked, 8 views over 6 m |
| 2 Nov 15:22 → 16:40 | day → low sun | 1 view link, not linked | linked, 4 views over 3 m |
| 2 Nov 15:31 → 16:40 | day → low sun | not linked | linked, 2 views over 4.8 m |
| 1 Nov morning ↔ night (4 pairs) | morning → lamps | linked | linked, the same turns within 1.5-2.7° |
| 1 Nov living room close-ups | afternoon → evening | not linked | not linked (all within 0.4 m: left out) |

No session of another room linked. A chain of two DINOv2 links (morning → morning → night) landed
within 1° and 4.4 cm of the direct one. The live view takes about 3 ms to match and lay on the Mac
per stored view; DINOv2 itself about 75 ms per view on the Mac (the iPhone's Neural Engine: to be
measured), on a queue of its own.

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
7. **Light** (2 Nov, in the app): described corners link sessions in the same light only; on 2 Nov
   the same rooms at 15:22 in daylight and at 16:40 in low sun gave one corner view link and the
   session was never linked. Beside them, every 3 s, `DinoLink`: Meta's DINOv2 (ViT-S/14, Core ML,
   `ios/scripts/convert-dinov2.py`, in the app bundle) describes the live view, its three most alike
   stored views (DINOv2's whole-view token) are matched patch by patch, each match lifted at its
   LiDAR depth, a turn and shift fitted (RANSAC), and that fit laid onto the surfaces (`DepthAlign`:
   point to plane, the turn about the vertical and the shift), which light does not move. See
   "Linking across light" above.
8. **Beyond home**: within one visit (a shop) the session's own snapshots already answer "where did I
   see…" (the last 30 minutes are kept in full, located in the live session). Across visits the same
   linking, per place on earth: the linker only matches sessions mapped at the same place
   (`SpaceLinker.keepOnly`, from the location of each session).

## Status (2 Nov, evening)

Steps 1-8 are in the app: the light-robust linking (step 7) since 2 Nov; to be shown on the device
across a change of light.

## Status (1 Nov, evening)

Steps 1-6 and 8 are in the app; 7 as far as accumulating views (DINOv2 measured, not enough alone). To be shown on the device: a session
linked to an earlier one (the log says "space: linked to the session of …"), things of the earlier
session found and pointed at here, remembered places back and corrected on sight.
