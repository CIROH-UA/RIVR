# 0012 — Renaming a GEOGLOWS river had no way back

**Status: DONE 2026-08-30.**
**Date:** 2026-08-30
**Deciders:** Jerson Garcia (lead)
**Relates to:** ADR 0011 (cloud data layer), ADR 0003 (weekly outlook)

## The problem, as reported from a device

Renaming an NWM favourite shows a **"Restore to White River"** button, so the
rename is reversible. Renaming a GEOGLOWS favourite showed nothing, so once
renamed there was **no way back to the geocoded place** ("Pitumarca, Peru")
short of deleting the favourite and re-adding it.

Reported 2026-08-29 and deliberately deferred: *"this might be more like a
favorite card design thing that does not belong to this ADR 0011."*

## Why it was not a one-line fix

The button is gated on `favorite.riverName`. **GEOGLOWS publishes no river
name at all**, so that gate is false for every GEOGLOWS reach — and the name
its card actually shows is not on the entity either. It is a reverse-geocoded
place resolved asynchronously *inside `FavoriteRiverCard`'s own state*, and the
rename dialog is built by the **page**, which cannot see into a card.

So the real question was where that resolved label should live.

## Decision — cache it in the provider

Three options were on the table. Jerson chose the provider, 2026-08-30.

| Option | Why not |
|---|---|
| Promote onto `FavoriteRiver` | The entity would carry a field that is null for every NWM reach, populated asynchronously, and derived rather than user data. |
| Pass down from the card | Inverts the ownership — the page builds the dialog; a card would have to push state upward for a sibling concern. |
| **Cache in `FavoritesProvider`** | **Chosen.** It is exactly the shape of the per-reach session state already there, and `_sessionReturnPeriodUnits` is the precedent sitting immediately above it. |

**It deliberately does not `notifyListeners()`.** Every visible card geocodes
independently, so notifying would rebuild the whole list once per card on first
paint — to publish a value nothing rebuilds for. The only reader is the rename
dialog, on open. Same reasoning as the return-period unit beside it.

**An empty label is refused.** A restore button that restores to nothing is
worse than no button: it looks like a working control that wipes the name.
Null correctly means no button, exactly as an NWM reach with no name gets none.

## The part that was not asked for, and why it was done anyway

`FavoriteRiverCard` called `GeocodingService`'s **static** `placeLabel`. ADR
0011 recorded this file as one of two surfaces still doing so and left it to a
later phase.

A static cannot be faked, so **nothing could test that the label reaches the
provider** — and reaching the provider is the entire fix. The card now resolves
`IGeocodingService` from the DI graph. ADR 0011's note has been corrected;
`map_search_service` remains.

## What is tested, and what is not

**Behaviourally tested** (`favorites_provider_place_label_test.dart`): the
label round-trips, an unknown reach is null rather than empty, blank labels are
refused, caching does not notify, removing a favourite forgets its label, and a
later label replaces an earlier one. All six mutation-checked.

**Source-level guards only** (`geoglows_restore_wiring_test.dart`), and they
say so: that the card publishes, that it uses the interface, and that the
dialog reads the label rather than gating on `riverName` alone. Exercising
these properly needs a widget harness for a card that plays video, loads
images and reads several providers, and none exists. Comments are stripped
before matching, because a guard a comment can satisfy is not a guard — this
repository learned that twice on 2026-08-30 alone. All three mutation-checked
by reintroducing the original defect.

**VERIFIED end to end on the iPhone 17 Pro Max simulator, 2026-08-30**, signed
in as the account that actually holds GEOGLOWS favourites. The whole journey:

1. GEOGLOWS card showed its geocoded place, "Pitumarca, Peru" (reach
   `620569308`).
2. Swipe → Rename. **No restore button**, correctly — the reach has never been
   renamed, and the button requires an existing custom name.
3. Renamed it, saved. Card became the custom name.
4. Swipe → Rename again. **"Restore to "Pitumarca, Peru"" appeared** — the
   defect this ADR exists for.
5. Tapped it, saved. Card returned to "Pitumarca, Peru".

**The sync half was confirmed in the same pass**, which the widget tests
cannot reach: the user document now holds
`"geoglows:620569308": "Pitumarca, Peru"`, so the restored name went to
Firestore and a flood alert for that river would use it. Both the old bare-id
keys and the new source-prefixed ones are present, exactly as this ADR's
sibling documented — old keys are not migrated, and the next rename writes the
new one.

**Still not verified:** the same journey on physical hardware. The simulator
shares the app binary and the real Firestore backend, so what remains untested
is the device-specific layer only.

## Not changed

Restoring sets the custom name to the place label, matching what NWM already
does rather than clearing the name. Changing that would alter NWM behaviour
that nobody reported a problem with.
