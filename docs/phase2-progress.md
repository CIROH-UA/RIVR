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

## Item 13 continued — the stale cadence row, and the GEOGLOWS figure everywhere

**Broken, and found by the test written for it.** CLAUDE.md's cloud-store
table announced `storeRefreshHourly` at `:20`. The cron has been `5 * * * *`
since 2026-11-03. That is the same drift item 14 fixed in the health
endpoint, sitting in the most-read document in the repo instead. The other
four rows checked out.

**Changed.** The row is corrected, and `claude_md_schedule_drift_test.dart`
now reads the cron expressions and timezones out of `functions/src/index.ts`
and fails when the table and the schedule disagree in either direction. It
also fails when the table names a function `index.ts` no longer exports,
which is how four deleted conditions functions stayed advertised for weeks.

This is the durable half of item 13 and the reason it is a test rather than a
careful re-read: of ~190 audited claims, every one resting on n <= 2 that
could be checked came back wrong or stale, and every one pinned by a test
came back right, 21 for 21.

**The corrected GEOGLOWS window is now in the code too.** The wrong
10:15-10:30 figure had spread to eleven comments across six files:
`index.ts`, `store-document.ts`, `store-window.ts`, `store-trigger.test.ts`,
`store-window.test.ts`, `functions_geoglows/main.py`,
`geoglows_data_source.dart` and `data_sources_test.dart`. All now say
09:39-10:09 UTC with the n=5 measurement, and three keep the old figure
beside it labelled as the n=2 claim that was wrong, so nobody re-derives it.

**No behaviour changed.** `GeoglowsDataSource._publishHourUtc/_publishMinuteUtc`
stays at 10:30 UTC, which remains a valid finished-by upper bound with about
21 minutes of margin over the worst sample. Moving it needs a fortnight of
samples, because its failure mode is expiring BEFORE publication and putting
every device into a retry loop.

**Break-it review.** Seven mutations, all caught, both directions: the doc
reverting to `:20`; the cron moving while the doc stays; the GEOGLOWS hour
slipping; the GC minute changing; a timezone changing under the doc; the
heartbeat becoming 3-hourly; and the table naming a deleted function.

1,514 tests, 480 functions tests, analyze clean.

**Correction, same day:** the commit for this change says 1,518. The real
figure is 1,514. I read the `+8` from running `flutter test test/docs/` as
eight NEW tests when it was the whole directory's total, four of which
already existed. Recorded rather than amended, because the commit is already
on `development` and the log is the durable record. It is a small number and
exactly the kind this phase has been correcting in other people's work.

**Still open on item 13:** the remaining audited claims that are prose rather
than numbers. They are not enumerable from here without redoing the audit,
and the stamp rule plus these two drift tests are what stop new ones.

## Item 6 — medium range went stale every night, and why the schedule fix was not enough

**WRITTEN AND TESTED, NOT DEPLOYED.** This is server code and takes effect
only on `firebase deploy --only functions:default`. Jerson's standing
instruction is not to deploy without a recorded reason, so it is on
`development` waiting for his word. Nothing about the running system has
changed.

**Broken.** `mediumRange` went stale between 00:00 and 08:00 UTC daily,
peaking at a stored run 32 hours old against a 24-hour cap. The 2026-11-03
schedule move cut that by about 80% and not to zero, and the remaining cause
is not the schedule.

NOAA serves the medium and long range sections as a per-request LOTTERY
inside a daily window (measured 2026-11-03: 3 full responses of 14 for one
reach within five seconds while the window was open, and 0 of 700 across
every production reach once it had shut). **The probe takes exactly one
sample per product per hour.** Lose the lottery and `probeRunFor` returns
null, which `decideTriggers` read as "upstream failed this hour, do nothing".
Hour after hour, while the stored run aged past its cap.

The retry budget to fix it already existed downstream:
`EMPTY_SECTION_ATTEMPTS` in `store-upstream.ts`, bounded per run by
`WINDOW_PROBE_REACHES` in `store-run.ts`. All that was missing was a reason
to spend it.

**Changed.** Once the stored run is half way to its product's own run-age
cap, a null probe reading stops vetoing the attempt and the fetchers get to
try properly. Two conditions, and the second matters as much as the first:

* **Upstream must have ANSWERED.** A 200 whose section was empty is a lost
  lottery; a timeout or a 5xx is an outage, and retrying through an outage is
  the fan-out-every-hour behaviour the null guard was written to prevent, as
  well as hammering whatever is already failing. The probe already records
  per-endpoint `ok` and `httpStatus`; `readLatestProbe` was throwing them
  away.
* **Something must already be stored**, so a cold start does not fan out
  either.

**The probe is deliberately NOT given retries**, which was the first idea.
The probe exists to measure the per-request success rate, and this repo's own
rule is that retrying inside it hides the failure rate it exists to measure.
Retrying where the data is actually wanted keeps the measurement honest.

**An existing guard failed, correctly, and changed the design.** "A probe
reporting NO run does not trigger" went red on the first version, which
rescued on any null. It was right: that version reintroduced the fan-out on
every upstream outage. The answered/not-answered split is the result.

### A second gap found on the way

Three mutations of the probe-document mapping passed the entire 488-test
suite: marking every endpoint answered, marking none, and dropping
`answered` from the result altogether. Each changes what the store fetches
and all three are silent. None could be caught while the logic sat inside
`readLatestProbe`, which talks to Firestore and cannot be unit-driven.

So the mapping is now `probeRunsFromDocument`, a pure function, with its own
test file. This is the refactor `store-health-wiring.test.ts` says
`checkStoreHealth` still needs; done here because the cost of getting it
wrong is a product that silently stops refreshing.

**Break-it review.** Ten mutations, all caught: the rescue removed; rescuing
through an outage; rescuing a fresh run; the threshold at the full cap
instead of half; a cold start fanning out; products with no run identity
qualifying; `answered` defaulting to true for historical samples; and the
three mapping mutations above. One earlier form did not compile and proves
nothing.

Q2: the lottery figures are the 2026-11-03 measurements already in CLAUDE.md,
not new claims. The 00:00-08:00 staleness window and the 32-hour peak are the
audit's, and I did NOT re-measure them: doing so needs production logs over a
night, so they stay the audit's figures rather than mine.

Q3: **unproven, and it is the central claim.** That this actually fixes the
nightly staleness is reasoned from the mechanism, not demonstrated against
production. The mechanism is certain, the tests pin the decision, and the
effect can only be confirmed by deploying and watching a night of
`storeHealth` and the run logs. Recorded as unproven rather than claimed.

496 functions tests, tsc clean.

## Item 10 — CI's non-admin half: it now runs what it claims to

The branch-protection half needs a CIROH-UA owner and is untouched. The rest
needed nobody's permission.

**Broken 1: CI excluded `test/integration_test/` on a premise this repo had
already retracted.** The comment said "~27 long-standing pre-existing
failures and needs a device". Both halves are false. CLAUDE.md retracted the
27 figure on 2026-09-22 after measuring 0 failures on a clean tree, and
recorded that the wrong note had been MASKING real regressions: a guest-mode
change produced exactly 27 new failures and they were read as expected noise.
And they need no device.

⏱ MEASURED 2026-11-09 in a fresh worktree carrying only the CI stub config,
which is that job's exact starting state: **43 tests, 0 failures.** Until now
those 43 ran nowhere in CI, including the behavioural guard for the ADR 0015
onboarding hint added the same day, which is the only test that can tell
whether that feature is alive.

CI now runs bare `flutter test`. No allow-list and no exclusions: an
enumerated list is a promise someone will remember to update it, and this
repo has now been bitten by that twice (`test/docs/` ran nowhere for the same
reason).

**Broken 2: CI had never built an artefact.** Nothing between a push and a
store exercised the Android build, so a Gradle, manifest, plugin or resource
change that stops it compiling was invisible to `flutter analyze` and
`flutter test` alike.

There is now a debug-APK job that reads the artefact back rather than
trusting the exit code, per this repo's own rule that its pipelines have
exited 0 while producing wrong or partial data five separate times.

**This one did not work first time, and the honest version is better for
it.** The first attempt claimed to be verified locally. It was not: the build
FAILED in the worktree, because `android/app/google-services.json` is
gitignored and the Google Services plugin refuses to run without it, before
compiling anything. So there is now a committed
`android/app/google-services.ci.json` placeholder, the same pattern the repo
already uses for `firebase_options.ci.dart`. Re-measured after adding it: the
APK builds and carries 16 mipmap entries, which is what the read-back checks.

**Broken 3, honestly scoped.** CI builds against `config.template.dart`,
whose secrets are the literal `INSERT-THE-KEY`, so it is structurally
incapable of catching the missing-token defect that shipped AAB 800. That
does not change: there is no real token in CI to check, and the real guard
for it is `make verify-aab` (item 11). What CI can check is the inverse,
which is worth having: that nobody has committed a REAL credential into any
of the four committed stub files. Verified both ways locally, including that
the scan does fire on the real `config.dart`.

**No break-it mutations here**, and that is a gap worth naming rather than
papering over: a GitHub Actions workflow cannot be mutation-tested from this
machine. Every claim above was instead verified by running the exact commands
the workflow runs, in a worktree with no gitignored files, which is the
closest reachable thing to the job's real environment. The first run of that
exercise is what caught the google-services failure.

## Item 13 finished as far as it can be: the numbers are pinned

The audit found 52 stale and 29 wrong claims of ~190 checked, and its own
conclusion was that the split had nothing to do with writing quality: **every
claim resting on n <= 2 that could be checked came back wrong or stale, and
every claim pinned by a test came back right, 21 for 21.** So the remaining
work on this item was to move claims from the first category into the second,
not to re-read prose more carefully.

Three guards now cover CLAUDE.md's falsifiable content:

| Guard | Pins |
|---|---|
| `claude_md_accuracy_test.dart` (existing) | every `lib/` and server PATH it names |
| `claude_md_schedule_drift_test.dart` (item 13, earlier today) | the cron SCHEDULES, both directions |
| `claude_md_constants_test.dart` (this change) | the code CONSTANTS it quotes |

Pinned here: `EMPTY_SECTION_ATTEMPTS`, `WINDOW_PROBE_REACHES`, both ends of
the island COMID band, the island short-range cycle, GEOGLOWS's run-age cap,
the four run-age caps stated as `16/16/24/36h`, and the island hold and
run-age caps. **All were already correct when checked**, which makes this
prevention rather than correction, and that is the point: the claims that
stayed true are the ones something was checking.

**MY OWN GUARD WAS WRONG BEFORE THE DOCUMENT WAS.** The first version
reported CLAUDE.md's GEOGLOWS cap as wrong, 42h against 48h. CLAUDE.md was
right: `hold_policy.dart` lists `geoglowsForecast` in BOTH `maxHold` (48h)
and `maxRunAge` (42h), and the unscoped pattern matched the first table it
found. A guard that reads the wrong number is worse than no guard, because it
teaches you to distrust the document. Claims can now name the declaration
they belong to, and the reason is written at the field.

**Deliberately not pinned, and said so in the file:** the flood tileset's
zoom range, retention and tile-size percentages. They describe a Mapbox
artefact built by a script outside this repo, so there is no source of truth
on disk and a test would only restate the prose back to itself.

**Break-it review.** Eight mutations, all caught, both directions: the doc's
number drifting; the code's number drifting; a run-age cap moving under the
doc; the island band shifting; the island cycle changing; the GEOGLOWS cap
moving in one table only, which is the case that caught me out; the doc
dropping a claim entirely; and the island hold cap changing.

**What remains open on item 13, precisely.** The audited claims that are
prose rather than numbers or paths. They cannot be enumerated from here
without redoing the audit, and no test can check whether a paragraph still
describes the system. The stamp rule at the top of CLAUDE.md is what governs
new ones, and these three guards are what hold the checkable ones. That is
the end of what this item can be taken to without a fresh audit.

1,522 tests, analyze clean.

**A rule for myself, written down because I broke it twice today.** Both
times I stated a test count by ARITHMETIC — previous total plus however many
tests I thought I had added — and both times it was wrong by four, because a
directory run reports the directory's total and not my additions. The count
is free to read: run the suite and copy the number. Do not compute a figure
that a command will tell you.


## Item 16 — the global forecast function was still being killed for memory

**WRITTEN AND TESTED, NOT DEPLOYED.** Same standing as item 6: this is server
configuration and takes effect only on
`firebase deploy --only functions:geoglows`. Nothing about the running
system has changed, and the deployed `containerConcurrency` is still 80.

**Broken.** `geoglows_forecast` was recorded as fixed in August. It was not.

⏱ MEASURED 2026-11-09 from production logs (`gcloud logging read`, 30-day
window, as `jersondevs@gmail.com`): **three memory-limit kills, all on
2026-11-03**, at 2056, 2071 and 2075 MiB against the 2048 limit. n=3,
min 2056, median 2071, max 2075. Overshoot 8 to 27 MiB. Plus one "container
instance was found to be using too much memory and was terminated".

**The August change raised the ceiling and left the cause alone.** It went
from GB_1 to GB_2, which fixed the single-request peak. But Cloud Run packs
concurrent requests onto one instance and **the default for a Firebase
function is eighty**, while one in-flight request holds ~1.03 GB of
xarray/zarr machinery. Two cannot fit in 2 GiB, so the second request kills
the instance serving the first. Every overshoot being 8 to 27 MiB is the
signature of that rather than of a leak: a leak does not stop politely just
over the line. Confirmed against the live service, which was still carrying
`containerConcurrency: 80`.

The conclusion was already written down in the same file.
`geoglows_conditions_worker` sets `concurrency=1` at GB_4 and explains why:
"the work is memory-bound, not IO-bound, so there is nothing to gain from
sharing an instance anyway." That applies here word for word.

**Changed.** `concurrency=1` on all four GB-scale HTTP endpoints:

| Function | Basis |
|---|---|
| `geoglows_forecast` | the measured defect above |
| `geoglows_reach_coords` | arithmetic, not a crash: its own comment documents a ~1.1 GB transient parse peak against the same 2 GiB limit, so two concurrent cold parses cannot both fit. **Zero memory-limit kills in 60 days of logs**, and the reason is traffic rather than safety, because the app resolves a reach's coordinates once and persists them. That is luck, and removing the exposure is cheaper than relying on it. |
| `geoglows_stream_conditions`, `nwm_stream_conditions` | retired conditions functions; the first is deployed but has logged nothing since 2026-08-18 and the second is not deployed at all. Nothing operational changes, and it is the correct value if either is revived. Set rather than excused, so the guard needs no allow-list. |

No `max_instances` added: concurrency is what fixes the OOM, and capping
instances would trade a crash for a queue with no measured need.

The three MB_512 endpoints keep the default on purpose. They serve a cached
blob and pinning them would cost scaling for nothing; a test asserts that
too, because "everything declares concurrency" would otherwise be satisfiable
by pinning the whole file.

**Break-it review.** Seven mutations, all caught: `geoglows_forecast` losing
the setting, and set to 2 rather than 1; `geoglows_reach_coords` losing it;
each of the two GB_4 functions losing it; a light endpoint needlessly pinned
to 1; and `geoglows_forecast` renamed, which would leave the guard reading
nothing. Two earlier mutation attempts were invalid rather than survivors:
one inserted a comment instead of removing the setting, and one had an anchor
matching three places. Both are recorded because an invalid mutation reported
as a survivor is how a real gap gets missed.

`functions_geoglows/` is Python with no test infrastructure at all, so the
guard lives in the TypeScript suite and reads `main.py` off disk. That is
already how this project pins cross-language contracts
(`hold-policy-drift.test.ts` reads the Dart freshness tables). It is
source-level and says so: it checks the DECLARATION, not the deployed
service.

**Q3, unproven:** that `concurrency=1` ends the kills. It follows from the
arithmetic and from the sibling function's measured experience at GB_4, and
it cannot be confirmed without deploying and watching. Recorded as unproven.

501 functions tests, tsc clean.

## Item 17 — the deployed flood-builder image was missing the guard that exists in source

**FIXED IN SOURCE, IMAGE NOT REBUILT.** The source lives outside this repo at
`~/Developer/rivr-tiles/`, which is not a git repository, so there is nothing
to commit there; what is committed here is the record and the build
instruction. **The running image is still the old one.**

**Broken, and confirmed exactly as the backlog described it.**
`cloudrun/build_flooded.py` is a COPY of `daily/build_flooded.py`, because
Docker's `COPY` cannot reach outside the build context and the context is
that directory. The copy was taken 2026-08-19 at 16:13 and the maintained
script gained its guard at 19:10 the same day. The copy never caught up.

Diffed the two: the difference was **exactly and only** the 28-line guard
block, nothing else. So the deployed image reached
`restricted = bool(args.only or args.vpu)`, logged "both-networks and
plausibility gates relaxed", and then published anyway. That is the precise
sequence that once uploaded East Africa's 2 flooded reaches over the live
100,220-feature tileset and pointed every app at 40 KB of Tanzania.

The daily schedule passes no arguments, so `restricted` is false for it and
the exposure was only ever the manual
`gcloud run jobs execute ... --args=...`. That is the command a person runs
while testing, which is when the guard matters most.

**Changed.** Copied the maintained script forward, so the two are now
byte-identical (verified by `diff -q` and an md5 of the backup first). Copying
rather than hand-porting removes any chance of transcribing the guard wrongly,
and the diff proved it was safe: there were no container-specific adaptations
to preserve.

**And a check so the drift is noticed next time**, because the stale copy was
the real defect and it would simply recur. `cloudrun/check_in_sync.sh` diffs
the two files and exits 1 when they differ. Both the Dockerfile and this
repo's CLAUDE.md now say to run it before `gcloud builds submit`.

**Break-it review.** The check was tested against the real historical drift,
in both directions: restoring the pre-fix copy (the actual stale file, from
the backup) makes it exit 1 and print the missing guard; with the files in
sync it exits 0. That is a mutation using the genuine defect rather than an
invented one.

**Q3, unproven and important:** that the deployed image now carries the
guard. It does not. Nothing was rebuilt and nothing was deployed, so the
exposure on the manual command is unchanged until
`gcloud builds submit` is run. Recorded rather than implied.

## Item 15 — Firestore had no backup, no PITR and no delete protection

⏱ MEASURED 2026-11-09, read back from the live project as
`jersondevs@gmail.com`:

| | Before |
|---|---|
| `deleteProtectionState` | `DELETE_PROTECTION_DISABLED` |
| `pointInTimeRecoveryEnablement` | `POINT_IN_TIME_RECOVERY_DISABLED` |
| backup schedules | `Listed 0 items.` |
| existing backups | `Listed 0 items.` |

All three, exactly as the backlog said. Together they mean an accidental
deletion of the production database today has **no recovery path at all**,
for an app that is live on both stores.

**DONE: delete protection is now ENABLED**, verified by read-back
(`DELETE_PROTECTION_ENABLED`). This is the one mitigation of the three that
is free, so there is no trade to weigh: it makes
`gcloud firestore databases delete` refuse until someone explicitly turns the
flag off again. It changes nothing about reads, writes, latency or cost, and
it is reversible with one command. Recorded here as the reason, per the rule
about not changing cloud resources without one.

The reason it was worth doing unprompted rather than queued: with PITR and
backups both off, deletion is unrecoverable, and this project's own history
is of destructive accidents rather than hypothetical ones. A `--vpu 101` test
replaced the live tileset with two reaches in Tanzania; `User.delete()` on a
stale reference destroyed a real account of eight months; a merge deleted a
tester's saved rivers. The pattern is consistent and the protection is free.

**NOT DONE, because both bill and that needs Jerson's yes:**

```bash
# Point-in-time recovery (raises version retention from 1 hour to 7 days)
gcloud firestore databases update --database="(default)" \
  --enable-pitr --project=ciroh-rivr-app

# A daily backup kept for a week
gcloud firestore backups schedules create --database="(default)" \
  --recurrence=daily --retention=7d --project=ciroh-rivr-app
```

**The cost is unquantified and deliberately not guessed.** Both are billed on
stored volume. The database is small — the only collection that was ever
unbounded is `publish_cadence_log`, now TTL-capped at 90 days of hourly
~2 KB samples, and `river_data` holds roughly 35 reaches times 7 products,
overwritten in place — so the bill is very likely trivial. **That is an
estimate from collection shapes, not a measurement**: the
`firestore.googleapis.com/document/count` metric does not exist for this
project, so there is no figure to read, and quoting unit prices from memory
is the thing this phase has spent its time correcting. Worth a minute in the
console before saying yes, not because the answer is in doubt but because the
number should come from somewhere.

**Break-it review.** No mutation applies: this is a one-bit state on a cloud
resource, not code. What stands in for it is the read-back, which is the rule
this repo already has for its pipelines (five operations have exited 0 while
producing wrong or partial data). The `update` command's own output was not
trusted; the state was re-read with `describe` and confirmed changed.

