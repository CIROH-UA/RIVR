## Item 4 — a metric user could see a flow 35x wrong, with the flood category inverted

**Broken.** One invariant, three ways: the stored entry's unit tag did not
describe the payload it was attached to.

* The tag was read from the live preference BEFORE the await, while the
  conversion read it again AFTER. The favourites page flips that preference
  without cancelling in-flight reads, so a toggle landing in that window
  tagged CMS data as CFS. The decoder trusts the tag alone, re-converted, and
  produced a number 35.3x too low — then classified against correct
  thresholds, so every river read Normal. In a flood app.
* One point with a null flow, which NOAA does send, threw a cast error that
  discarded the ENTIRE series around it. A 120-point forecast with one bad
  reading rendered as "No data", and the empty result was cached as a
  confirmed success.
* The 30-second unfiltered-fallback cache was keyed by reach alone and stored
  already-converted bytes with no record of the unit.

**Changed.** The converter now stamps the payload with the unit it actually
produced, and the data source reads that stamp instead of the preference, so
tag and payload cannot disagree by construction. Unreadable points are
dropped individually, with the count logged. A payload with no readable
points anywhere is refused at the source rather than stored as a success.

**Break-it review.** Five mutations, all caught: removing the stamp;
`if (false)` around the stamp; `_unitOf` ignoring the stamp; bad points
discarding the series again; `if (false)` around the usable-series guard.

Two things worth recording. The usable-series check first named a section
per product, which duplicated a mapping that belongs to `ForecastValues` —
replaced with "is there anything readable anywhere", using the real parser
rather than counting raw entries, because a section can be structurally
present and decode to nothing. And four existing tests broke: their fixtures
carried a referenceTime with zero points, which is not a response NOAA sends
successfully. Fixtures made realistic; the assertions they make about call
mapping and run identity are untouched.

1,480 tests, analyze clean.

## Item 3 — the app could cache an EMPTY forecast over a full one

**Broken.** NOAA's `?series=` filter is honoured only some of the time.
⏱ MEASURED 2026-11-09 16:56 UTC, n=10 CONUS reaches taken from this repo's
own tests and docs (6 more returned 503 and are discarded):
`?series=medium_range` comes back HTTP 200 with **all five sections `{}`**,
10 of 10. The app then refetches the UNFILTERED body, which for the same
reaches at the same moment carries `analysisAssimilation` 47 points and
`shortRange` 18 points with medium and long range empty, 10 of 10.

That whole body was handed back to the caller. The caller is a cache keyed by
PRODUCT, so a medium-range read stored a full copy of SHORT range inside the
medium-range entry, on medium range's 6-hour window.

* `ReachDataProvider._mergeForecastData` lets whichever section load lands
  LAST win, so the hourly chart and the gauge could be driven by that copy
  instead of by the dedicated short-range entry on its 1-hour window, and
  differ between two opens of the same page.
* It defeated the empty-section check, which asks "is anything readable
  here" of the payload as a whole, on purpose, because naming a section per
  product would duplicate the decoder's mapping. A smuggled short range
  answered the question.

**Changed.** `fetchForecast` trims its answer to the section it was asked
for, keeping the reach block and the unit stamp, with the section always
present as `{}` when upstream sent nothing. The unfiltered body is still
cached whole for 30 seconds so a second product's fallback shares the one
request, and the trim COPIES rather than editing that shared map.

### The first version of this shipped a worse bug than it fixed

The first version refused an empty answer by THROWING, so that nothing was
cached and nothing claimed to be current. An independent break-it agent
measured what that did on screen and returned FAIL. It was right.

`ReachDataProvider` turns any exception from a section read into
`SectionLoadState.error`, which renders RED: "Unable to Load Forecast /
Something went wrong loading the medium range forecast. Pull down to retry."
Nothing had gone wrong in the app, pulling down could not help, and since
medium and long range are empty for every CONUS reach that answers, that was
the NORMAL case rather than an edge. It also raised `outOfSync`, putting the
app-wide stale banner over the favourites page for half an hour after any
reach page was opened, and made every read refetch: the agent measured the
call count climbing 2, 3, 4 across three reads of one product.

Worse, `FavoritesProvider._refreshSingleFavorite` reads the name, the flow
and the thresholds in one `Future.wait` inside one `try`, so a throw from
`currentFlow` would have discarded the river's NAME and its FLOOD THRESHOLDS
as well. The code anticipates null entries there; it does not anticipate a
throw.

**The honest half of the fix was the WINDOW, not the refusal.** An empty
answer is now cached with a 15-minute retry window instead of its product's
publish window. It decodes to a section with no points, which lands the panel
on `SectionLoadState.empty` — orange, "temporarily unavailable, this usually
resolves on its own", which is true — with no app-wide banner and no refetch
on every read. The defect being fixed was never "it was cached"; it was
"it was cached for six hours as a confirmed current value with no later
attempt".

Fifteen minutes is a judgement, not a measurement, and it is recorded as one.
It sits between two failures that have both happened here: hold the empty
answer for six hours and one unlucky request means an empty 10-day panel all
morning; hold it for nothing and one page open becomes a climbing count of
calls against an endpoint that is already failing.

### Two claims of mine the review disproved

**"Nothing shipped with it: the bug needed this trim to become reachable" is
DISPROVEN.** The agent measured that on `d40ddf1`, already merged to
`development`, a POPULATED filtered `?series=medium_range` response — one
call, no fallback, no trim involved — was refused outright, because the
usable-series check looked under `series` only and medium and long range are
ensembles keyed `mean`/`memberN`. So `development` today throws away every
real medium- and long-range forecast NOAA serves. This branch is the fix for
something already merged, not a precaution, and my claim understated it.

**The fixture provenance comment was wrong.** It attributed the
populated-shortRange shape to the filtered endpoint. The filtered endpoint
returns all five sections empty; that shape is the UNFILTERED body. The
fixtures now serve a different body per URL, which is both accurate and a
stronger test.

### Break-it review

Round 1, by me: eight mutations, all caught. **The independent agent then
wrote twelve of its own and four survived**, which is the whole argument for
the rule. Round 2 re-ran its four plus eight new ones:

| Mutation | Round 1 | Now |
|---|---|---|
| fallback trims the CACHED map in place, poisoning the shared body | SURVIVED | caught |
| drop the line that keeps the requested section present | SURVIVED | caught |
| `shortRange` skips the window check | SURVIVED | caught |
| `currentFlow` skips the window check | SURVIVED | caught |
| an empty answer gets its full publish window again | — | caught |
| the usable-series check always says yes | — | caught |
| ensemble members ignored again | — | caught |
| the provider calls an empty section an error | — | caught |
| `if (false)` the trim, call site intact | — | caught |
| medium range answers with short range instead | — | caught |
| the empty window is 6 hours, not 15 minutes | — | caught |
| `_runIdOf` first-found across sections, two forms | — | caught |

**Discarded as equivalent mutants, with the reasoning:** two weaker
`_runIdOf` forms that fall back only when the requested section is ABSENT.
That branch is unreachable, because the section is always present — in the
trimmed production payload and in the test fake alike. The stronger
fixed-order first-found forms are caught by `data_sources_test`.

**Why round 1's eight were not enough, which is the lesson worth keeping:**
every one of them attacked the defect. None asked whether the FEATURE still
worked, and none went near the call sites the change did not touch. Three of
the agent's four survivors were untested call sites of a function I had just
written a guard for. That is now written into the break-it skill as a
required second half of question 1.

1,494 tests, analyze clean.

## Item 14 — storeHealth announced a schedule that no longer existed

**Broken.** `healthCheck` serves human-readable prose about when things run,
hand-written next to machine-read cron strings. It had drifted twice: it
advertised four Mountain-Time slots for functions deleted in ADR 0011 Phase
6, and after the refresh moved to `:05` it kept announcing `:20` — six lines
below a comment warning against exactly that. The string itself was corrected
on 2026-11-03; nothing stopped it drifting a third time.

**Changed.** `health-schedule-drift.test.ts` reads the cron expressions and
timezones out of `index.ts` and fails when the prose and the schedule
disagree, in EITHER direction. It also fails when the prose names a function
that is no longer exported, which is the first drift.

Honest about its strength: this is a source-level guard, like
`store-health-wiring.test.ts`. It cannot tell whether the cron is the right
cron, only whether the sentence an operator reads still describes it. That is
the failure that actually happened, twice.

**Break-it review.** Seven mutations, all caught, both directions: cron moves
and prose stays; prose reverts and cron stays; the GEOGLOWS hour slips; the
GEOGLOWS timezone changes under the prose; the weekly outlook moves to
Monday; the prose advertises a deleted function; the schedule block is
dropped from the endpoint entirely.

480 functions tests.

## Item 12 — the banner at the top of CLAUDE.md pointed at a closed incident

**Broken.** The most-read paragraph in the repo described the hydromap.com
email quarantine as an open operational task needing Dan's Cloudflare access.
Issue #38 closed 2026-11-09 at 03:23Z.

**Verified before removing it** — ⏱ MEASURED 2026-11-09 · n=1
`dig +short TXT` per record:

| Record | Value |
|---|---|
| `hydromap.com` | `v=spf1 include:_spf.google.com ~all` |
| `_spf.google.com` | resolves to a real policy — this was the broken half |
| `google._domainkey.hydromap.com` | `v=DKIM1; k=rsa; p=MIIBIjANBgkq…` |
| `_dmarc.hydromap.com` | `p=quarantine`, correct now that both pass |

**Not measured:** that a reset email reaches an inbox. The records
authenticate; delivery was not re-tested end to end. And RIVR's own reset
mail goes out from the default Firebase sender, not from hydromap.com, so it
was never the part that depended on these records. Said so in both places
rather than letting "fixed" imply more than was checked.

**Changed.** Banner removed. A dated record with the measurements kept lower
in the file, next to release tracking, including the lesson that an
operational banner needs a closing check or it keeps sending readers after a
solved problem. The memory memo and its index entry were corrected the same
way — the memo's original diagnosis is kept, relabelled as disproven as a
current state rather than deleted.

## Item 11 — the release path had no guards where it had already failed

**Broken.** `make release-android` and `make release-ios` checked nothing:
not the branch, not the tree, not the gitignored config, and above all not
the artefact. That matters more here than in most projects, because every
RIVR release is built on one laptop — nothing between `main` and a store
passes through CI. The Makefile IS the primary control, and it needed
nobody's permission to exist, so it was done first regardless of the branch
protection question in item 10.

**Changed.** A `preflight` target that refuses to build, and two targets that
read the finished artefact back. Every check comes from an incident:

| Check | The incident |
|---|---|
| map token in `android/local.properties` | AAB 800 reached Play with a map that never loaded; the build exited 0 with the literal placeholder compiled in |
| `MAPBOX_ACCESS_TOKEN` in `ios/Flutter/Secrets.xcconfig` | `Release.xcconfig` includes it with `#include?` — the `?` makes it OPTIONAL, so a missing file ships an empty token and a dead map. The iOS twin of the above, unguarded until now |
| every gitignored config file present | merging development into main deletes them from disk (Apr 2026) |
| clean tree | an artefact that matches no commit cannot be traced from a crash report |
| branch is `main` | releases are stamped there; `ALLOW_BRANCH=1` for a test build |
| `verify-aab` reads the bundle | the token out of the manifest, and versionCode+versionName against pubspec |
| `verify-ipa` reads the IPA | `aps-environment`, the map token, and the build number |

The repo's own rule for these pipelines is that they fail SILENTLY — five
separate operations have exited 0 while producing wrong or partial data, and
exit status has never caught any of them. So both verify targets end by
reading the artefact, and `verify-ipa` reads the IPA rather than the archive,
because `flutter build ipa` re-signs on export.

**Proven, not assumed** — ⏱ MEASURED 2026-11-09 against the real artefacts
still on disk from the 2026-11-02 build:

| Case | Result |
|---|---|
| real AAB | passes: `2026.2.5+917`, token present |
| real IPA | passes: `2026.2.5+917`, `aps-environment production`, token present |
| the ARCHIVE's app repacked as an IPA | **FAILS** with `aps-environment is 'development'` — this is the six-month push outage signal, reproduced from a real artefact on this machine rather than a hypothetical |
| IPA with `MBXAccessToken` reset to the unexpanded variable | **FAILS** |
| IPA with `CFBundleVersion` set to 900 | **FAILS** against pubspec's 917 |
| missing artefact, either platform | **FAILS** with "build it first" |
| wrong branch | **FAILS**, and prints the `ALLOW_BRANCH=1` escape |
| dirty tree | **FAILS**, and lists what is dirty |

**Not yet proven:** the missing-config and missing-token refusals. They sit
behind the clean-tree check, which this working tree does not satisfy while
the remediation work is in flight, so they were read rather than executed.
Saying so rather than listing them with the eight above.

**Deliberately not added:** `flutter test`. A release should not be the first
place the suite runs, and bolting 75 seconds onto every build invites people
to work around the target.

**Still open, and not ours:** branch protection on an org-owned repo needs a
CIROH-UA owner. The iOS Release config still carries
`CODE_SIGN_IDENTITY = "iPhone Developer"`, worked around rather than fixed —
`verify-ipa` now catches the consequence, which is the half that was costing
real outages.

## Item 13 — the docs' numbers (started: the rule, and the worst claim)

Two halves. The rule that stops new wrong numbers, and the 81 existing ones.

**The rule is in.** CLAUDE.md now opens with it: a figure is only usable if
it carries `⏱ MEASURED <date> · n=<count> · <method>`, and **an unstamped
number may not justify a decision or close a scope.** The audit's finding is
what justifies the rule rather than taste — of ~190 claims checked, 115 held,
52 were stale and 29 were wrong, and the split was not about writing quality:
**every claim resting on n ≤ 2 that could be checked came back wrong or
stale, and every claim pinned by a test came back right, 21 for 21.** So the
rule also says to prefer pinning a number with a drift test over stamping it,
because a drift test is the only thing in this repo's history that has kept a
number honest with nobody remembering to check.

**The worst single claim is corrected, with a real n.** The GEOGLOWS
publication window: documented as 10:15-10:30 UTC from **two** consecutive
days, spread to eight places, and carrying the instruction "do not re-derive
it; do not call it unknown".

⏱ MEASURED 2026-11-09 · n=5 consecutive days · `curl -I` on
`geoglows-v2-forecasts/<YYYYMMDD>00.zarr/.zmetadata`, reading `Last-Modified`:
**09:39-10:09 UTC, median 09:40.** The run lands 35-50 minutes earlier than
documented. (`.zmetadata` is zarr's consolidated metadata, written after the
arrays, so it is a fair proxy for complete-and-readable rather than for
write-started.)

Nothing is broken by the correction and no schedule moves — the store's 11:30
and the flood builder's 11:00 both sit after the latest observed publication,
and the client's 10:30 constant is a finished-by upper bound with ~21 minutes
of margin over the worst sample. **What it costs:** a device waits up to ~50
minutes longer than necessary for a forecast already on S3. Recovering that
means lowering a constant whose failure mode is expiring BEFORE publication,
which would put every device into a retry loop against a run that is not
there — so it wants a fortnight of samples, not five days. Recorded as the
recommendation rather than done.

Corrected in CLAUDE.md and ADR 0011, with the old figure kept and labelled
rather than deleted, per the rule that a disproven claim stays visible so
nobody proposes it twice.

**Still open:** the same figure in four code comments and two test files
(`geoglows_data_source.dart`, `store-document.ts`, `store-window.ts`,
`functions_geoglows/main.py`, plus `store-window.test.ts` and
`data_sources_test.dart`), and the other ~80 audited claims. Left for a
dedicated pass rather than edited while an independent review held the suite.

## Item 9 — a wall-clock assertion that could go vacuous

**The backlog's own claim about this one was wrong, so start there.** It said
the 40 ms assertion in `river_data_repository_test.dart` was "measured green
on an idle machine and red (43 ms) under load". ⏱ MEASURED 2026-11-09 · n=12
(6 idle, 6 with 8 saturated cores) · printing the elapsed value: **every run
22-23 ms, idle and loaded alike.** Five full runs of the old assertion under
that load were green 5 of 5. The flake is not reproducible on this machine
and the claim is recorded as disproven rather than quietly inherited.

**The real defect is the mirror image, and this one IS measured.** The
threshold silently encodes the fake cache's 20 ms read delay:

| | elapsed |
|---|---|
| correct, two keys in parallel | 22-23 ms (n=4) |
| broken, fully serialised | 45-47 ms (n=4) |
| the threshold | 40 ms |

So it discriminated, with 17 ms of margin on the pass side and 5-7 ms on the
fail side. Then shorten the fake's delay from 20 ms to 12 ms, which is an
innocent tidy-up nothing would flag: a **fully serialised** implementation
comes in at 30 ms and the assertion PASSES. The guard is vacuous and nothing
says so. That is this repo's single most common defect shape, arrived at from
a direction the audit did not consider.

**Changed.** The fake counts in-flight `get` calls and records the peak. Two
different keys must overlap (peak 2); the same key must not (peak 1), which
also names the mechanism the existing supersession test only tested the
symptom of. No clock, no margin, and immune to the delay change above:
verified red at 12 ms where the old one went green.

**Break-it review.** 5 mutations caught: the chain becomes global rather than
per key; no chain at all; `if (false)` on the line that stores the chain so no
successor ever waits; and two that attack the GUARD itself rather than the
code, freezing the concurrency counter and the call counter, because a
counter stuck at 1 would satisfy the same-key assertion by accident. One
mutation discarded for not compiling, which proves nothing.

Q2 re-measured above, and it contradicted the claim that justified the item.
Q3: nothing claimed beyond what is tabled here.

1,494 tests, analyze clean.

## Item 8a — the guard protecting a real account proved nothing

**Broken.** ADR 0014 rule 2 is the refusal that stops `User.delete()` acting
on a stale reference. `User.delete()` deletes the current SESSION, not the
reference it is called through, so in build 843 it destroyed a real account
of eight months while the anonymous guest it was meant to remove survived.

Reproduced the audit's finding before touching anything: **delete that
refusal from the production datasource and all 1,494 tests stay green.**

The cause is the second of this repo's three vacuity mechanisms. The guards
that look like they cover it, in `guest_mode_test.dart` and
`guest_merge_destroy_test.dart`, drive a `_FakeDatasource` whose own
`deleteUser` reimplements the refusal. One of them said so in a comment,
"Mirrors the real datasource's refusal", which is the tell. They prove the
FAKE refuses.

**Changed.** A new test drives the REAL `AuthFirebaseDatasource` over
`MockFirebaseAuth`, in the exact shape of build 843: an account signed in, a
stale guest reference still in hand. It asserts the refusal, that neither
user was deleted, that the session is intact, that deleting the CURRENT user
still goes through, that a null session also refuses, and that the message
names both uids — because this failure is silent by nature and whatever
reaches the log is the only witness.

`MockUser.delete()` is a no-op, so the "it does go through" half is recorded
through a subclass that logs the call. Without that, the positive control
would have been vacuous in the same way as the thing it replaces.

The fake's comment is corrected rather than its behaviour: it SHOULD model
the real contract, or the `AuthService` tests around it would be
unrealistic. It now says explicitly that it does not test the refusal, and
points at the file that does.

**Break-it review.** Six mutations, all caught, including the audit's
original survivor: delete the refusal; `if (false)` it with the code intact;
drop the null-session half; `==` for `!=` so it refuses the right user and
allows the wrong one; throw for everyone, which would break account deletion
entirely and that is itself an App Store 5.1.1(v) requirement; and stop
naming the uids in the message.

Q2: no measurement claimed beyond reproducing the survivor, which is above.
Q3: nothing asserted that is not tabled here.

1,498 tests, analyze clean.

## Item 8b — the onboarding feature could be dead with every guard green

**Broken.** ADR 0015's hint is carried by three connections between the page
and the card, and all three were guarded only by
`swipe_hint_wiring_test.dart`, which greps the page's SOURCE for
`runSwipeHint:`, `_resolveSwipeHint()` and
`CoachMarkService.completeSwipeHint()`.

Reproduced the audit's finding first. ⏱ MEASURED 2026-11-09: wrap either
`setState(() => _swipeHintCardIndex = 0)` or
`CoachMarkService.completeSwipeHint()` in `if (false)` and all three
pre-existing guards stay green — `swipe_hint_wiring_test.dart`,
`swipe_hint_test.dart` and `coach_mark_service_test.dart`. The string being
grepped for is still on the line. This is the mechanism the audit called the
largest single source of vacuous tests in the suite, and it named these
guards specifically as ones written the week before by someone who believed
they were careful.

**Changed.** `test/integration_test/swipe_hint_plays_test.dart` pumps the
real `FavoritesPage` with real cards and watches the first card MOVE: 19 →
-197 logical pixels, which is exactly the 216pt action strip, and back. It
reads geometry, not widget properties, because a translation that never
reaches the screen is the failure being guarded against. Four scenarios: the
second arrival plays and returns to rest; it is marked seen so it never
plays twice; the FIRST arrival does not move the card and does not spend the
one chance; and a user who has already seen it is left alone.

The audit's claim that "no FavoritesPage widget test exists" was true of
`test/ui/`, but `test/integration_test/` already had a full harness that
pumps the page with real cards, and those 39 tests run and pass under
`flutter test`. **So the related claim in item 10, that all 10 integration
test files are skipped, is also wrong.** Recorded here rather than acted on.

### Two things this cost, both worth keeping

**The harness silently overwrote the test's own preferences.**
`buildTestApp` called `SharedPreferences.setMockInitialValues({'has_seen_swipe_hint': true})`
unconditionally, deliberately, so the hint cannot make other tests flaky.
A test that seeds `false` in `setUp` therefore got `true` anyway — so two of
these four tests PASSED for the wrong reason on the first run, watching a
hint that was never going to play. That is the same vacuity this file exists
to remove, reproduced inside the fix for it. `buildTestApp` now takes
`seedSwipeHintSeen`, defaulting to the old behaviour so no existing test
changes, and the trap is written down at the call site.

**Async setup inside `testWidgets` hangs rather than fails.** The first
version did the harness setup in the test body. The body runs in Flutter's
fake-async zone, where a real platform-channel future never completes, so
the file hung for over ten minutes with no output instead of failing. Every
other favourites test does its setup in `setUp` for exactly this reason;
each scenario is now its own group. Noted in the file.

**Break-it review.** Six mutations, all caught, including the two the
pre-existing guards let through: `if (false)` on the hint index; the page
passing `runSwipeHint: false`; `if (false)` on persisting "seen"; removing
the second-arrival rule so it fires on the first; ignoring "already seen" so
it replays for everyone; and the card never reporting completion.

The old grep guard is kept, with its header corrected to say it is a
deletion tripwire and not coverage, and to point at the behavioural file.

1,502 tests, analyze clean.

## Item 8c — the card's swipe mechanics had four unguarded behaviours

**Broken.** The audit reported "no `FavoritesPage` or `FavoriteRiverCard`
widget test exists at all, which alone causes four of the findings". I
re-derived the gaps by mutating the card and running the whole suite for
each change rather than trusting the list. Five of nine mutations were
caught. **Four survived all 1,502 tests:**

| Survivor | What a user would see |
|---|---|
| the drag origin ignores that a row was already open | dragging an open row back snaps it shut on the first pixel instead of following the finger |
| the fling DIRECTION inverts | a flick left closes and a flick right opens: the gesture runs backwards |
| the strip behind the card is a different width than the card travels | a button left clipped under the card, which is the exact defect ADR 0016 was written to fix |
| the reveal is not clamped | nothing, as it turns out: see below |

`swipe_hint_test.dart` does pump this card, but only ever drives the HINT,
never a finger, which is why the drag maths was untouched.

**Changed.** A widget test that drives real gestures at the real card: the
reveal stops at the strip however far you drag; dragging an open row back
follows the finger; a short slow drag springs back; the strip is exactly as
wide as the card travels; and the strip is three buttons at the ADR's width.

### The fling branch cannot be tested through the gesture layer

⏱ MEASURED 2026-11-09. `DragEndDetails.velocity` reads effectively zero under
`flutter test` for every synthetic release I could build: `tester.fling` at
40, 50, 60 and 80 px, and hand-built gestures at 3, 6 and 10 samples. All of
them fall through to the distance test. `tester.fling` was also
non-monotonic, opening the row at 50 px but not at 40, 60 or 80, so it is not
a usable instrument for this at all.

So the decision is now a pure function, `FavoriteRiverCard.shouldLatchOpen`,
with the two thresholds named, and it is tested as a value function. That is
the honest way to reach a branch the harness cannot drive, rather than
writing a gesture test that passes for a reason unrelated to what it claims.

### Two things measured against myself

**The clamp survivor is an equivalent mutant, and the code now says so.**
`AnimationController.value` clamps to `[lowerBound, upperBound]` in
`_internalSetValue`, read from Flutter's own source, and this controller uses
the default 0..1. The explicit `.clamp(0.0, 1.0)` in `_handleDragUpdate` is
therefore behaviourally invisible. The user-visible result is still guarded;
it is just enforced one layer down. Noted in the card so nobody reads that
line as load-bearing.

**Two of my own assertions were wrong before they were right.** A single
large `moveBy` straight after touch-down is not picked up by the horizontal
drag recogniser, so the card never moved and the clamp assertion passed for
the wrong reason until the gesture was split with a pump between moves. And
the recogniser absorbs the first ~30 px as touch slop, so the open-row drag
lands near 146 rather than 116; that assertion is now a range, because the
exact figure is a property of the framework's slop and not of this card.

**Break-it review.** Nine mutations, eight caught, one discarded as an
equivalent mutant with Flutter's source quoted as the reason. The four
original survivors are all caught, and five new ones on the extracted
decision and the geometry constants are too.

1,510 tests, analyze clean.

