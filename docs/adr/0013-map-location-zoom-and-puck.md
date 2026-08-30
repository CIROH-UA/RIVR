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

## 4. A refused location is no longer a silent dead end

Jerson, after the above shipped: *"what happens if location is not granted?"*

**Opening the map degraded correctly** — permission refused, `initializeLocation`
returns null, the map stays on the default view. Nothing broken.

**The recentre button did not.** Tapping it with location refused produced
**nothing at all**: no message, no prompt, no route to Settings. The service
logged an error and returned. The streams button beside it has shown a "No
Streams Visible" dialog for its own empty case since long before — the pattern
existed in the same file and this button did not use it.

**And no test covered any denied path.** The five guards written for the zoom,
the puck and the first-open flag touch permission nowhere. Asked directly, that
was the honest answer.

**`initializeLocation` returned `Position?`, collapsing four situations into
one null** — services off, refused, refused permanently, and simply no fix. The
caller could not say anything useful, or know whether Settings would even help.
It now records which, and the page shows a dialog with **Open Settings** —
offered only for the two states Settings can actually fix. A plain refusal can
still be resolved by the system prompt on the next tap, and a missing GPS fix
is not a permissions problem at all; offering Settings there sends people on an
errand and teaches them the button lies.

**A successful fix clears the denial**, or the first refusal would stick and
the dialog would appear over a working map.

**One of these guards was wrong when first written, and the mutation caught it
rather than the code.** Deleting the dialog CALL left the test green, because
the pattern reached far enough forward to match the method's own DECLARATION.
A guard that matches a definition instead of an invocation proves the method
exists, which nobody doubted. Fixed to match the call with its argument, and
re-verified.

### The field version had two defects a source guard could not catch

Asked "did you write the tests", the audit found the fix itself was wrong in
two ways — both invisible to the guards written for it, because both depended
on statement ORDER inside one method:

- **`recenterToDeviceLocation` falls back to `_lastKnownLocation`.** So a
  failed FRESH fix — `noFix`, usually the 10-second limit elapsing indoors —
  recorded a denial while the cached position still moved the camera. The map
  recentred correctly AND the user got "Can't Find Your Location" on top of it.
- **The not-ready early return skips `initializeLocation` entirely**, so a
  denial from a previous attempt was still sitting in the field and the page
  showed a permissions dialog for a map that had merely not finished loading.

**Two source guards were written for these and both passed the mutation that
reintroduced the bug.** Comment stripping shortens the source, so
distance-bounded patterns matched a different `_lastDenial = null;` than the
one intended. That is the third time in two days a guard matched the wrong
thing.

**So the shape changed instead.** `recenterToDeviceLocation` now RETURNS the
denial: one answer per outcome, no ordering to get wrong, and the field is
private with no accessor. The guards now pin the signature and the call site —
structure rather than distance — and the mutations that make the method `void`
again, or make the page read a field, both fail.

**The lesson, stated for the next time:** when a guard cannot see a defect, the
answer is usually to change the code's shape so the defect is not expressible,
not to write a more elaborate pattern.

## 5. First open recentres, then the map remembers (2026-08-30)

Jerson, after testing on the simulator: *"the map view does not remember the
last map location. Is that a good or bad UX?"*

**Making centring first-open-only had broken the reasoning that justified
discarding the camera.** The comment retiring camera persistence on 2026-08-20
said: *"It opens on the user's location when one is available and on the
configured default otherwise, so there is nothing to restore."* That stopped
being true the moment it only did so once. The result was worse than either
behaviour it replaced: pan to a river in Montana, close the map, reopen — and
you were on Provo at zoom 9, neither where you were nor where you are.

**The three options are not equal.** Always recentring is never wrong but
discards what you were doing. Remembering forever goes stale — a camera from
last week drops you on a river you looked at once, which is exactly why it was
un-persisted. First open recentres, then remembers, keeps both: once per launch
you land on yourself, and within that launch reopening returns you to what you
were looking at.

**Session memory only, deliberately.** Static on the page state, because
`Navigator.pushNamed` builds a fresh page every time; stored as plain numbers
so nothing holds a disposed platform object; never written to disk.

**Verified on the simulator, and the first attempt at verifying it was not
good enough.** Panning away and reopening produced an identical screenshot,
which is also what a failed back-tap produces. Re-run by backing out, confirming
the favourites list was actually on screen, and only then reopening: the map
came back to San Rafael Swell rather than Provo. Three mutations verified
failing — idle stops recording, open ignores the memory, and the field made
non-static.

### Static outlives the page — and it also outlived the ACCOUNT

Found by the audit behind "did you write the tests", not by a test.

Both `_hasCenteredOnUser` and `_rememberedCamera` are static so they survive a
page `Navigator.pushNamed` rebuilds on every open. That is deliberate and
necessary. **Static also survives a change of user**, and that is not, because
the two defects compound:

- The next person's map would open on the **previous person's river**. Where
  someone was looking is their business.
- `_hasCenteredOnUser` would already be `true`, so the next person would
  **never be centred on themselves** — they would land on the previous user's
  camera instead.

Sign-out already clears the biometric cache, user settings, the FCM token cache
and the river-data cache. `MapPageState.forgetMapState()` now sits in that
list. Three mutations verified failing: clearing only the camera, clearing only
the flag, and sign-out not calling it at all.

**Worth noting how this arrived.** The reasoning for making the fields static
was written out carefully in both places, and it was correct as far as it went
— it addressed the page lifetime and stopped there. A justification that is
right about the case you were thinking of is exactly the kind that hides the
case you were not.

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
