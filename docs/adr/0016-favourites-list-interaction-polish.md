# ADR 0016 — Why the favourites list feels unpolished

**Status:** Accepted — fixes landed 2026-11-02
**Date:** 2026-11-02
**Trigger:** Jerson, 2026-11-02: *"the card slide to show more options has
something that does not make it look professional or smooth and I don't know
what it is."*

This ADR is the running log for a UX review of the favourites list and the
three tools behind a card (Background, Rename, Delete). Findings are labelled
**Measured / Estimated / Unverified / Disproven** and nothing moves out of
Unverified without a check.

## Scope

In: the swipe-to-reveal interaction, the three action buttons and their
destinations, and the list page around them.

Out of scope, settled elsewhere, do not reopen:
* Removing per-card freshness badges (ADR 0011 Phase 7 — silence means current).
* The swipe hint itself (ADR 0015).
* Showing a third alert control on the card (deliberately refused — the
  setting lives on the river's own page).

---

## Measured

Method for the first three: a throwaway widget test that pumped
`FavoriteRiverCard` at iPhone 16 Pro metrics (393 × 852 pt, DPR 3), drove the
slide fully open and printed the global rectangles of the card and of each
action button. Numbers are from that run, 2026-11-02.

### 1. The card moves 10% less than the finger that drags it

| | |
|---|---|
| Finger travel for a full open | **216 pt** (`totalActionWidth`, the denominator in `_handlePanUpdate`) |
| Card travel for a full open | **195.1 pt** |
| Ratio | **0.903** |

The card lags the thumb by a constant 10% for the whole gesture. This is a
tracking error, not a smoothing curve — direct manipulation is supposed to be
1:1 under the finger.

**Cause.** `SlideActionConstants.getSlideOffset` returns
`-(totalActionWidth / screenWidth)`, but `SlideTransition` multiplies its
offset by the width of **its own child**, and the child is the card, which is
38 pt narrower than the screen (`margin: horizontal 19`). So the fraction is
computed against one width and applied to another:

```
card travel = (216 / 393) × 355 = 195.1 pt      (not 216)
```

### 1b. The first 40 pt of every swipe are thrown away

Measured on a booted iPhone 17 Pro Max simulator (440 pt wide), 2026-11-02,
by driving a real `FavoritesPage` through `flutter drive` and stepping one
pointer 10 pt at a time, printing the card's translation after each step:

| Finger travelled (pt) | 10 | 20 | 30 | 40 | 50 | 60 | … | 240 |
|---|---|---|---|---|---|---|---|---|
| Card moved (pt) | 0.0 | 0.0 | 0.0 | 0.0 | −9.1 | −18.3 | … | −182.7 |

**The card does not move at all until the thumb has travelled about 40 pt**,
and the distance already covered is then discarded rather than applied — at
50 pt of finger the card has moved 9.1, which is `(50 − 40) × 0.914`, not
`50 × 0.914`.

**Cause.** The card listens with `onPanStart/Update/End`. A pan recogniser
must beat `kPanSlop` before it is accepted, and Flutter sets
`kPanSlop = kTouchSlop * 2 = 36.0` logical pixels
(`packages/flutter/lib/src/gestures/constants.dart:65,76`). `_handlePanStart`
only then captures `_dragStartX`, so everything before acceptance is lost.
A horizontal drag recogniser (`onHorizontalDrag*`) is accepted at
`kTouchSlop = 18.0` — half the dead zone, half the discarded distance — and,
being single-axis, also stops competing with the list's vertical scroll
(see finding 11).

**Combined with finding 1, the card ends a 240 pt swipe 57 pt behind the
thumb**: 40 pt lost to the dead zone and ~17 pt to the 9% scale error.

### 2. The card never fully uncovers the first action button

Measured rectangles with the row open, in screen coordinates:

| Element | Left | Right |
|---|---|---|
| Card (open) | −176.1 | **178.9** |
| "Background" button (blue, leftmost) | **158.0** | 253.0 |
| "Rename" (orange) | 226.0 | 316.0 |
| "Delete" (red) | 294.0 | 374.0 |

The card's right edge rests at 178.9 while the first button starts at 158.0 —
**20.9 pt of the blue button stays underneath the card**, permanently, in the
resting open state. Same root cause as finding 1.

### 3. The error changes with screen width

It is `216 × 38 / screenWidth`. Measured at 393 pt (20.9). *Estimated* for
other devices — see the Estimated section.

### 4. The action buttons are mounted and unmounted, never animated

`favorite_river_card.dart` builds them as `if (_isSliding)
_buildActionButtons(...)`. `_isSliding` flips to true on the first drag pixel
and false when the close animation ends. There is no fade, no slide, no
scale: three full-colour buttons appear in one frame and vanish in one frame.
iOS's own row actions are *uncovered* by the row, which is why they read as
physical.

### 5. The whole row shrinks 2% while you drag it

`_handlePanStart` sets `_isPressed = true`; the `AnimatedContainer` wrapping
**both** the buttons and the card applies `scale(0.98)` over 150 ms, and
`_handlePanEnd` releases it. So the row shrinks as you grab it and springs
back as you let go, on top of the horizontal slide.

### 6. Closing from a button looks different from closing by drag

`_closeSlide()` sets `_isSliding = false` **first** and then calls
`reverse()`. The buttons disappear instantly and the card glides back over
empty space. `_handlePanEnd` does the opposite — it waits for the animation
and clears the flag in `.then()`. Two closes, two different looks.

### 7. Tapping an open row does nothing

`onTap: _isSliding ? null : widget.onTap`. The expected behaviour — and the
iOS one — is that a tap anywhere closes the open row. Here the tap is simply
swallowed, which is indistinguishable from the app being frozen.

### 8. Picking a card up to reorder snaps instead of easing

`_proxyDecorator` receives the drag `animation` and ignores it, returning a
constant `Transform.scale(scale: 0.95)` inside an `AnimatedBuilder` that
therefore animates nothing. The card jumps to 95% in one frame.

### 9. The list is not lazy, and every card owns a video player

`_buildReorderableList` uses `ReorderableListView.builder` with
`shrinkWrap: true` and `NeverScrollableScrollPhysics` inside a parent
`CustomScrollView`. `shrinkWrap` forces every item to be built and laid out
immediately, so a user with twenty favourites gets twenty
`VideoPlayerController`s at once. The card already staggers initialisation by
`100 ms × cardIndex` to avoid exhausting Android's decoder slots — that
workaround exists because of this.

### 10. ~~The last card sits under the add button~~ — WRONG, see Disproven

### 11. Three gesture recognisers compete for the same pixels

The card uses `onPanStart/Update/End`. A pan recogniser claims both axes, so
it enters the gesture arena against the parent scroll view's vertical drag
**and** the reorderable list's long-press drag. `_handlePanUpdate` filters
per-event with `horizontalDelta > verticalDelta`, which corrects the maths
but not the arena. `onHorizontalDrag*` would yield to a vertical scroll by
construction.

### 12. Smaller things, all read from source

* `slide_action_constants.dart` comments `// 156px` beside a value that is
  `(80 × 3) − (12 × 2)` = **216**.
* Button labels fake their alignment with literal leading spaces
  (`'   Delete'`, `'     Rename'`, `'  Background'`) and ad-hoc icon padding
  (20/30/15). Widths differ (95/90/80) with 12 pt overlaps.
* No haptic when the row latches open; the only `HapticFeedback` on the card
  is on long-press.
* Opening a second row does not close the first, and scrolling does not close
  either.
* `favorites_page.dart` empty state: `CupertinoColors.systemGrey2..resolveFrom(context)`
  — a cascade, so the resolved colour is discarded and the dynamic colour is
  never resolved for dark mode.
* The navigation bar has no title; a 45 pt "RIVR" wordmark is drawn in the
  body instead, consuming ~77 pt above the list on every visit.
* The add button is a Material floating action button in a Cupertino app.

### 13. Rename dialog

* The field is seeded with `favorite.customName`, which is **null** until the
  user has already renamed once — so the first rename opens an empty box and
  the existing name cannot be edited, only retyped from scratch.
* The text is not selected on open, so typing appends rather than replaces.
* `Save` is not `isDefaultAction`, so it is not bold, and the keyboard's
  return key does nothing (`onSubmitted` is unwired).
* An empty field silently does nothing on Save — no error, no disabled state.
* The `TextEditingController` is never disposed.

### 14. Background picker (`image_selection_page.dart`)

* Five segments in one `CupertinoSlidingSegmentedControl`, labelled at
  **`fontSize: 10`** with an icon beside each. Apple's floor for legible UI
  text is 11 pt, and the size is fixed rather than scaling with Dynamic Type.
* Switching category sets `_selectedImagePath = null`, so looking at another
  category discards the image you had picked — and the Save button with it.
* The background **currently in use is not indicated**. Nothing marks which
  one you already have.
* `Save` is rendered only when a selection exists (`_selectedImagePath != null
  ? CupertinoButton(...) : null`), so it appears and disappears from the
  navigation bar instead of being present and disabled.
* The grid's padding is `EdgeInsets.all(16)`; the floating action pills sit at
  `bottom: 20` over the top of it, so the last row of images is permanently
  partly covered.
* The delete control on a custom image is a 16 pt icon in 6 pt of padding —
  a **28 pt** target against Apple's 44 pt minimum — and it is hidden when
  the tile is selected (`if (isCustomImage && !isSelected)`), so the image you
  just tapped cannot be deleted.
* Two filled pills sit side by side as equal primaries: blue "Flow animation"
  and green "Upload image". Green is not an iOS primary-action colour, and
  "Flow animation" does not say that it *removes* the photo.
* The selection border is 3 pt and appears inside the tile's decoration, so
  selecting shifts the image by 3 pt.

### 15. Seen in the screenshots, not in the source

Captured from a real simulator through `flutter drive`, 2026-11-02.

* **The background picker opens on an empty tab.** "Custom" is category index
  0 and the page starts there, so the first thing after tapping Background is
  "No custom images yet" — the two dozen bundled backgrounds are one tap away
  and invisible. Every new user meets an empty screen.
* **The category is named twice, two rows apart.** The segmented control says
  "Mountain" with a snowflake; immediately below, a header repeats
  "❄ Mountain Rivers". One of them is redundant and it costs ~44 pt of grid.
* **"Large" is the short label for "Big Water"**, which reads as an image
  size rather than a kind of river.
* **Every thumbnail is dimmed by a gradient that serves nothing.** Unselected
  tiles carry a 40 pt black bottom gradient "for better contrast" — there is
  no text on a tile, so it only darkens the picture being chosen.
* **The rename dialog does not say which river it is renaming** and opens on
  an empty field: the title is the generic "Rename River", and "Provo River"
  appears nowhere, so the user must retype a name they can no longer see.
* **The delete button says Delete; its dialog says Remove.** Button "Delete",
  dialog title "Remove Favorite", confirm action "Remove". One action, two
  verbs.
* **The open row loses the card shape.** Closed cards are inset 19 pt with
  12 pt corners; the open one runs off the left edge of the screen, so for the
  duration it stops reading as a card at all.

---

## Estimated

**The uncovered strip of the first button, by device.** Derived from the
measured formula `216 × 38 / screenWidth`, not measured on each device:

| Device | Logical width | Estimated shortfall |
|---|---|---|
| iPhone SE (3rd gen) | 320 pt | 25.7 pt |
| iPhone 16 / 16 Pro | 393 pt | 20.9 pt *(measured)* |
| iPhone 16 Pro Max / 17 Pro Max | 440 pt | 18.7 pt — **since measured, see below** |

**The 440 pt row is now Measured, not estimated.** The same `flutter drive`
run recorded the card coming to rest at **−197.3 pt** on a 440 pt screen.
`216 × 402 / 440 = 197.3`, so the formula is confirmed on a second device
width and the shortfall there is `216 − 197.3` = **18.7 pt**, exactly as
derived.

---

## Unverified

**Which of these defects dominates the feeling Jerson described.** The
ranking is a perceptual judgement and cannot be settled by reading source or
by measurement — all twelve are real, and which one the eye catches first is
exactly the thing he could not name.

*Cheapest test:* fix findings 1, 2, 4 and 5 (they are small, independent
edits), build to TestFlight, and have him swipe a card before and after. If
the feeling is gone after those four, the rest are polish rather than cause.

**Whether the three-way gesture competition (finding 11) produces missed or
stuttering swipes in real use.** The arena conflict is real in the source;
its user-visible cost is not established.

*Cheapest test:* on a device, scroll the list quickly with a slight
horizontal component and count how often a row starts to open instead of
scrolling; repeat after switching to `onHorizontalDrag*`.

---

## Disproven

**"The last card sits under the add button."** I read the list's own
`padding: EdgeInsets.only(bottom: 20)` and stopped there. The scroll view
also carries a sibling `SliverToBoxAdapter(child: SizedBox(height: 100))`
immediately after the list, so the real clearance is 120 pt against an add
button that reaches 106 pt up from the bottom. There was never an overlap.
Found while implementing the fix, 2026-11-02 — a reminder that a padding
value means nothing without its siblings.

**"The action strip is 156 pt wide."** `slide_action_constants.dart` says so
in a comment, and I repeated it before checking. `(80 × 3) − (12 × 2)` is
**216**. The measured button rectangles confirm 216 (158.0 → 374.0). The
comment is stale and should be deleted rather than corrected — the expression
is already self-explanatory.

---

## Decision

Jerson, 2026-11-02: *"Go ahead and do all of that."* — the slide mechanics
fixed in place, the action strip rewritten, the page-level items included.
**Not rebuilt from scratch**: the card is 862 lines and the defective gesture
layer was 164 of them, so a rewrite would have thrown away the 81% the
screenshots showed working while still not touching the four findings that
live in other files.

### What changed

| Finding | Change |
|---|---|
| 1, 2, 3 | The card is translated by **exact pixels** (`Transform.translate`) instead of a `SlideTransition` fed a fraction of the wrong box. `getSlideOffset` and `getSlideOffsetWithMargin` are deleted; `totalActionWidth` is the single number |
| 1b, 11 | `onPanStart/Update/End` → `onHorizontalDragStart/Update/End`. Slop halves from `kPanSlop` (36) to `kTouchSlop` (18), and the recogniser stops competing with the list's vertical scroll and the reorder drag |
| 4 | The strip is mounted while `_slideController.value > 0`, inside an `AnimatedBuilder`, so the card **uncovers** it instead of the buttons appearing in one frame |
| 5 | `_isPressed` is no longer set on drag start — the 2% squeeze is now only the long-press grab |
| 6 | `_closeSlide` routes through `_animateClosed`, which clears `_isSliding` *after* the animation, matching the drag-end path |
| 7 | A tap on an open row closes it (`_isSliding ? _closeSlide : onTap`) |
| 9 | `ReorderableListView.builder` + `shrinkWrap` → `SliverReorderableList`, with each item wrapped in a `ReorderableDelayedDragStartListener`. The list is lazy again; Material is no longer imported by the page |
| 12 | Haptic on latch-open. The `// 156px` comment is gone. The button strip is rewritten: three equal 72 pt buttons in a `Row`, one radius, no overlaps, no faked label spacing, icon excluded from semantics so VoiceOver reads the action once |
| 15 | The delete dialog says **Delete**, matching its button, instead of "Remove Favorite" / "Remove" |

Also: the deprecated `onReorder` is replaced by `onReorderItem`, which
removes the manual `if (newIndex > oldIndex) newIndex--` correction and the
last analyzer warning in the repository.

### Follow-up: the open card's corner notch

Reported by Jerson from the after-screenshot, same day, and he was right:
with the row open, the card's rounded top-right and bottom-right corners sat
against the flat left edge of the blue button, and the page background showed
through as two white wedges. Flush everywhere else made it more obvious, not
less — the fix above removed every other seam and left this one.

The card's right-hand corners now square off as it opens, eased over the
first 16 px of travel so the corner unrolls rather than snapping (a 12 px
corner changing in one frame is the same class of pop this change set
exists to remove). The left corners stay rounded: that edge is still a card
edge, and it slides off the screen.

Guarded both ways — the test asserts the right corners are rounded when
closed and square when open, and both mutations (always rounded, always
square) are caught.

### Second pass: the background picker (finding 14)

| Was | Now |
|---|---|
| Opened on "Custom Images", empty for anyone who has never uploaded one | Opens on the first category that has pictures in it |
| Changing category set `_selectedImagePath = null` | The selection survives; only the grid changes |
| `Save` built only when a selection existed, so it came and went from the navigation bar | Always present, disabled until there is a change to save |
| Nothing showed which background the river already used | The applied one carries an **In use** badge, is preselected, and the picker opens on its category |
| Grid `padding: all(16)` under floating buttons at `bottom: 20` | 96 pt of bottom padding, so the last row clears them |
| Delete badge: 16 pt icon in 6 pt padding = **28 pt** target, and hidden once the tile was selected | 16 pt icon centred in a **44 pt** target, shown whether or not the tile is selected |
| Five segments, each an icon plus a **10 pt** label | Labels only, **12 pt**; "Large" is now "Big Water" |
| A header repeating the category name and icon two rows under the tab | Gone; only the Custom tab keeps a one-line count |
| Blue and green filled pills as equal primaries; "Flow animation" never said it removes the photo | One blue primary ("Upload your own image") over a plain "Remove photo, use flow animation" |
| 3 pt selection border appearing on tap, shifting the image | Border always present, transparent when unselected |
| A 40 pt black gradient dimming every unselected thumbnail "for contrast", over tiles that carry no text | Gone |

Four guards, four mutations, all caught: open on Custom again, clear the
selection on category change, hide Save until something is picked, drop the
In-use badge.

### Not done, deliberately

* **Opening one row does not close another, and scrolling does not close an
  open row** (part of finding 12). Both need a shared notifier across cards
  rather than a change inside one, and that is a different kind of edit from
  everything above. Left for its own change so this one stays reviewable.

### Verification

`flutter analyze`: **clean, zero issues** — the `onReorder` deprecation that
had been there throughout is gone.

`flutter test`: **1,447 passing** (1,440 before; 7 new guards).

**Six mutations, all caught:**

| Mutation | Caught by |
|---|---|
| Restore the screen-width fraction | finger-tracking **and** full-reveal guards |
| Mount the buttons only once the row is fully open | "uncovered, not popped in" |
| Swallow the tap on an open row | "a tap on an open row closes it" |
| Restore the 2% drag squeeze | "the row does not shrink while being dragged" |
| Revert to the `shrinkWrap` list | both laziness guards |

One of those guards was **vacuous on first writing** and the mutation pass is
what exposed it: the shrink test used `tester.getSize`, which reports the
layout size and is blind to a scale transform, so it passed with the squeeze
still in place. It now uses `tester.getRect`, which projects to screen space.

### Re-measured after the fix

Same method as the original measurement — `flutter drive` on a booted
iPhone 17 Pro Max, stepping one pointer 10 pt at a time.

| Finger travelled (pt) | 10 | 20 | 30 | 40 | 50 | … | 230 | 240 | at rest |
|---|---|---|---|---|---|---|---|---|---|
| **Before** | 0.0 | 0.0 | 0.0 | 0.0 | −9.1 | … | −173.6 | −182.7 | **−197.3** |
| **After** | 0.0 | 0.0 | −10.0 | −20.0 | −30.0 | … | −210.0 | −216.0 | **−216.0** |

* The dead zone halved, 40 pt → 20 pt, exactly as `kPanSlop` → `kTouchSlop`
  predicts.
* Tracking is **1:1 to the pixel** past that point: every 10 pt of finger is
  10.0 pt of card, where it used to be 9.1.
* The card rests at **216.0 pt**, the full width of the strip, so the first
  button is no longer clipped. It used to rest at 197.3.
* Total lag at the end of a 240 pt swipe: **24 pt, down from 57**, and all of
  what remains is the recogniser's slop plus the clamp at full open.

**Unverified, still:** whether the feeling Jerson described is gone. That
needs his thumb on a real phone. No build has been made — he asked to hold
off.
