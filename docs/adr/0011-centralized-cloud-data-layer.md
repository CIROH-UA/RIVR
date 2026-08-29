# 0011 — One source of truth for favourite rivers

**Status:** Phase 0 deployed and collecting. Phases 1–3 complete, merged. Phases 4–9 specified, not implemented.
**Supersedes in scope:** ADR 0010 (Weekly Outlook latency) — one symptom of this
**Related:** ADR 0001 (SSOT repository), ADR 0002 (canonical derived values),
ADR 0008 (push)

> **Rewritten 2026-08-22.** The original framing was "upstream is slow, so cache
> it." Measurement disproved the premise — see *What we actually measured* — and
> the justification is now **consistency and source-centralisation**, not speed.
> The conclusion survived the correction; the reasoning behind it did not, and
> the phase order changed as a result.

---

## Why we are doing this

Jerson, on the requirement that started it:

> *"I just don't want two different devices and/or accounts to have that same
> stream as favorite and see different flow values."*

Four things follow, and **none can be solved on the device**:

1. **Consistency across devices and accounts.** Two phones asking upstream
   separately get answers from different moments, and the numbers move. The only
   way two devices show the same value is if they read the same stored value.
2. **The app looks fast in every state** — online, offline, upstream healthy,
   upstream down — because it always reads local storage rather than waiting on
   a network it does not control.
3. **One place to reconcile multiple streamflow sources.** NWM and GEOGLOWS have
   different id schemes, cadences, proxies and failure modes, and every screen
   currently has to know which it is dealing with. A store normalises that, and
   a third source becomes a server change.
4. **Data-source changes stop requiring an app release.** If NOAA alters its API
   or a source is added, that is a deploy — not a build, not TestFlight, not
   Apple review. Given three months lost to an Apple lockout, not a small
   benefit.

**Speed is not on this list.** It used to be the whole argument. It isn't.

## The bar

**No value takes longer than 3 seconds to appear.** Favourites effectively
instant. Non-favourites: "as fast as upstream allows, shown progressively, never
a blank wait" — a different promise, honestly kept.

---

## What we actually measured

All figures 2026-08-21/22. The originals came from one degraded sitting and were
wrong in ways that changed the plan.

### Per-endpoint latency and reliability

10 rounds, 3 minutes apart, **all five variants fired simultaneously** each round
so a bad window cannot favour one. 50 samples.

| endpoint | success | avg | worst |
|---|---|---|---|
| `?series=analysis_assimilation` | **10/10** | **2.1 s** | 8.4 s |
| `?series=short_range` | **10/10** | **2.2 s** | 8.6 s |
| `?series=medium_range` | 9/10 | 10.9 s | 34.7 s |
| `?series=long_range` | 10/10 | 15.7 s | 51.5 s |
| unfiltered (all series) | 8/10 | 10.5 s | 35.6 s |

**This corrected the thesis.** The two products a detail sheet needs for current
flow answered in ~2.1 s, 10 out of 10, straight through a window where heavier
calls were timing out. Upstream is not slow — **we were asking the wrong
question**, fetching a 156 KB forecast series the sheet never rendered.

Under stress, weight is what fails: all three failures fell on heavy requests.
**Not established:** that the unfiltered endpoint is *specifically* fragile — the
failures cluster by time as well as by weight, and separating those needs
failures spread across many rounds. The Phase 0 probe now samples all five hourly
to settle it.

Supporting measurements, same period: NOAA `/reaches/{id}` metadata 0.30–1.11 s
at ~0.54 KB; CIROH `/return-period` 1.0–9.1 s at 0.2 KB; the GEOGLOWS proxy
~20 s at 24 KB.

### Publication is late and variable

| series | at 06:45Z | at 07:23Z |
|---|---|---|
| short_range | 21 Aug 23:00Z | 22 Aug **05:00Z** |
| medium_range | 21 Aug 18:00Z | 22 Aug **00:00Z** |

The 00Z medium-range run appeared **~7 hours after its nominal cycle**. Against
NOAA's documented 6-hourly cadence that is genuinely late, so **`referenceTime`
is the freshness signal, not elapsed time**. An 8-hour-old value *is* the latest
available when nothing newer has published.

`referenceTime` was identical across 8 sampled reaches — consistent with atomic
publication, not proof of it. Phase 4 guard 3 is designed so the answer does not
matter.

### Upstream goes fully down

On 2026-08-22 every `/streamflow` series returned 504 after ~60 s, filtered and
unfiltered alike, six consecutive attempts, while `/reaches/{id}` metadata, CIROH
return periods and GEOGLOWS all answered normally. **During that window the app
could not show a flow value for any NWM river, because nothing renders from
storage.** The Phase 0 probe has caught further outages since.

### NOAA's documented cadence

From [NOAA](https://water.noaa.gov/about/nwm), their wording:

| configuration | cadence | horizon |
|---|---|---|
| Analysis & Assimilation (CONUS) | "cycles hourly" | real-time |
| Short Range (CONUS) | "cycles hourly" | 18 h |
| Medium Range (CONUS) | "executed four times per day" | 10 d / 8.5 d, 6 members |
| Medium Range **Blend** | "executed four times per day" | 10 d, deterministic |
| Long Range (CONUS) | "cycles four times per day" | 30 d, 16 members |
| **Alaska Short Range** | **"cycles every three hours"** | 15–45 h |
| **Hawaii / Puerto Rico Short Range** | **"cycles two times per day"** | 48 h |

"Blend" refers to the *weather input*, not the river output: it is forced by NBM
precipitation plus GFS for other fields, where standard medium range uses GFS
alone.

**Bug:** `NwmDataSource.validUntil` applies the CONUS rule to every reach, so a
non-CONUS reach expires short-range data hourly for something that changes 2–8×
a day. Belongs to whichever phase touches `validUntil`.

### Disproven — short_range for "current flow" is not a defect

The product named `analysisAssimilation` actually fetches short range. Measured
across five reaches at the same `validTime`: two identical, three differing by
**under 1.1 %** — far inside return-period spacing, so it cannot change a flood
category. And short range came from a **fresher run** (13:00Z vs 11:00Z). The
series in use is more current, not less. **Only the name misleads** — rename in
the sweep; changing the behaviour would regress freshness.

---

## Decisions

### Scope

1. **The cloud store holds favourited reaches only.** Nothing else is stored.
2. **Non-favourites call the REST API directly**, progressively, fetching only
   what the consuming screen needs. With millions of streams, two users hitting
   the same unfavourited reach before it changes is effectively never, so storing
   them is cost without return.
3. **Non-favourites still cache on the device** — decision 9.

### The store

4. **Storage is per-reach, shared across all users and accounts.** Not per-user
   bundles: those are written at different moments and reintroduce the divergence
   this exists to remove.
5. **Freshness is keyed on `referenceTime`** (NWM) / `forecast_date` (GEOGLOWS),
   never on wall-clock TTL.
6. **An hourly probe decides *when to try*; each reach records the
   `referenceTime` it actually returned.** Progressive publication or a transient
   per-reach failure then costs a retry, not stale data under a fresh label.
7. **The work list is derived** from the union of all favourites each run.
   Nothing is reference-counted; orphans are garbage-collected.
8. **GEOGLOWS syncs once daily at 11:30 UTC**, keyed on `forecast_date`, and
    **gated on the date rather than trusted to the hour**.

    The hour is not a guess and must not be re-guessed: `functions_geoglows/
    main.py` records the daily run publishing at **10:15-10:30 UTC**, measured
    from S3 Last-Modified on two consecutive days, which is also why the flood
    builder runs at 11:00.

    It ran at 01:30 until 2026-08-29 on the assumption the 00Z run was out by
    then. It never was — 01:30 on the 28th returned the 27th's run, 01:30 on the
    29th returned the 28th's, and a direct query at 03:07 on the 29th still
    returned the 28th's. So the store **never once held the current day's run**:
    it took yesterday's and held it 24 hours while any device on the live path
    picked up the new one as soon as it appeared. That is Phase 5 guard 2 —
    two devices, one river, identical values — failing by construction, every
    day, found from a device log rather than review.

    The gate is what makes the hour safe rather than lucky: the run probes ONE
    reach for its `forecast_date` and fans out only when that date advances, so
    a late publication is a cheap no-op that retries instead of another silent
    day of yesterday's water.

    **An hourly version was written and reverted the same night.** It turned 4
    fetches a day into 24 to rediscover a number already on disk, and a cold
    proxy call costs 10-14s against a zarr on S3 (2.5s only when an instance
    still has that river cached) — the exact waste the store exists to
    remove.

### On the device

9. **The device cache retains until superseded by a newer run**, never on a
   clock. Publish-aligned: tap a stream, back out, tap again eight minutes later
   → no network call, because there is provably nothing newer. LRU-capped;
   favourites pinned.
10. **The app subscribes to its favourites with Firestore snapshot listeners.**
    No polling, no interval, no timestamp comparison. Verified against the
    [Firebase docs](https://firebase.google.com/docs/firestore/manage-data/enable-offline):
    offline persistence is **on by default** on iOS and Android, reads and
    listeners serve from the local cache while offline, and `fromCache` reports
    which. The screen renders instantly from that cache — cold start, offline,
    upstream down — and updates when our cloud writes.

    *The app has no snapshot listeners today; every read is a one-shot `get()`.
    This is a new pattern for the codebase, and listener lifecycle — attach on
    view, detach on dispose — is a real leak and billing risk, not a formality.*
11. **One store in the app.** Every widget reads through it. No widget fetches.

### Correctness

12. **Unit conversion must survive intact and stay efficient** — see below.
13. **Derived values are computed in exactly one place.**
    `weekly-digest.ts:242` has `categoryIndexFor()` server-side while the client
    classifies independently. `notification-service.ts` has a third,
    `evaluateAlert()`, which compares against the raw `return_period_*` fields
    instead of the 2/5/10/25 ladder. Three implementations of one rule is the
    drift ADR 0002 exists to prevent — and they had already diverged: until
    `28de63e` the alert path used a strictly-greater comparison, so a flow
    landing exactly on a return period read as Action in the digest and
    produced no alert at all. Phase 6 guard 3 is where these collapse into one.
14. **Cached payloads carry a schema version.** Entries without a recognised
    version are discarded, not parsed.
15. **Alerts read from the store and evaluate when a new run lands.**
    ~~The existing 6-hour cooldown remains the notification governor.~~
    **Corrected 2026-08-29: there is no cooldown.** `checkRecentAlert` runs and
    its answer only changes the wording to "still"; nothing skips a send. The
    governor is decision 19's trigger model — entry, escalation, a per-stream
    persistence interval, and an all-clear.
16. **No timestamps beside values.** Users should trust that what they see is the
    latest available; making that true is our job. A signal appears only when we
    *know* we are out of sync.
17. **The map's coloured streams and legend are finished and out of scope.**
18. **The alert floor is Action** — the lowest flood category, crossing the
    2-year return period. Confirmed by Jerson 2026-08-29 when the alternative
    (starting at Moderate) was put to him.

    This NAMES existing behaviour rather than changing it: `evaluateAlert`
    already fired on any exceeded threshold, and the lowest threshold is the
    2-year one. It was undocumented and implicit in a loop, so raising or
    lowering it would have been a one-character change nobody would have
    recognised as a policy change. It now lives in `warrantsAlert`
    (`flow-classification.ts`) with a test, so moving it has to be deliberate.

    The reasoning for keeping it low: a river reaching Action is rare, and this
    app exists to say so. The noise problem a low floor creates is not solved by
    raising the floor — it is solved by decision 19's per-stream frequency,
    which quietens a river that misbehaves without quietening the ones that
    matter.

---

## Unit conversion — the constraint the shared store creates

It works today. It must still work, and still be cheap, when this is done.

**Today** `NwmDataSource.fetch` stamps the payload with
`_unitService.currentFlowUnit` — *the fetching user's preference* — and codecs
convert from `entry.unit` to whatever the reader wants. Sound only because every
device fetches for itself.

**A shared per-reach document cannot do that.** If one user prefers CFS and
another CMS, whichever fetched first would poison the document for the other. So:

- **The store holds the native upstream unit**, never a user preference.
  `RiverDataEntry.unit` already exists for exactly this.
- **Conversion happens on read**, on the device.
- **Return periods are always CMS on the wire**, regardless of what the entry is
  tagged. A live landmine: swapping `'CMS'` for `entry.unit` silently
  misclassifies *every* flood category, and before it was guarded that mutation
  left all 881 tests passing.
- **Switching units re-renders from the cached entry with zero network calls.**
  Conversion is read-time, never a reason to refetch.
- **The same reach shows the same number, in the reader's unit, on every
  screen** — the consistency goal restated at the value level.

Every one of these gets a guard. This is where a regression would be invisible
and wrong rather than visibly broken.

---

## Existing assets this builds on

| asset | state |
|---|---|
| `RiverDataRepository` | SWR, keyed `(source, reachId, product)`, in-flight dedup — already the single-store mechanism |
| `RiverDataKey.storageKey` | emits `nwm__23021904__mediumRange` — usable directly as a Firestore document ID |
| narrow NWM products | `reachMetadata`, `analysisAssimilation`, `returnPeriods` — added in Phase 1, already used by the map sheet and forecast page |
| `return_period_cache` | Firestore, keyed by reach ID, server-written — the pattern already in production |
| `checkRiverAlerts` | already fans out over every distinct favourite 4×/day, then discards the data |
| 6-hour alert cooldown | `checkRecentAlert`, composite index declared |
| `probePublishCadence` | Phase 0, deployed, sampling five endpoints hourly |

Current scale: **18 users, 14 with favourites, 36 favourite rows, 29 distinct
reaches.** Cost scales with distinct favourited reaches × cadence, not with users.

---

# Phases

**Discipline for every phase.** Each guard must include at least one test
*demonstrated to fail before the change and pass after*. A guard that passes
against the current code is not a guard — this repo has produced several, and
four consecutive Phase 1 reviews each found another.

**Sweep the class, not the instance.** When a review reports a defect, the
question is not "where was it reported" but "where else does this shape exist".
Nine Phase 1 rounds found the *same* defect on three different surfaces in
sequence — the geocode on the critical path was fixed on the sheet, then found
on the NWM page, then on the GEOGLOWS page — because each fix addressed the
report rather than the class. Jerson's framing: being told to clean under the
bed does not mean the rest of the floor was not part of the job.

Practically: after any fix, enumerate every surface that could exhibit the same
shape and check each. The surfaces that display river data are the map detail
sheet, the forecast page (NWM and GEOGLOWS branches), the Weekly Outlook page,
the favourites card, and the two providers.

Round 11 repeated it once more, this time on the Weekly Outlook: the surface got
the *fixes* (geocode off the build path, error precedence, DI seam) but almost
none of the *guards*, so four separate mutations — geocode restored to the build
path, CMS conversion dropped, `Future.wait` replaced with a serial loop, failure
reporting deleted — each left the suite green. The class list below is now
checked mechanically, surface by surface, before a round is submitted.

**Never build a guard on top of the defect.** Round 11's sharpest finding. The
Weekly Outlook's first widget test drove its error state by leaving
`IGeocodingService` unregistered — which only *worked* because `_service` was a
`late final` resolved inside `_load()`'s try, i.e. the very defect the same phase
fixes on the NWM forecast page. Applying the fix turned three of the four new
tests red. A test whose fixture is a bug cements the bug. Before writing a
failure test, ask which production path produces this failure — if the answer is
"a misconfiguration that a different guard already proves cannot happen", the
test is wrong, not the code.

**A catch that wraps the callback makes its `mounted` check unfalsifiable.**
Three variants of this, found across rounds 11 and 12, all on all four surfaces:

1. *The geocode chains.* `.then(cb).catchError(h)` routes `cb`'s own throws into
   `h`, so `setState() called after dispose()` was swallowed by the handler meant
   for a failed lookup. The catch now covers the geocode only.
2. *The load paths.* The success `setState` sat inside the load's own `try`, so
   the same throw was caught there and rendered as a load failure. The success
   `setState` now happens after the `try`, and the sheet's three product reads
   use `then(cb, onError:)` — unlike `.then(cb).catchError(h)`, a throw from `cb`
   does not reach `onError`.
3. *Two redundant checks.* With a `mounted` check both inside and after the
   `try`, each covered for the other: removing either alone changed nothing a
   test could see. One check now sits immediately before the `setState` it
   protects. The map sheet had a second form of this — every guard read
   `_isCancelled || !mounted`, and `dispose()` set `_isCancelled`, so the two
   conditions were always equal. Deleting the whole flag left 973 tests green.
   It is gone; `mounted` alone is the check.
4. *The failure path.* Every "disposing mid-flight is safe" test popped while a
   load was **succeeding**, so the `mounted` check on the catch — and on the
   sheet's `markSettled`, which writes the error card — was unfalsifiable on all
   four surfaces at once. Each surface now has a paired test that pops while a
   **failing** load is outstanding.

**A rebuild-from-scratch `setState` wipes state that arrived between rebuilds.**
Round 14's live bug: the forecast page's per-product `publish()` rebuilt
`_details` wholesale from the product values, so a geocoded place label that had
already rendered was silently erased when the next product landed — present at
300 ms, gone at 6 s, and the measured latencies (metadata 0.3-1.1 s, geocode
~0.1 s, return periods 1.0-9.1 s) made that ordering the normal case. Values that
arrive outside the rebuild's inputs must live in state the rebuild reads, not in
the record it overwrites. Corollary for tests: a "renders while slow product is
out" test must re-assert AFTER the slow product lands.

**Moving work off a path moves every consumer of its result.** Round 15's live
regression: taking the geocode out of the outlook build meant rows no longer
carried labels when `_recordOutlookOpen` persisted `row.title` — so the user doc
the Friday push banner reads got "Station 9962444" written over a correct
"Provo, UT", while the screen (which fills labels reactively) stayed right. The
worst shape a bug can take: the visible output and the persisted output diverge,
and every test looks at the visible one. When a value stops being computed
eagerly, grep for every consumer of the field and decide per consumer: wait,
skip, or read the post-fill state.

**A guard that classifies independently cannot guard the classifier.** The page's
NORMAL text comes from `FlowGauge`, which runs its own `FlowClassification` on
the raw props — so hardcoding every classifier *in the page* left the suite
green. Assert on output the code under test computed (`_returnPeriodBand`'s
"10–25 yr" text), not on a sibling's recomputation.

**A guard nothing can drive is not a guard; label it.** Where a check survives
because its path is genuinely unreachable (`WeeklyOutlookPage._load`'s catch,
which `buildOutlook` cannot enter since it catches per row), the comment says so
outright. The alternative — leaving it to read like a tested property — is how
five rounds of review kept re-finding the same thing.

Related, and the reason round 12 could prove all of this: a dispose test must pop
while the thing it guards is *actually outstanding*. Popping during the reads
never runs the geocode callback; popping after the load never runs the post-load
`setState`. Both holes existed on all four surfaces at once, so the whole
family of "disposing mid-flight is safe" tests was vacuous.

**An `async` method's GetIt lookup does not throw to its caller.** Hoisting a
resolution to the top of an `async` `_load()` looks like it moves the failure out
of the `try`, but an `async` body never throws synchronously — the error lands in
an unawaited Future and arrives after the test body finishes, where
`takeException()` cannot see it. Resolve dependencies in `initState`, where the
throw is a real mount-time failure.

**Scope guards where the failure lives.** Repeatedly a guard was written one or
two layers above the thing it claimed to prevent and was structurally blind to
it. If a fetch happens inside `ForecastService`, a fake `IForecastService` cannot
see it.

**No legacy paths survive a phase.** Whatever a phase replaces, it deletes — not
later, not behind a flag. Work happens on `development` and every working version
is on `main`, so deleted code is recoverable from history and need not be
recoverable from the tree. The one exception is the Phase 5 kill switch, removed
in the sweep once the store is proven.

**Stale documentation is a defect**, fixed in the phase that caused it.

## The review gate — the last guard of every phase

**No phase is complete until an independent agent review passes.** A gate, not a
formality.

- A **fresh agent with no context from the implementation.**
- Given the guards, the "you are done when", and the diff — **not** a summary of
  what was done. Summaries are where self-deception hides.
- **Verifies independently.** Commit messages, comments and this ADR are
  assertions to check, never evidence.
- **Adversarial**: "how is this still broken?", not "does this look right?"
- Output per guard: `MET` / `NOT MET` / `CANNOT VERIFY`, each with a command and
  its output or a `file:line`. **`CANNOT VERIFY` is a failure.**
- **Reports, does not fix.** Merging those roles recreates the problem.
- **Mutation-tests the guards**: break the property deliberately and confirm a
  test dies. This has caught more real defects here than any other technique —
  scoped to the phase's **core properties** (3-4 per phase), not every comment.

Hunt this project's known failure modes: fake guards; unearned "measured"; silent
success; stale docs; a second way to do the thing just centralised.

**Phase 5 is an exception: six rounds.** Decided 2026-08-25 by Jerson, on the
evidence of its first three rounds — which did not follow the pattern below.
Rounds 1-3 each found live, user-visible defects rather than hygiene: guard 1
unreachable because the store held no river names or flood thresholds; a kill
switch that never reached a running app; concurrent syncs duplicating every
listener and every bill; store fetchers retrying against an explicit
prohibition; and a kill switch that stops new ingests without reclaiming the
values already ingested. Phase 5 is the phase where the app starts trusting the
cloud store, so the cost of a defect surviving is a wrong number on a river
someone is standing in. The cap returns to three for Phase 6 onward unless
similarly re-argued.

**No phase advances until a round comes back with no blocking findings.**
Guards that can only be settled with a deployed server or a physical device
(Phase 5's guards 2, 3, 4 and the device half of 9) are recorded as OPEN and
owned by name — they are not review failures and must not be counted as
rounds spent.

**The cap: three rounds per phase, maximum.** Decided 2026-08-23, after Phase 1
took 17 rounds and Phase 2 eight. The ledger was clear: rounds 1-3 caught real,
user-visible defects that a 1,000-test green suite missed (a digest label
overwriting user data, a favourite evictable on every cold start, a page blank
for five seconds, a pin-wipe on a Firestore hiccup). Rounds 4+ almost
exclusively found correct-but-unguarded code, comment inaccuracies and doc
drift — hygiene priced at hours per round.

The agent gets **at most three attempts** to find defects that would make the
phase's goal fail. Rules under the cap:

- **What blocks:** live defects, and documentation that states something
  untrue. Nothing else fails a round.
- **What does not block:** correct code that lacks a guard, unlabelled
  defensive checks, style. These get fixed in the same pass as the blocking
  items — no additional round to re-verify them.
- After the final round's blocking findings are fixed and their fixes
  verified, the phase **closes**. Remaining review suggestions are recorded,
  not looped on.
- A phase may still close early: a round with no blocking findings passes it.

---

## Phase 0 — Baseline and instrumentation ▶ DEPLOYED, COLLECTING

**Stays regardless of everything else.** It has already corrected this document
twice, and it is cheap.

**Built.** `probePublishCadence` — hourly, all five NOAA endpoints fired
simultaneously, one schema-versioned document per hour into
`publish_cadence_log`. No retries: a retry hides the failure rate being measured.
`referenceTime` taken from the filtered calls, unfiltered as a cross-check.

**Guards.**
1. Seven consecutive days of hourly samples, no gap over an hour.
2. Publication lag characterised per series — median and worst.
3. Per-endpoint failure rate measured, settling "weight vs bad window".
4. Device-side timing for the detail sheet: elapsed ms per fetch, warm and cold.
   *Folded into Phase 1, which rewrites those paths; cannot close until Phase 1
   emits real numbers.* `AppLogger.metric` exists because `AppLogger.info` is
   debug-only and would be silent in release.
5. **Any claim in this ADR contradicted by the data is corrected before code
   depends on it.** Expect at least one.
6. Independent agent review passes.

**You are done when** you can state, from a week of data: how often each series
actually publishes, how late it typically is, how often each endpoint fails, and
how long the app really takes to draw a detail sheet warm and cold.

---

## Phase 1 — The non-favourite experience ▶ COMPLETE (gate passed, round 17)

**The review gate passed on round 17** — sixteen rounds failed first, each
documented in "Sweep the class, not the instance" above. The passing round
re-verified every prior fix by mutation (58 mutations, all killed or labelled),
found three low-severity gaps (F52 retry-leaked failure names, F53/F54
under-asserted skeletons), and all three were closed and mutation-verified in
the same pass. Declared carry-forwards at close: the <500 ms device capture
(Phase 0 guard 4 / Phase 8 guard 2) and the two documented `favoriteLabels`
limits (reachId-keyed across sources; place-over-stored-name).

Permanent value: non-favourites always take the live path.

**Built.** Three narrow reads issued together, each rendering as it lands. Medium
range is not deferred — it is **not requested**, because the sheet renders no
forecast series (its peak comes from the map tile). The forecast page reads the
same three keys, so "See forecast" is warm with nothing warming it.

**Guards.**
1. Sheet on screen **under 500 ms** with a skeleton, before any read completes.

   *The "before any read completes" half is guarded and mutation-proven. The
   **under-500 ms** half stays open at merge: it needs a device capture, which
   is **Phase 0 guard 4** and **Phase 8 guard 2**. Stated here so it is a
   declared carry-forward rather than an unnoticed gap.*

   *That capture must be taken in **debug or profile**, not release:
   `AppLogger.metric` uses `dart:developer.log`, which writes nothing without an
   attached VM service. An earlier note claiming it "always logs, including
   release" was wrong and is corrected.*
2. Values render as they land; a ready flow is visible while a threshold call is
   30 s out.

   *Guarded on the sheet since Phase 1 and — as of round 13 — on the NWM
   forecast page, which was batching all three reads through one `Future.wait`
   and one `setState`. It therefore showed nothing until the slowest landed:
   with `/return-period` measured at 1.0-9.1 s, a name and a flow that arrived
   in 10 ms sat invisible for five seconds. The page now settles per product.
   Its concurrency guard could not see this — concurrent reads and a batched
   render look identical to a start-time assertion — so the new guard drives
   per-product latency directly.*
3. **Medium range is never fetched on a tap** — asserted against the **real**
   `ForecastService` with a recording API client, plus a canary that the bundle
   *does* still fetch it, so the guard cannot become vacuous.
4. One read failing never blocks the others.
5. Exactly three reads, none waiting on another — asserted on recorded start
   times, not list position.
6. Terminal state **names what failed** and offers **Retry** — on all four
   surfaces, the Weekly Outlook included, where a total upstream outage used to
   render "No forecast is available for your rivers right now" with no way out.
7. The forecast page reads the narrow products, never the bundle.
8. A missing DI registration fails as a **wiring bug at mount**, never as a load
   failure with a Retry that cannot succeed. Resolutions live in `initState`:
   hoisting them to the top of an `async` load body is not enough, since an
   `async` body never throws synchronously to its caller.
9. Every `mounted` check is **individually falsifiable** — one check per
   `setState`, no redundant pair, no enclosing catch that swallows
   `setState() called after dispose()`, and a dispose test that pops while the
   guarded work is genuinely outstanding, on both the success and failure paths.
10. Independent agent review passes.

**You are done when** tapping any stream puts a sheet up instantly, titles it as
soon as the cheapest call lands, fills each number independently, never shows a
blank spinner, and "See forecast" does not repeat a wait.

---

## Phase 2 — Device cache discipline ▶ COMPLETE (closed under the 3-round cap)

**Closed 2026-08-23** after eight review rounds — the phase that motivated the
cap above. Real defects found and fixed with verified guards: the memory-only
pin set evicting a favourite on every cold start (round 1); the identity-change
clear missing deleteAccount and the auth-state listener (rounds 2-3); the
unbounded notifier/recency maps (rounds 3-4); first-found run extraction
stamping mediumRange with shortRange's run (round 6); a fabricated GEOGLOWS
wall-clock run id (rounds 6-7); and a swallowed Firestore error un-pinning
every favourite and persisting the empty pin set (round 8). All core
properties mutation-proven; remaining round-8 riders (guard-of-guard depth)
fixed in the closing pass without a ninth round.

**Before this phase nothing pruned the disk cache** — `evict()` and `clear()`
existed and nothing called them.

**Built.** Retention lives in `RiverDataCache`: an LRU cap on non-pinned
*reaches* (a reach's products are one unit — half-evicting a reach leaves a
name whose flow will never refetch with it), enforced after every write;
favourites pinned via `setPinnedReaches`, pushed by `FavoritesProvider` at its
single membership hook (`_updateFavoriteReachIds`) and **persisted to
`pins.json`**, so a cold-start put that beats the Firestore favourites load can
never evict a favourite (review round 1 caught the memory-only version doing
exactly that); schema version baked into both the entry JSON and the cache
**filename** (`<storageKey>.v<N>.json`), so the once-per-upgrade discard sweep
is a directory listing, not N file reads. LRU order is memory-tracked and falls
back to file mtime across restarts (stat once per group per session). Every
identity change — `signOut`, `deleteAccount`, and the auth-state listener's
revoked-token path, gated on a null that follows a non-null — clears the cache
and its pins through one `AuthProvider._clearRiverDataCache()` helper; clear,
pin-persist and entry writes are serialised so a fire-and-forget sign-out
cannot race the next account's pins. There is deliberately no time-based
deletion — an old entry whose run has not advanced is still the current data.

**Guard 6 (unit change, zero refetches) — resolved app-wide by Phase 3.** The
Phase 2 limit declared here (the legacy `ForecastService` cache wipe on a unit
flip) is gone with the caches themselves: the flip is now
`recomputeForUnitChange()` — zero cache clears, zero fetches, decode converts —
and the property is mutation-proven at the provider (Phase 3 guard 4).

**Build.** Retention keyed on **run supersession**, not wall-clock. LRU cap on
non-favourites. **Favourites pinned**, never evicted. Entries record the run they
came from so supersession is decidable offline, and carry a schema version.

**Guards.**
1. Inside its publish-aligned window an entry is served with **no network
   call**, however old in wall-clock terms — the window is the source's own
   schedule, never a generic TTL. Tap → back → tap again issues nothing.
   *Past* the window the cached value is still served instantly while ONE
   background revalidation runs (ADR 0001 decision D3): whether the run actually
   advanced is not decidable without asking, so the revalidate is the ask, and
   the user never waits on it. Entries record the run they came from
   (`runId` — NWM `referenceTime` lifted from the product's OWN payload
   section, GEOGLOWS generation date when the response carries one), so what a
   revalidate brought back is decidable from the stored data alone; Phase 5's
   store diffing builds on it. Declared exceptions, all null by design:
   products with no run (returnPeriods, reachMetadata), and a GEOGLOWS
   response carrying no generation stamp of any kind (minting one from
   wall-clock would make every refetch look like an update). (`reachSummary`
   was a third exception until Phase 3 deleted the product outright.)
2. Exceeding the cap evicts least-recently-used non-favourites and **never** a
   favourite — tested with the cap exceeded entirely by favourites.
3. Cache size stabilises under simulated browsing of many reaches.
4. Favouriting a previously-browsed stream renders instantly from cache.
5. **Upgrading over an old install discards unrecognised schema versions** rather
   than parsing them. Every upgrading user hits this once, on first cache use
   (`initialize` runs lazily from the first get/put/pin-push — the favourites
   load's `setPinnedReaches` typically triggers it during startup; nothing
   calls it directly, and nothing needs to).
6. **A unit-preference change re-renders from the same cached entry with zero
   refetches.**
7. Independent agent review passes.

**You are done when** browsing hundreds of streams leaves the cache bounded,
favourites survive eviction unconditionally, and a stream you looked at earlier
still draws instantly with the network off.

---

## Phase 3 — One data path inside the app ▶ COMPLETE (closed under the 3-round cap)

**Closed 2026-08-23.** Round 1 found one live defect (the chart stuck on "No
chart data available" when opened mid-load — fixed with a regression test) and
two documentation lies (fixed by finishing the build: the favourites card and
weekly outlook were rewired onto the narrow products and `reachSummary` +
the old `ForecastService` deleted for real). Rounds 2–3 failed only on stale
comments, all removed; every code fix held under mutation in both rounds.

**Built.** `ReachDataProvider` rewired onto `IRiverDataRepository`: its session
cache, private disk cache and hand-rolled SWR loop are deleted — the repository
already does all three. The 179-line cache mixin is gone; display values are
pure per-call derivations over the decoded response (`ForecastValues`, which
`ForecastService` now delegates to, so each rule has ONE implementation).
`ForecastService`'s three TTL caches and the whole legacy forecast disk cache
(`ForecastCacheService` + contract) are deleted, along with the four forecast
use cases, `IForecastRepository`, `ForecastRepositoryImpl` and three other
zero-caller use cases — the provider was their only client. `lib/ui/` holds no
reference to `IForecastService`/`NoaaApiService` (guard 1 is now a CI test, not
a grep); the weekly outlook service is DI-assembled; `ReachDetailsData` moved to
the domain layer; `CurrentFlowPayload.decode` no longer needs the fetch
contract. A unit flip is `recomputeForUnitChange()` — zero cache clears, zero
fetches; decode converts. Background revalidations reach open pages through the
repository's watch listenables.

**Review round 1 additions.** The favourites card and the weekly outlook now
read the same narrow products as every other surface (the card read the
`reachSummary` bundle; the outlook fetched NOAA directly per favourite per
open — both could disagree with the sheet about the same river). With their
last readers gone, `reachSummary`, its codec, `loadReachDetailsData` and the
rest of the old `ForecastService` (three TTL caches, seven load methods, ten
value helpers) are deleted — the service is now one method,
`loadBasicReachInfo`, backing the `reachMetadata` product; `IForecastService`
declares exactly that method. In total eight use-case files died with their
repositories. Guard 3's bundle-fetches-medium canary died with the bundle; the
source now REJECTS the product, and that rejection is the pinned test. One
live defect fixed: `InteractiveChart` extracted its series once and never
re-extracted, so a chart opened while medium range was in flight showed "No
chart data available" forever — it now re-extracts when the provider's
forecast identity changes (regression test drives the exact gated-read
window).

**Honest census, guard 6 (consumers).** The "ten consumers" of the old
provider were an overcount: `chart_preview_widget` is fully commented out,
`current_flow_status_card` and `forecast_category_grid` are mounted nowhere,
`geoglows_forecast_provider` mentions the provider only in a doc comment. The
live set — main.dart, reach_forecast_page, hydrograph_page, interactive_chart,
horizontal_flow_timeline, long_range_calendar, daily_flow_forecast_widget,
favorites_page — is exercised by the page/widget suites plus the new
interactive-chart test; hydrograph_page and long_range_calendar have no
dedicated widget test and are covered only via the page tests. Declared, not
hidden.

**Declared, Phase 5's problem:** `ReachCacheService` still stores reach info
(name, coords, thresholds) for `loadBasicReachInfo`'s fast path — a second
store for reach METADATA (never for flow series). It follows the metadata
product into the repository when Phase 5 touches this seam.

**Moved earlier in the rewrite.** Consistency is the goal, and this is what
delivers it *between screens*. It is also a prerequisite for the store being
useful: a shared cloud value is worthless if four widgets still fetch their own.

Before this phase the app was split — `favorites_provider` and
`weekly_outlook_page` read *both* through the repository and directly.

**Build.** Remove direct `ForecastService` / `NoaaApiService` use from
`reach_data_provider`, `reach_data_cache_mixin`, `hydrograph_page`,
`interactive_chart`, and the mixed paths in `favorites_provider` and
`weekly_outlook_page`.

**`ReachDataProvider` is the bulk of this phase — measured, not guessed.** 939
lines, mixing in a 179-line cache mixin, referenced from `main.dart` plus **nine**
forecast widgets and `geoglows_forecast_provider`. It is **rewired**, not deleted.

**Delete `ForecastService`'s competing cache layer** — `_currentFlowCache`,
`_flowCategoryCache`, `_recentResponseCache` and its `_forecastCacheService`
writes. Two caches with different TTLs holding the same reach is precisely the
divergence this ADR exists to remove. A correctness change, not cleanup.

**Guards.**
1. `grep -rn "NoaaApiService\|IForecastService" lib/ui/` returns nothing.
2. Every surface showing one reach shows the same value simultaneously —
   favourites card, detail sheet, forecast page, hydrograph.
3. Two widgets mounting the same reach issue **one** fetch.
4. **A unit flip repaints every surface without refetching.**
5. **Exactly one cache holds forecast values.**
6. All ten `ReachDataProvider` consumers render correctly after the rewire — each
   exercised, not assumed. The phase's main regression risk.
7. No method survives with zero callers, verified by search.
8. Independent agent review passes.

**You are done when** there is exactly one way for a value to reach the screen,
and no widget can fetch on its own even if someone tries.

---

## Phase 4 — Cloud store: write path, with monitoring ▶ DEPLOYED, RUNNING

**Review gate passed under the 3-round cap; deployed and verified in
production 2026-08-25.** Seven functions are deployed in `ciroh-rivr-app`; the
seventh, `storeStaticDaily`, was added and deployed by Phase 5:
`storeRefreshHourly` (:20 past), `storeGeoglowsDaily` (11:30 UTC),
`storeGcDaily` (03:40 UTC), `storeHeartbeat` (2-hourly), `storeHealth`
(HTTPS), `storeWriteThroughOnFavourite` (Firestore trigger). Composite index
`river_data(product ASC, runId ASC)` created and READY — without it every
hourly run aborts on FAILED_PRECONDITION.

**Every guard observed on live data, not inferred.** 121 documents stored.

| Guard | Observed |
|---|---|
| 1 no advance → no fetches | two unattended runs, 5 reads / **0 writes** each |
| 2 advance → every reach | 116 written first run; 4 on write-through |
| 3 own run, retried | each product on its own runId (23:00Z / 18:00Z / 12:00Z) |
| 4 failure keeps prior record | GEOGLOWS 500s left the stored document intact, twice |
| 5 native unit | CFS for NWM, CMS for GEOGLOWS; no user preference reachable |
| 6 no backwards writes | supersession skipped correctly under the transaction |
| 7 grace then delete | GC scanned 117, **deleted 0**, retained 4 unfollowed |
| 8 one document, one fetch | 29 reaches → 116 documents, no duplication |
| 9 favourite → seconds | **8.9 s, 4/4 written** on a real favourite |
| 10 schema version | `schema: 1` on every document |
| 11 usage vs free quota | GC 135 reads/0 writes; refresh 5/0; GEOGLOWS 20/1 — all **<1%** of daily free tier |
| 12 silent failure impossible | count assertion balanced on every run, including a mixed 1-written/1-failed |

**Guard 1 was proven by an upstream stall, which is a better test than a
normal cycle.** NOAA short range stopped advancing at `2026-08-24T23:00:00Z`
and was still there five hours later — confirmed by querying NOAA directly,
not just the probe. Both scheduled runs correctly did nothing. A naive
implementation would have refetched 116 documents every hour for data that
had not changed; that is the cost this phase exists to remove, and it was
removed in the only conditions that can demonstrate it.

**Still open, declared not hidden:**
- **No unattended NWM *write* cycle yet** — it needs NOAA to publish, which is
  outside our control. The write path itself is proven three ways: a manual
  trigger (116 documents), the GEOGLOWS daily run, and write-through.
- **Guard 6's own method is unexercised in CI.** The transaction is correct and
  was verified by hand in review, but there is no `store-firestore.test.ts`, so
  "test by interleaving two runs" has no automated test. Same for
  `store-service` and the trigger.
- **`geoglows_forecast` (Python) OOMs at its 1 GiB limit** — `1065/1024 MiB`,
  container killed, HTTP 500 on back-to-back requests. A pre-existing defect in
  a different codebase, surfaced because the store is the first caller to hit it
  twice in quick succession. Deliberately NOT hotfixed here; it needs a 2 GiB
  bump on its own branch. Phase 4 behaved correctly under it (guard 4).
- `readExisting` maps any read error to `FatalRunError`, so one transient
  Firestore hiccup aborts the whole hourly run. Loud, but wide.

Round 1 found the whole phase was a library — five pure modules with no entry
points, no Firestore adapter and no monitoring, so two guards came back CANNOT
VERIFY. It also found guard 3's retry half missing, and a test whose name
("a run killed part-way through throws") asserted the opposite of its body.

Round 2 found five: lagging measured against the stored document rather than
the probe (and `sampleStoredRun` taking the NEWEST run, so a straggler was
never revisited); `analysisAssimilation` fetched as NOAA's
`analysis_assimilation` while the client stores and decodes a `short_range`
body under that key; write-through planning products upstream cannot serve;
usage counting refused transactions and missing the transaction's own read; and
a required composite index neither declared nor deployed.

Round 3 found three, two reproduced against live upstreams: the GEOGLOWS proxy
emits `forecast_date` as `YYYYMMDD` and the parser accepted only `YYYY-MM-DD`,
so every GEOGLOWS fetch would have failed forever; a SECOND `SECTION_BY_PRODUCT`
map in `store-payload.ts` still pointed `analysisAssimilation` at its own
section, and because NOAA returns all five section keys with the unrequested
ones as `{}`, the trim kept the empty one and threw the real data away — round
2's F2 again, one file downstream, because one rule had two implementations;
and the `analysisAssimilation` trigger compared the probe's AA run against the
store's shortRange run, two different series ~3 h apart, so the product stopped
triggering after its first write.

**The pattern across all three rounds: every defect was a place where two
things that had to agree were written down twice.**

**Built.** `store-keys` (the document-ID and section contracts, pinned against
the Dart enums by tests that read them off disk), `store-work-list` (dedupe on
`(source, reachId)` — the phase's whole cost argument), `store-document`
(envelope, publish schedule, supersession), `store-run` (plan → fetch →
supersede → write, with the count assertion inside), `store-payload` (trimming;
>10× on medium range), `store-trigger` (probe→advance decision, heartbeat,
quota), `store-gc` (7-day grace, refuses a wipe), `store-upstream` +
`store-geoglows` (fetchers), `store-firestore` (the only DB file; supersession
re-checked inside a transaction), `store-service` + `index.ts` (hourly refresh,
write-through on favourite, daily GEOGLOWS, daily GC, heartbeat, health
endpoint). 194 tests.

**GEOGLOWS was briefly excluded on a false premise and put back.** The
exclusion claimed the proxy returned only the median. It does not —
`functions_geoglows/main.py` returns `flow_uncertainty_lower` and
`flow_uncertainty_upper` too. The existing `geoglows-client.ts` parses only the
median because it serves the ALERT path, and "my client ignores it" was misread
as "the proxy does not send it". GEOGLOWS is stored with all three bands, on
its own daily schedule keyed on `forecast_date`.

**Still open, declared not hidden:**
- **Nothing is deployed.** Guard 11 (reads/writes per day measured against the
  free quota) cannot be met until it is, and neither can the "done when".
- **The composite index is declared, not deployed.** `river_data`: `product`
  ASC, `runId` ASC. Without it every hourly run aborts on FAILED_PRECONDITION.
  Phase 6's guard already warns to verify indexes are deployed, not declared.
- **Guard 6's own method is unexercised.** The transaction is correct and was
  verified by hand in review, but there is no `store-firestore.test.ts`, so
  "test by interleaving two runs" has no CI test. Same for `store-service` and
  the write-through trigger.
- `readExisting` maps any read error to `FatalRunError`, so one transient
  Firestore hiccup aborts the whole hourly run. Loud, but wide.
- `sampleStoredRun` orders by `runId`; Firestore excludes documents missing
  that field, so a product whose documents all lack one would read as null and
  fan out hourly. Not reachable for the four managed products today.

---

Server-only; no app changes; fully verifiable before any client depends on it.

**Build.**
- **Hourly probe** decides when to try; on advance, fetch the affected products
  for every reach in the derived work list.
- **Per-reach documents** at `nwm__<reachId>__<product>`, matching
  `RiverDataKey.storageKey` so the document ID *is* the client cache key.
- **Store the trimmed payload** — the app reads `mediumRange['mean']`; storing
  only that should cut 156 KB substantially and keeps documents far from
  Firestore's 1 MiB limit.
- **Store the native upstream unit**, never a user preference (decision 12).
- **Each record carries the `referenceTime` it actually received.**
- **Per-reach retry across cycles.** Transient per-reach failures are real:
  `10376596` failed and then succeeded unchanged twenty minutes later.
- **Write-through on favourite**, so a newly-favourited reach is not absent until
  the next hourly run.
- **GEOGLOWS on its own daily schedule**, keyed on `forecast_date`.
- **GC** documents absent from the union and unrefreshed for ~7 days.
- **Security rules.** `firestore.rules` currently default-denies everything
  except `users/{userId}` — **the app cannot read any store collection today.**
  Store documents: readable by authenticated users, writable only by the Admin
  SDK. Never client-writable.
- **Monitoring ships in this phase, not after.** Probe `referenceTime` compared
  against every stored record; a heartbeat alerting when no successful write
  lands in N hours; a **count assertion** of reaches updated vs expected each run.

**Guards.**
1. No new run → **zero** fetches beyond the probe.
2. A new run → every reach in the work list updated, count assertion matches.
3. **A reach returning an older `referenceTime` than the probe is stored with its
   own value and retried — never written under the probe's run.** This makes
   atomic publication irrelevant.
4. A reach failing entirely leaves its previous record intact and is retried.
5. **Documents are stored in the native unit** — two users with opposite unit
   settings favouriting one reach produce a byte-identical document.
6. **Overlapping runs cannot write backwards**: a write carrying an older
   `referenceTime` must not replace a newer one. Test by interleaving two runs.
7. Unfavouriting everywhere removes the reach from the work list; the document
   survives the GC window and is then deleted.
8. Two users favouriting one reach produce **one** document and one fetch.
9. Favouriting a never-viewed reach produces a document within seconds.
10. Every document carries a schema version; an unrecognised one is rejected.
11. Firestore reads/writes per day measured against the documented free quota.
12. **Silent failure is impossible:** kill the fetch mid-run and confirm the count
    assertion fires. Five documented operations in this repo have exited 0 while
    producing wrong or partial data; exit status has never caught one.
13. Independent agent review passes.

**You are done when** the store has held correct values for every favourited
reach across several publish cycles with nobody watching, a deliberately broken
run raises an alarm rather than passing quietly, and "is the store fresh right
now?" is answerable from a dashboard.

---

## Phase 5 — Cloud store: read path via listeners

**Build.** For favourited reaches, `NwmDataSource` and `GeoglowsDataSource` read
the store instead of upstream. The repository, keys, products and freshness logic
are unchanged — a data-source swap.

**Delivery is a Firestore snapshot listener, not polling.** The app subscribes to
its favourites' documents; Firestore's local persistence renders instantly on
cold start and offline, and pushes updates when our cloud writes. No interval, no
timestamp comparison. **The app has no listeners today**, so lifecycle is new
ground and a real leak/billing risk.

Non-favourites continue to the live path.

**Kill switch.** A Remote Config flag forces every device back to the live path.
The flood pipeline already uses Remote Config this way, and an app release takes
days — if the store serves something wrong, the fix cannot wait on Apple.

**Guards.**
1. A favourite renders with **zero** upstream calls from the device.
2. **Two devices, two different accounts, one reach → identical values.** The
   requirement that motivated the design.
3. A favourite renders in **under 3 seconds** on a cold device cache.
4. **With the network off, favourites still render** from Firestore's cache.
5. A store write reaches an open app **without the app asking** — the listener
   property, tested.
6. Listeners are detached on dispose; no leak, no orphaned reads.
7. Values match what the old path produced for the same run, field by field.
8. A missing or malformed document degrades to the live path with no error shown.
9. **The kill switch works** — verified on a device, not in code review.
10. Older app versions on the direct path keep working; the store is additive.
11. Independent agent review passes.

**You are done when** two phones on different accounts, both favouriting one
river, show the same number at the same time — and each renders within 3 seconds
of a cold start, or instantly with no network at all.

**Settled on real devices, 2026-08-28/29.** These could not be closed from a
development machine, and running them was worth it: the session found four
live defects that the whole suite was green through, one of them guard 9
itself.

| Guard | Result | Evidence |
|---|---|---|
| 1 — zero upstream calls for a favourite | **PASS** | Clean install, empty cache: every favourite rendered from the store, 0 NOAA calls. The same test 20 min earlier made 78 — see the expiry-window defect below. |
| 2 — two devices, two accounts, identical values | **PASS** | iPhone (main account) and simulator (second account, `jersonjara7.18@`), reaches 18471070 / 10376596: White River 16702.1, Provo 179.1 on both, 0 NOAA calls for either reach. |
| 3 — renders under 3 s on a cold cache | **PASS** | Store subscribed 08:34:28, White River rendered 08:34:30. ~2 s. |
| 4 — renders offline | **PASS** | Airplane mode, Wi-Fi off, force-quit, reopen: all favourites rendered. The values were the store's own (16702 / 179, its 04:00Z short-range points), and they had reached the device only 40 s before the network was cut — so this is Firestore's offline persistence, not an older local cache. |
| 9 (device half) — the kill switch, flipped for real | **PASS, after a fix** | Failed first: with the switch off, a cold start made 0 upstream calls and parsed the store's trimmed payload. After the fix, the same test makes 51 calls across both favourite reaches and parses `analysis_assimilation (120 points)`. |
| The construction in `main.dart` | **PASS** | Covered by every device run above. |
| The `main.dart` lifecycle handler | **PASS** | Force-quit / relaunch cycles throughout. |

**Guard 9's failure is the argument for this table existing.** Eight review
rounds passed it. Two independent holes had to be open at once: an ingest
dispatched `unawaited` outlived the `detach()` that was supposed to stop it,
and `RiverDataCache.evict` deleted the file outside the serial chain that
`put`'s write joins — so the evicted entry was written straight back, and the
next cold start served store data with the switch off for as long as the entry
stayed fresh. The switch is what we would reach for if the store ever served
something wrong, so it failing silently is the worst available shape.

**Remaining, and NOT closed by the above:** guard 11 (independent agent review)
and the round 7 code items.

**`storeStaticDaily` and the extended `CAN_FETCH` are deployed** (2026-08-25;
Firestore holds 29 `reachMetadata` and 29 `returnPeriods` documents, counted
back out through the REST API rather than believed from the run's own logs).

**That prerequisite is met.** `store_read_enabled` was created by hand in the
Firebase console on 2026-08-28 and is `true`. Nothing publishes it; the Remote
Config API still returns no ETag for this project, so programmatic writes are
force overwrites and must read the whole template first and put every other
parameter back unchanged (done twice on 2026-08-29 to drive the guard 9 test,
each time verified by reading all four parameters back).

**A second prerequisite was found only by testing: the `river_data` Firestore
RULE had never been deployed.** It went into the repo 2026-08-24 but only
`firestore:indexes` was ever pushed, and that command exits 0. Every store read
on a device returned PERMISSION_DENIED, silently, so the phase was inert for a
different reason than this document predicted. Deployed and verified by reading
the live ruleset back on 2026-08-29 — not by trusting "Deploy complete".

---

## Phase 6 — Alerts on the store

**Two premises this section rested on are false, and were corrected on
2026-08-29 before any code depended on them.** Phase 0 guard 5 exists for
exactly this.

> ~~Free to change: no alert has ever been delivered — the `notification_logs`
> collection does not exist. And the 6-hour cooldown decouples check frequency
> from notification frequency, so raising the former cannot spam.~~

**Alerts HAVE been delivered.** `notification_logs` exists and holds real sends.
Reach 620569308 alerted Jerson every six hours, four times a day, for at least
three consecutive days (verified by reading the collection). This phase is not
free to change: it is changing something users are already receiving.

**And there is no cooldown.** `checkRecentAlert` runs, and its answer is used
ONLY to change the wording to "still". Nothing skips a send. So the claim that
raising check frequency "cannot spam" is backwards — moving evaluation to
hourly, as this phase does, would have taken four notifications a day to
twenty-four, for a river whose category had not changed once.

### Decision 19 — what deserves a notification (2026-08-29)

The question Jerson put: *"we built an app to notify users of high events and
now that we have it, will we just notify them once? A stream does not flood
often if ever. So when they do we should notify it."* Both halves are right,
and the resolution is that **the unit of news is a change, not a tick.** A
river sitting at Major for three days is one event, not seventy-two.

Four triggers, in priority order:

1. **Entry** — the reach crosses from Normal into any alert category. Sent
   under every frequency **except `off`**.

   This first read "always sent", and taken literally it meant a stream a user
   had muted still spoke twice — once when the event began, again if it
   worsened. Corrected 2026-08-29 when that consequence was put to Jerson:
   muting a river means "stop telling me about this one", and only the safety
   override outranks it.
2. **Escalation** — the category rises (Action → Major, Major → Extreme).
   **Always sent, and NOT suppressible by any user setting — including `off`.**
   The only true override in the system. Safety beats
   preference: Action to Extreme at 3am must wake someone regardless of what
   they chose. This is the one place the system deliberately overrides a stated
   user preference, and it was confirmed explicitly by Jerson.
3. **Persistence** — while the event continues without escalating, a reminder
   at the user's chosen interval for THAT reach. Default 6-hourly.
4. **All-clear** — the reach returns to Normal. Sent today by nothing at all,
   and genuinely useful: "it is over" is news. Only to someone who was told the
   event started — an all-clear for something a user never heard about is
   noise — and silenced by `off`, but NOT by `change-only`, because the end of
   an event is exactly the change that option asks for.

**A drop that is still elevated** (Extreme → Major) is a persistence
continuation, not an all-clear and not an escalation: the event has not ended
and has not worsened. **`Unknown` triggers nothing** — it is not a category any
user has been shown, and the half that matters is that losing the thresholds
must not read as "back to Normal" and fire a false all-clear while the river is
still high.

**Per-stream frequency, not global.** Options: hourly, 6-hourly, daily,
only-on-change, off. Stored on the user document as a reach → preference map,
beside `favoriteSources`. It must NOT live on `river_data`, which is readable
by every signed-in user and has to stay free of anything user-specific.

The reasoning for a 6-hourly default rather than hourly: hourly notifications
about an unchanged category say the same thing with a different number, and the
number is the part a reader cannot use. That is how a safety app teaches people
to ignore it — and the Peru reach above is that mechanism already running.
Per-stream control exists so a river that misbehaves can be quietened without
quietening the ones that matter.

### Decision 20 — what an alert says (2026-08-29)

Alerts carried a raw recurrence interval and a raw streamflow number:
`Forecast: 147362 CFS (Exceeds 25-year flood threshold)`. Neither appears
anywhere in the app, which calls that same water "Extreme".

    White River — Major Event
    Peaking in ~14 hours at 12,400 CFS.

    White River — still Major Event
    Now peaking in ~6 hours at 13,100 CFS.

- **The category comes first**, and is the app's own, through a shared ladder
  (`functions/src/flow-classification.ts`) pinned to
  `flow_classification.dart` by a drift test. Guard 3.
- **The river is named once.** There is room for about two lines.
- **The body leads with WHEN.** "In ~14 hours" decides whether you move the
  truck tonight; a streamflow figure decides nothing. The time was always in
  the payload and was being discarded.
- **Timing is RELATIVE, never absolute.** No user timezone is stored anywhere,
  so "Saturday 4 PM" would be silently wrong for every user outside Mountain
  Time. A peak already past yields no timing rather than "in ~-3 hours".
- **The recurrence interval is not shown.** Still on the payload for the app;
  it competed for space with how bad and how soon.
- `SCALE_FACTOR` is deleted — a demo lever whose non-1 value would have
  desynchronised the alert from the screen, which is what guard 3 forbids.

**Known gap, deliberately deferred:** the title uses NOAA's official river
name, because a user's custom name for a favourite lives only in device
`SharedPreferences` and is never written to Firestore. Jerson wants custom
names synced so alerts can use them; scheduled AFTER this phase.

### How alerting actually works, end to end

Written out in full because it is the part of RIVR hardest to reconstruct from
the code, and the part most worth explaining to someone who has not seen it.

1. **A model publishes.** NOAA's National Water Model issues a new run; GEOGLOWS
   issues one per UTC day. Neither tells us — an hourly probe watches for the
   `referenceTime` to change (decision 6).
2. **The store refreshes.** `storeRefreshHourly` (:20 past) compares what
   upstream reports against what is stored and fetches ONLY the products whose
   run advanced. If nothing advanced it does nothing at all, which is most
   hours. GEOGLOWS has its own daily pass at 11:30 UTC (decision 8).
3. **Alerts evaluate immediately afterwards**, in the same invocation, against
   the documents just written. There is no separate schedule and no clock: if
   the store wrote nothing, no evaluation happens and nobody is notified. This
   is what takes time-from-publication-to-alert from up to six hours down to
   under one.
4. **Every favourited reach is classified** on the same 2/5/10/25-year ladder
   the app uses — Normal, Action, Moderate, Major, Extreme — through code
   pinned to the client's by a drift test (decision 13, guard 3). The alert and
   the card cannot disagree about what to call the same water.
5. **The trigger model decides whether that is news** (decision 19). The
   category is compared against the last one this user was actually told about,
   read back from `notification_logs`. Entry and escalation always send;
   a continuing event reminds at the user's per-stream interval; a return to
   Normal sends an all-clear.
6. **The notification says how bad and how soon** (decision 20), because those
   are the only two things a reader can act on.

The cost story: alerts perform **zero** upstream fetches. Everything above is
Firestore reads against documents the app is already using, so a user's alert
and the number on their screen are the same value by construction rather than
by coincidence.

**Build.** `checkRiverAlerts` reads from the store rather than fetching, and
evaluates when a new run lands rather than on a fixed clock. The four fixed
Mountain-Time slots (6am / noon / 6pm / midnight) and the global
`notificationFrequency` are replaced by run-driven evaluation plus decision 19's
per-stream triggers.

**Guards.**
1. Alerts issue **zero** upstream fetches.
2. Persistence reminders honour the per-stream interval; **entry and escalation
   are never suppressed.** Verify the composite index is deployed, not merely
   declared — `checkRecentAlert` fails open, so a missing index silently
   disables dedupe. (Index verified READY in production 2026-08-29.)
3. **The category a user sees and the one the alert fired on come from the same
   code** (decision 13). Reading the same document is not sufficient — identical
   inputs through different implementations can still disagree.
4. No new run → no evaluation, no sends.
5. Time from publication to alert under one hour, versus up to six today.
6. **A sustained event does not re-notify beyond its per-stream interval**, and
   a category rise during one notifies immediately. Both proved against a real
   multi-day event, not a unit test alone — the Peru reach is a standing
   fixture.
7. Independent agent review passes.

**You are done when** an alert fires from data the app is already displaying,
within an hour of the run that triggered it, and a three-day event produces the
notifications a person would actually want rather than twelve identical ones.

---

## Phase 7 — The trust model

**Last, deliberately.** Removing the timestamp is a promise; it may only ship
once Phase 4's monitoring proves the guarantee, because afterwards **users cannot
tell a stale value from a current one — we have trained them not to look.**

**Build.** No timestamps beside values. One unobtrusive indicator only when the
app *knows* it is out of sync — offline, or the store has not advanced past an
expected cycle. Silence means current. The map legend keeps its date: a
once-daily product where the date is real information.

**Guards.**
1. No value view renders a timestamp.
2. Offline shows the indicator; healthy shows nothing.
3. A store deliberately frozen past its cycle raises the indicator without a
   user-visible error.
4. The indicator is driven by the same signal that alarms operationally.
5. Independent agent review passes.

**You are done when** a user has no reason to pull-to-refresh, and when the
number isn't current the app says so before they have to wonder.

---

## Phase 8 — Prove it on device

**Guards.**
1. Phase 0's timings retaken and compared **in the same table**.
2. Favourites render under 3 s cold; non-favourites show a titled sheet under
   500 ms and fill progressively.
3. Two accounts, two devices, one river, identical values.
4. Airplane mode: favourites still render.
5. A full publish cycle observed end to end — probe detects, store updates,
   devices converge, alert fires.
6. **Unit switching verified on device**: every surface repaints, no refetch,
   return periods still classify correctly.
7. Android checked — it shares this code path entirely.
8. Every number recorded with the build it came from.
9. Independent agent review passes.

**You are done when** tapping a Friday digest on a cold start renders rivers in
under 3 seconds, and you have the numbers rather than the impression.

---

## Phase 9 — Sweep: kill the legacy, fix the docs

Affordable because every working version is on `main`.

**Code.** Remove the Phase 5 kill switch and its Remote Config parameter once the
store has run clean through Phase 8. Delete everything with no callers — **the
list is derived at the time, not predicted here** (an earlier draft named
`reach_data_provider` and was wrong). Rename `analysisAssimilation`, which
fetches short range. Fix `validUntil`'s CONUS-only assumption for Alaska and
Hawaii/Puerto Rico. Resolve the two ADR 0008 server defects: `arrayRemove`
receiving an array instead of varargs, so stale-token pruning is a silent no-op;
and `setupNotificationListeners()` gated on `enableNotifications` alone, so a
weekly-only user never gets tap routing.

**Docs.** Rewrite CLAUDE.md's architecture and data-flow sections. Settle ADR
0001 Step 7, ADR 0002 Stage 2b, ADR 0003's back-off flaw, and confirm ADR 0010's
disposition. Entries in `app_releases.md` / `notifications_history.md` per phase.

**Guards.**
1. `grep -rn "loadCompleteReachData" lib/` returns nothing.
2. No Remote Config fallback parameter remains, and no code reads one.
3. `flutter analyze` reports zero unused-element warnings across touched files.
4. Every ADR listed is updated or explicitly confirmed accurate, with a date.
5. **CLAUDE.md read as if new would build the current architecture.** Every
   stale-doc incident here began with a doc that was true when written.
6. Full suite green with no skipped tests carried forward.
7. Independent agent review passes.

**You are done when** nothing in the tree describes or implements the old data
path, and someone joining would not find a second way to fetch a river.

---

## Sequencing

```
Phase 0 (running) ──┬── Phase 1 ── Phase 2 ── Phase 3 ──┐
                    └── Phase 4 ───────────────────────┴── Phase 5 ── Phase 6 ── Phase 7 ── Phase 8 ── Phase 9
```

Phase 4 is server-only and runs in parallel with the app phases. Phase 5 needs
both 3 and 4. Phase 7 needs Phase 4's monitoring proven in production. Phase 9
follows Phase 8, because the kill switch survives until the store does.

**Phases 1, 2, 3, 4 and 6 each improve the product on their own** and are
independently shippable.

**Why 3 before 5.** The original order built the cloud store first. With
consistency as the goal rather than speed, one path *inside* the app is both the
larger correctness win and a prerequisite.

---

## Honest limits

- **"Fast in every state" holds for favourites, not for non-favourites.** If
  upstream is down and someone taps an unfavourited stream, there is nothing
  stored and nothing to show. The design cannot deliver that and should not claim
  it.
- **The backend becomes a dependency for viewing data**, not just for
  notifications. Hence the kill switch and the degrade-to-live-path rule.
- **Phase 1 opened a divergence that Phase 3 closed.** The map sheet and the
  forecast page read the narrow products from Phase 1; `favorites_provider`
  kept reading `reachSummary` — same derivation, *different cache entries
  fetched at different moments*, so the favourites card could legitimately
  disagree with the sheet, and it paid the 156 KB medium-range fetch on every
  refresh. Phase 3 put the card on the same narrow products and deleted the
  bundle.

  *(An earlier draft cited `docs/internal/forecast-data-consistency-audit.md`
  as where this is recorded. `docs/internal/` is gitignored, so that file is not
  in the repository and the citation pointed at nothing — recorded here
  instead.)*
- **Geocoding is now behind `IGeocodingService`.** `GeocodingService`'s statics
  made it impossible to pin either direction — that a geocode does *not* happen
  on the fast path, or that it *does* happen at the consumer — and made widget
  tests issue live Mapbox calls. Both are now counted against a fake. The
  `ForecastService` takes it too, which removed the last **Mapbox** call from
  the suite — proven by instrumenting the real HTTP call and running the whole
  suite with zero hits. One live call remains and is **not** Phase 1's:
  `ConnectivityService._canReachInternet` reaches
  `clients3.google.com/generate_204` via the integration harness. Pre-existing;
  named here rather than left inside a sweeping "no network" claim. The statics remain only for surfaces not yet on
  the DI graph — `favorite_river_card` and `map_search_service` — which Phase 3
  and Phase 9 own. `weekly_outlook_service` took the interface in Phase 1 and no
  longer calls them.
- **A silently-failing store is the most dangerous outcome in this document**,
  because Phase 7 removes the timestamp that would let anyone notice. Monitoring
  ships with Phase 4 or the store does not ship.

## Open and unverified

- **Probe interval.** Hourly is the working default; Phase 0 confirms or corrects.
- **Atomic publication.** 8/8 reaches agreed in one sample. Phase 4 guard 3 is
  designed so the answer does not matter.
- **Weight vs bad window.** Not yet separated; the five-endpoint probe will.
- **Access distribution.** Whether non-favourite browsing shows enough overlap to
  justify caching is unmeasured; decision 2 says no at current scale.
- **Trimmed payload size.** The reduction from storing only `mean` is an estimate
  from the 156 KB measurement, not a measured result.

## What this does to the Weekly Outlook

ADR 0010's 3–5 minute stall is closed by **Phases 3 and 5**, not by anything
specific to that page. Its NWM rows used to call `loadCompleteReachData` —
always network, all four products, for a page rendering one series; Phase 3
rewired them onto repository reads of `mediumRange` alone (and deleted the
method). Once favourites read through the store, the page draws from documents
it already holds.
