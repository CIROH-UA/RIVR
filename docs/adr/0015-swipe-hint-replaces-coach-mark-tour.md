# ADR 0015 — A swipe hint replaces the first-run coach-mark tour

**Status:** Accepted
**Date:** 2026-11-02
**Decision owner:** Jerson Garcia
**Supersedes:** the `tutorial_coach_mark` tour shipped in 1.0.0+5 (2026-02-22)

## Context

The favourites list ran a four-panel onboarding tour the moment a user saved
their first river. It was built on the `tutorial_coach_mark` package and
worked like this:

| Panel | What it explained |
|---|---|
| 1 | pull down to refresh |
| 2 | swipe a card left for actions |
| 3 | the settings menu in the navigation bar |
| 4 | a "search tip", chained on after the others |

Three properties made it invasive rather than helpful:

1. **It blacked the screen out** to 90% opacity, so the river the user had
   just saved — the thing they opened the page to look at — was hidden behind
   the explanation of how to look at it.
2. **It was built with `hideSkip: true`.** There was no skip control. The only
   way out was to tap through every panel to the end.
3. **It fired on the first save**, which is the single moment a new user is
   most engaged with their own content and least interested in a lesson.

Jerson's assessment, 2026-11-02: *"the tour is a good thing but only to
discover that there are actions behind the favorite cards. Anything else is
redundant and not needed."*

That reading is right on the merits. Pull-to-refresh and a navigation-bar
menu are conventions a phone user already has; a row that reveals buttons
when dragged sideways is also a convention, but **nothing on the card
indicates it has one** — no chevron, no partial reveal, no grabber. The
affordance is genuinely invisible, and it is the only one in the tour that
was.

## Decision

Remove the tour completely. Replace it with a single hint that performs the
gesture on the real card: the first card slides left to reveal its actual
action buttons, holds them visible, and slides back.

**It fires on the user's SECOND arrival at the favourites list, not the
first.** The first arrival belongs to the user and their new river.

### What "arrival" means

Every time the favourites list becomes the visible page:

* the app launching onto it, once the saved rivers have actually loaded; and
* returning to it from anywhere else — the forecast page, the map, settings.

The count is persisted in `SharedPreferences` under
`favorites_visit_count`, and the hint's once-ever flag under
`has_seen_swipe_hint`.

### An empty list does not count as an arrival

The hint demonstrates a gesture *on a card*. With no favourites there is
nothing to demonstrate, so an empty list does not increment the counter at
all — otherwise a user who opens the app, sees an empty list, then saves a
river would have the hint fire on the very first list they ever see, which is
the interruption being removed.

This is also why the decision is made **after** the favourites finish
loading rather than in the post-frame callback: on a cold launch the list is
always empty at first frame, and deciding then would find it empty every
time.

### Nothing is modal

The hint is an `AnimationController` driving the card's existing
`SlideTransition` — the same controller the user's own drag uses. A user who
grabs the card mid-hint simply takes over; the drag handlers run because
`_isSliding` is already true. There is no overlay, no barrier, and no control
to dismiss.

Timing (chosen, not measured): 900 ms settle before anything moves, 420 ms to
open, 1100 ms holding the buttons visible, 320 ms to close.

## Consequences

**Removed**

| | |
|---|---|
| `tutorial_coach_mark` | dependency dropped from `pubspec.yaml` |
| `coach_mark_targets.dart` | and its test — the tour's four anchor definitions |
| 3 `GlobalKey`s | the page's tour anchors, and the duplicate-key crash class they caused |
| `has_seen_favorites_tour`, `has_seen_search_tip` | keys no longer read; harmless residue in existing installs |

**Kept, rewritten**

`CoachMarkService` keeps its name and its place in
`services/4_infrastructure/favorites/`, but now holds only the hint's two
pieces of state and one pure decision function, `shouldShowOnVisit`.

**Existing users** have `has_seen_favorites_tour: true` and no
`has_seen_swipe_hint`, so anyone who already completed the old tour will see
the new hint once. That is acceptable: the tour's swipe panel described the
gesture over a blacked-out screen, and the hint shows it.

## Verification

All **Measured**, 2026-11-02, on this branch.

| What | How |
|---|---|
| The card moves only when asked | widget test reads `SlideTransition.position.value.dx` inside the card's own subtree |
| The hint opens the card and puts it back | same test, sampled at 300 ms (closed), ~1.3 s (open), ~3.8 s (closed again) |
| Completion fires exactly once | callback counter over the full sequence |
| The decision rule | 9 tests on `CoachMarkService` — second visit, not first; never twice; empty list does not qualify |
| The wiring | source-level guards: the page passes `runSwipeHint`, `didPopNext` resolves on arrival, completion persists the flag, and `tutorial_coach_mark` appears nowhere in `lib/` or `pubspec.yaml` |

**Seven mutations, all caught:**
`showOnVisit = 1`; dropping the empty-list guard; `_playSwipeHint` made a
no-op; the card never sliding back; completion firing twice; the page no
longer passing `runSwipeHint`; `didPopNext` reverted to revalidate-only.

Suite: **1440 unit/widget tests green**, plus **27 integration tests** after
seeding `has_seen_swipe_hint` in `buildTestApp` — without that seed the hint
would slide the first card open mid-test and make any card tap flaky.

`flutter analyze`: clean apart from the pre-existing `onReorder` deprecation
in `favorites_page.dart`.

**Unverified:** nothing here has run on a device. What a device would add is
whether 1100 ms is long enough to read three buttons, and whether the hint
reads as a demonstration rather than a glitch.

## Out of scope

* Any hint for pull-to-refresh, the settings menu, or search. Those were the
  redundant three.
* A re-playable "show me again" control. Nobody asked for one and it would
  need a settings row to live in.
* Reordering, renaming and the image picker remain discoverable only through
  the revealed buttons — which is what the hint reveals.
