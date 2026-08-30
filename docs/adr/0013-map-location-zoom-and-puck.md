# 0013 — Where the map goes when it finds you, and what it draws there

**Status: DONE 2026-08-30.**
**Date:** 2026-08-30
**Deciders:** Jerson Garcia (lead)
**Relates to:** ADR 0005 (flood colours / tilesets)

## What was wrong

**The map flew to zoom 14 and drew no marker at all.**

Jerson, on the simulator: *"I don't need to zoom in so much to level 14 because
streams are not visible at that level usually."*

He was right, and there is a hard reason: **`byu-hydroinformatics.nwm-channels-v3`
is tiled z0–12**, confirmed from its Mapbox metadata (`maxzoom: 12`). Above 12
there is no more stream data — Mapbox stretches the z12 tile, so lines thicken
and no new stream ever appears.

Measured viewport width on a Pro Max (440 pt) at latitude 40:

| zoom | m per point | screen spans |
|---|---|---|
| 9 (opening view) | 117 | 51.5 km |
| 12 | 14.6 | **6.4 km** |
| 14 (old location zoom) | 3.7 | **1.6 km** |

So zoom 14 discarded three quarters of the visible area and bought nothing. On
1.6 km of ground a small stream is often simply not in frame.

**And there was no location marker.** `LocationComponentSettings.enabled`
defaults to `false` and was never set, so the map flew to the user's position
and then gave no indication of where that was — the centre of the screen was
the only clue.

## Decisions

**1. Location zoom is 12, the tileset maximum.** The sharpest zoom the data
actually supports.

**2. Use Mapbox's own location puck, with its accuracy ring.** Jerson: *"if
mapbox already offers the location puck we could use that instead of
reinventing the wheel."* Correct — `enabled: true` plus
`showAccuracyRing: true` is the whole feature. The ring is drawn from the
radius the device itself reports, in real metres, so it shrinks and grows
correctly as the user zooms and needs no code of ours to stay honest. A precise
fix is a small dot; a poor one is visibly a circle.

**Rejected: zoom chosen from the accuracy radius.** Proposed before checking
what the plugin offered. With a real ring it is unnecessary complexity — a
vague fix simply draws a big circle, which tells the truth without any zoom
arithmetic.

**Not done: detecting iOS reduced accuracy.** `Geolocator.getLocationAccuracy()`
and `requestTemporaryFullAccuracy()` both exist and the app calls neither, and
`Info.plist` has no `NSLocationTemporaryUsageDescriptionDictionary`. Not needed
once the ring is honest, and recorded here so the next person knows it was
considered rather than missed.

**3. Centre on the FIRST open only; afterwards the recentre button.**
Recentring on every open was reasonable while there was no marker — the jump
was the only way to know where you were. With a puck it just takes the user
away from wherever they panned to.

The flag is **static**, because `_MapPageState` is recreated on every open and
an instance field would be false again on the second one — the gate would
never gate anything. Not persisted across launches: centring once per launch is
helpful, and a stored flag makes the app behave differently on day two for
reasons the user cannot see.

**The location is still REQUESTED on every open.** The puck needs a fix to
draw, and `initializeLocation` is what prompts for permission; only the camera
move is first-open-only.

## Unverified

**How far off an iOS approximate fix actually is.** Stated from memory as
"1–3 km" during the discussion and never checked — the ring makes the number
unnecessary for this design, but the claim was wrong to make. Cheapest test:
log `position.accuracy` (already on every `Position`, currently ignored) with
Precise Location toggled off, then on, in Settings → Privacy → Location
Services.

## Verified

Simulator, GPS set to Provo: blue dot renders, and the view at zoom 12 shows
the Provo River and several other channels across the frame — the streams that
were absent at 14. No visible ring, correctly: a simulated fix is exact, so the
ring is smaller than the dot.

Five mutations verified failing: zoom back to 14, zoom to 13 (still
overzoomed), accuracy ring off, the flag made non-static, and the puck dropped
from the style-load hook.
