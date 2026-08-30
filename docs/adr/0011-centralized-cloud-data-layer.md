# 0011 — One source of truth for favourite rivers

**Status:** Phases 0–7 complete. Phase 0 still collecting (it is the instrument, not a step). Phases 1–3 merged 2026-08-23; Phase 4 live 2026-08-25; Phases 5–7 completed and deployed 2026-08-29/30, Phase 7 verified on device. **Phase 8 (prove it on device) is in progress; Phase 9 (sweep) not started.**
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
| ~~6-hour alert cooldown~~ | **There was never one.** `checkRecentAlert` existed and read like a cooldown, but its answer only changed the wording to "still" — nothing skipped a send. Corrected 2026-08-29; see decision 19. |
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
   **Always sent, and NOT suppressible by any PER-RIVER setting — including
   `off`.** The only true override of a per-river preference.

   Precisely: the account-wide "River Flood Alerts" switch still applies, since
   `getNotificationUsers` filters on `enableNotifications`. A user who turns
   notifications off entirely receives nothing, escalations included — and the
   stale-token cleanup flips that switch automatically when every one of a
   user's tokens has died. Stated exactly because the earlier wording said "any
   user setting", which an independent audit correctly called false. Safety beats
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

**Closed 2026-08-29.** The title used NOAA's official river name, because a
user's custom name lived only in device `SharedPreferences`. Renaming a
favourite now writes `favoriteLabels` on the user document and the alert reads
it, so a notification calls a river what its owner calls it. The key is
`<source>:<reachId>`, not the bare reach id: NWM COMIDs and GEOGLOWS LINKNOs
are both plain integers drawn from uncoordinated id spaces, so a shared slot
would eventually let one river's name overwrite another's.

### Decision 21 — health is per-product, not per-collection (2026-08-29)

Phase 7 removes the timestamps that let a user notice stale data, and this
document already says the quiet part: *a silently-failing store is the most
dangerous outcome in this document*. So Phase 7 cannot ship on monitoring that
cannot see a silent failure — and the monitoring shipped in Phase 4 could not.

`lastSuccessfulWrite` takes the newest write across the WHOLE `river_data`
collection. One fresh write reports the entire store healthy, so a product that
stops being written is invisible for as long as any other product keeps
writing.

**A correction, because the first version of this decision claimed more than is
true.** It said this check would have caught the 2026-08-29 GEOGLOWS incident.
It would not have, and the review caught the overclaim. In that incident the
01:30 job ran *punctually every day*: it fetched, received a `forecast_date`
one day newer than the stored one, and wrote. `fetchedAt` was therefore never
more than ~24 hours old against a 48-hour cap, and a per-product **write
recency** check reports that as healthy — exactly as the old one did. The store
was serving yesterday's water while writing on time.

So there are two distinct failures, and this decision addresses one of them:

| Failure | Detected by |
|---|---|
| The refresher stops writing | **write recency** — `assessProductFreshness` |
| The refresher writes stale content on time | **run currency** — `assessRunCurrency` |

**Run currency, added the same day once the review exposed the gap.** It
measures the age of the RUN rather than the age of the write. Every `runId` is
an ISO instant — NWM uses the run's `referenceTime`, and GEOGLOWS's date-only
`forecast_date` is widened to that day's 00Z by `normaliseForecastDate` — so
the two sources are directly comparable and no probe comparison is needed.

The caps come from measurements already in this repo:

| Product | Cap | Why |
|---|---|---|
| `analysisAssimilation`, `shortRange` | 16 h | **Measured.** 8 h was the first answer and it was wrong: it counted the documented five-hour NOAA stall but not the ~3 h baseline publish lag that precedes it. Replaying 163 hourly `publish_cadence_log` samples, 8 h would have fired on **29 of them (17.8%)**; the worst run age observed is 11.0 h |
| `mediumRange` | 24 h | **Measured.** 0 of 153 samples would have fired; worst observed 13.0 h. Nominally 6-hourly, but the 12Z run was observed landing at 21:20Z |
| `longRange` | 36 h | **Measured.** 0 of 155 samples; worst observed 21.0 h |
| `geoglowsForecast` | 42 h | **Measured.** What matters is when WE fetch, not when GEOGLOWS publishes: `storeGeoglowsDaily` runs at 11:30 UTC with no retry, so a stored run legitimately reaches 35.5 h. Confirmed in production — the run check at 2026-08-29T11:30:34Z logged `held: 2026-08-28T00:00:00Z` against `upstream: 2026-08-29T00:00:00Z`, replacing it seconds later. A 36 h cap left ~25 minutes |

Products with no entry are **skipped, never defaulted** — the near-static
products carry no run identity at all, and inheriting another product's cadence
is exactly how the hold cap called a healthy store down within a minute of
reaching production.

**The client applies these same caps**, added when guard 4 was closed properly.
One deliberate difference in how the two AGGREGATE: the server judges the
newest run across a product's documents, because one lagging reach is a
per-reach fetch failure it already records and retries; the client judges the
single entry in front of the user. So a device favouriting a reach whose run
lags the rest will show the strip while the store reports healthy. That is the
device being more honest about the water on ITS screen, and honesty is the
right direction here — but it is a divergence, and it is written down rather
than discovered later.
Until then the phone had no notion of run age: during the 2026-08-29 incident
the server would have alarmed while the device showed nothing at all, because
every check it had asked "how long ago did we write?" and the answer was
"minutes". `runTooOld` in `hold_policy.dart` asks the other question, against
these numbers, pinned by the same drift test.

Both dimensions are logged side by side, because the pair is what makes a
healthy verdict checkable: punctual writes carrying yesterday's water look
perfect in one list and wrong in the other.

`assessProductFreshness` now judges the newest document PER PRODUCT against
that product's own cap.

- **The threshold is `MAX_HOLD_MS`, reused rather than redefined.** It already
  answers precisely the right question — how long upstream can plausibly be
  quiet before silence stops meaning "nothing changed" and starts meaning
  "something is broken" — and it is per product because the products differ by
  an order of magnitude (short range 6 h, long range 36 h, GEOGLOWS 48 h). A
  second constant here would drift from the window logic it has to agree with.
  The client shares this constant (decision 22), and shares `MAX_RUN_AGE_MS`
  below as well, so guard 4 holds for both of the server's dimensions.
- **A product with no documents is skipped, not reported down.** Nobody has
  favourited a river that needs it, so there is nothing to be stale.
- **The NEWEST document per product is judged.** One old document among fresh
  ones is a per-reach fetch failure, which the run already records and retries
  next cycle. Reporting that as a stalled product would make the alarm cry wolf
  until nobody read it.

**It false-alarmed in production within a minute of going live, and that is
worth recording.** `reachMetadata` and `returnPeriods` had no `MAX_HOLD_MS`
entry, so they inherited the 6-hour default meant for hourly forecasts — while
in fact they hold a 30-day window and are rewritten only when missing or nearly
expired. `storeHealth` returned 503 with *"returnPeriods has not advanced for
17h (cap 6h)"* on a completely healthy store. Both now have 32-day caps
(30-day window plus room for the daily pass), pinned at both ends by tests so
the fix cannot drift into "never alarm". A false alarm matters more here than
almost anywhere else in this document: Phase 7 hands this signal to users, and
a warning that cries wolf is ignored before the day it is right.

Costs no new index — `sampleStoredWindows` already projects `product` and
`window` through a single-field query — but it is **not free**: it now reads
every stored document on every health check (~135-180 reads), against 2 before.
At the 2-hourly heartbeat that is roughly 1,600-2,100 reads/day, about 3-4% of
the 50,000/day free tier. That is safe at current scale and becomes the store's
largest single reader; `storeHealth` is also a public unauthenticated endpoint,
so each anonymous request now costs the same. Worth revisiting at roughly 700
favourited reaches.

### Decision 22 — one indicator, and what it refuses to say (2026-08-29)

With the timestamps gone, silence is a claim. The app makes one statement about
freshness, and only when it cannot vouch for what is on screen.

**Coverage is deliberate, and narrower than the first version of this decision
implied.** Full banner on the favourites page; **offline only** on the reach
forecast page; the map has its own `MapOfflineNotice`; the weekly outlook page
has nothing.

The reasoning, which is Jerson's: the store exists so that a device with
internet shows the newest value that exists anywhere, so in practice the reason
a user sees an old number is that they are offline — and the offline half is
the half worth repeating. The forecast page earned it because that is where a
flood notification lands, and it previously had **no connectivity indicator of
any kind**: tapping an alert with no signal showed flow numbers with nothing
anywhere saying the phone was offline, and Phase 7 had just removed the "3h
ago" label that was the last hint.

The STALE half is deliberately not repeated there. `outOfSync` is a property of
the whole repository, not of the river on screen, so on a single-river page it
could warn about a different river entirely. It stays on the favourites page,
where every affected river is visible at once.

The premise had one known exception, and it is the one that actually happened:
during the GEOGLOWS incident devices were online and still showed yesterday's
water, and at the time neither the banner nor `outOfSync` would have caught it
— the app considered that data in-window. **That is no longer true.** Closing
guard 4 gave the client the server's run-age caps, so `outOfSync` now rises on
exactly that shape: a value written minutes ago carrying a run a day old. What
was answered by more monitoring is now also answered on the device.

`SyncStatusBanner` **subsumes `OfflineBanner`** rather than sitting above it.
Offline is one of the two reasons the app cannot vouch for a number, not a
separate subject; two strips would be two competing answers to one question.

| Situation | Banner |
|---|---|
| In window AND recently fetched, online | nothing |
| Offline | "No internet connection" |
| Serving data past its window, refresh failed | "These numbers may not be current" |
| Online, a fetch failed, data still in window | nothing |
| Held past its product's cap, even though in window | "may not be current" |
| Carrying a run older than its product's cap, however recently written | "may not be current" |

The last row is the one worth defending. A failure that left in-window data on
screen has cost the user nothing, and a warning there is the noise that teaches
people to dismiss the strip before the day it matters.

**Guard 3 was NOT met by the first two attempts** — this paragraph is the
history, not the status. The scoreboard below carries the current verdict.
The first version of this decision claimed it was met under a redefinition. That claim does not survive reading the code, and
the review said so.

The argument made was: when a stored document expires the client falls through
to the live path and gets current data, so no warning is warranted. That
describes only what happens *after* a product's hold cap. Before it —
`extendWindowCoverage` re-stamps every document's `validUntil` forward every
hour for up to `MAX_HOLD_MS`, which is 6 hours for short range and **48 hours
for GEOGLOWS**. Throughout that window `StoreBackedDataSource` serves the held
document as in-window, the client never reaches the live path, and `outOfSync`
never rises. A store frozen past its cycle therefore produces, for up to two
days, exactly what this phase exists to prevent: held data, no indicator, no
fallback. That is the guard-3 scenario, and it is unguarded.

Nor was the redefinition tested. No test in the tree freezes a store; the
substitute drives a total fetch failure, which is the different case where the
store *and* the live path both fail.

Extending a window is the store saying "upstream has not moved, so this value
is still the newest that exists". That is true and useful, and the extension
mechanism is not the bug. What was missing is that a document held on
re-verification alone is a *weaker* claim than a freshly fetched one, and
nothing carried that distinction to the device.

**Closed the same day, and it needed no schema change** — the first attempt at
this paragraph said it did. The envelope already carries what is required:
`fetchedAt` is deliberately never moved by an extension (moving it would let a
document be held forever, one extension at a time), so it is the honest record
of when this water was last pulled from upstream. `validUntil` answers "may I
serve this?"; `fetchedAt` answers "how long has nobody actually checked?".

The client now applies the SAME per-product cap the server does
(`hold_policy.dart` mirroring `MAX_HOLD_MS`) to `fetchedAt`. Past it the server
stops extending and lets the document expire; the client stops vouching for it
at the same instant.

**"The same instant" was not true when first written, and the third review
caught it.** `planWindowExtensions` stamped the full refresh floor, so the last
extension before abandonment promised one whole refresh interval BEYOND the
cap — and the client, stopping exactly at the cap, spent that gap warning about
the newest data in existence, then cleared it by re-fetching identical bytes
through the live path. About 70 minutes for short range; about a day for
GEOGLOWS, whose refresh interval is a day. Extensions are now clamped to
`fetchedAt + maxHold`, which is what makes the sentence above true. Deliberately it does NOT force a refetch: the window is
still valid, so this is a statement about confidence, not a reason to spend a
network call.

That shared constant is also what finally makes **guard 4** true rather than
asserted, and it is pinned: `hold-policy-drift.test.ts` reads the Dart file off
disk and fails if the two sides ever disagree, in either direction — the same
mechanism that keeps the flood-category ladder honest across the two
languages. A client holding LONGER than the server would keep showing water the
server had already given up on, silently, which is this scenario again.

**Found by the fourth review and FIXED 2026-08-30 rather than deferred: the
GEOGLOWS LIVE path warned truthfully for about six hours a day.** Device testing on
2026-08-30 narrowed who this reaches: with the store read switch ON, favourites
are served entirely from the store (zero upstream calls observed), so the live
path — and this warning — is reached only by non-favourite rivers browsed on
the map, or by everyone if the Phase 5 kill switch is ever flipped OFF. That
last case is why it was fixed now rather than left for Phase 9: flipping the
switch is something done DURING an incident, and it would have added a
six-hour daily warning to whatever else was going wrong.

**The fix is that the window now follows PUBLICATION, and the run actually
received.** `GeoglowsDataSource` expired its values at the next UTC midnight,
conflating the run's 00Z stamp with when GEOGLOWS actually publishes —
10:15-10:30 UTC, a measurement `functions_geoglows/main.py` has recorded all
along and which is why the flood builder runs at 11:00. A device fetching at
00:20 therefore held the previous day's run for another 24 hours while a newer
one had existed since 10:15.

`windowFor` now expires at the next publication plus slack, and takes the run
identity into account: holding today's run waits for tomorrow's publication;
holding yesterday's before the expected time waits for today's; holding
yesterday's AFTER it means publication is late, so it looks again in 30
minutes rather than sitting on old water for a day. A test sweeps all 24 hours
and asserts a held run can never reach the 42 h cap that makes the app warn. `GeoglowsDataSource`
sets `validUntil` to next UTC midnight + 15 min, but GEOGLOWS actually
publishes at 10:15-10:30 UTC. So a device on the live path holds the previous
day's 00Z run in-window until midnight, reaching ~48 h of run age against a
42 h cap, and the strip appears from about 18:00 UTC. **The warning is
correct** — a day-newer run has existed since 10:15 — so this is the new guard
exposing a window mis-calibration that predates it, not a false alarm. The
STORE path is unaffected: its documents expire at 11:40, giving 35.7 h of run
age with 6.3 h of margin, measured on the four live documents. Fixing it means
changing when every device revalidates GEOGLOWS, which is a live-path change
and belongs with Phase 9's sweep, not smuggled into the phase that removed the
timestamps.

**What was kept, and why it is not a timestamp.** The forecast chart's time
axis stays: when the peak arrives is the subject the user came for, not a claim
about our data's age. The map legend's date stays for the reason this document
already gives — a once-daily product where the date is real information.

### Phase 7 — where it actually stands (2026-08-29)

Written down because the first pass at this phase reported itself complete and
three of the five guards were not met. An independent review found it; the
overclaims are corrected in decisions 21 and 22 above rather than deleted.

| Guard | Status |
|---|---|
| 1 — no value view renders a timestamp | **met**, tested and mutation-checked |
| 2 — offline shows the indicator, healthy shows nothing | **met for the offline half** — favourites (full), reach forecast (offline only), map (its own notice); weekly outlook has none. The staleness half stays on favourites by decision, not omission |
| 3 — a frozen store raises the indicator | **met**, on the second attempt. The first passed its own test while failing in production: the repository stamped its own read clock over the server's `fetchedAt`, so the hold clock reset on every device read and the guard could never fire on store-served data. The test proving it wrote the crafted entry straight into the fake cache — asserting the premise instead of proving it. Now tested through a store-shaped source |
| 4 — the indicator is driven by the same signal that alarms operationally | **met, on the third attempt.** Both of the server's dimensions are now shared: `MAX_HOLD_MS` (how long ago we wrote) and `MAX_RUN_AGE_MS` (how old the water is), each mirrored in `hold_policy.dart` and pinned by a drift test that fails in both directions. The first attempt claimed a shared constant that existed only in TypeScript; the second shared the weaker dimension and left the phone silent through the very incident that motivated the phase |
| 5 — independent agent review passes | **four ran; the fourth found no code defects.** Rounds 1-3 each found real blockers and each was fixed. Round 4 (2026-08-30) replayed 187 probe samples and 125 production documents against the client's new run-age check and recorded **0 false trips**, verified the run-identity formats against the live NOAA API, and reproduced all three mutation claims. Its single blocker was a stale sentence in this document, corrected. Treat the guard as met on code and thin on process: no review has passed on its first reading |

What was genuinely delivered: the timestamps are gone from the values, the
indicator exists and is correct for the cases it covers, per-product write
recency now catches a stalled writer that the old heartbeat could not, and
three live defects in the indicator's own signal were found and fixed (a flag
that could stick on after data was restored, one that stayed silent on a failed
cold-start fetch, and a global latch that let one river's success speak for
another's failure).

**A second review ran on 2026-08-29 and also did not pass.** It found the
guard-3 fix passing its own test while failing in production, two run-age caps
that would have false-alarmed (one on 17.8% of eight days of real probe
samples), a status ladder that served one ordinary NOAA pause as a 503 outage,
and a drift test that could be defeated by an ordinary trailing comment. All
were fixed; the corrections are in decisions 21 and 22 above rather than
deleted.

What remains: guard 5. A fourth review ran on 2026-08-30 against the state
above and found **no code defects** — it replayed 187 probe samples and 125
production documents and recorded 0 false trips — but blocked on a stale
sentence right here, which still said guard 4 was half-met after the row above
had been corrected. That sentence is this one, rewritten. The third time this
document went stale on guard 4's status specifically.

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
Firestore reads against documents the app is already using, so an alert and the
app are computed **from the same documents, through the same ladder** rather
than from two independently fetched copies.

Not the same NUMBER, and the distinction matters: an alert reports the forecast
PEAK, while the favourites card and the gauge show CURRENT flow. They agree
about the flood category because they share the ladder; they legitimately show
different figures, which is why the app already carries a strip explaining that
the map colours by forecast peak.

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

**Guard status, 2026-08-29 (deployed to production).**

| Guard | State | Evidence |
|---|---|---|
| 1 — zero upstream fetches | **MET** | Alerts and the weekly digest both read the store; `batchFetchReachData` is deleted, so no live-fetch path remains in the alert code at all. |
| 2 — per-stream interval, entry/escalation never suppressed | **MET** | Pure `decideTrigger`, mutation-checked in both directions. The app writes the setting from three places (see below). **Escalation was BROKEN until 2026-08-30** — see the review findings below; it is fixed and pinned by a regression test that drives the state machine as the caller does. |
| 3 — one category, one implementation | **MET** | The threshold comparison is single-source per language, pinned by a test that reads `flow_classification.dart` off disk and fails on drift in the names, the intervals, the boundary direction or the completeness check. An audit on 2026-08-30 found the collapse was incomplete — `weekly-digest.ts` still declared its own copy of the category NAMES, which the drift test could not see because it only asserted `indexFor(` was called. Fixed, and a second test now fails if any module outside `flow-classification.ts` declares that list again. |
| 4 — no new run, no evaluation | **MET in code, not yet observed** | Evaluation is gated on the store run's own outcome, so an idle upstream cannot reach it. The "nothing advanced" path has not yet been seen in a production log. |
| 5 — publication to alert under an hour | **MET structurally; the timing is UNMEASURED** | Evaluation runs inside the same invocation that writes the documents, on the :20 hourly cycle, so the bound follows from the schedule. The 2026-08-29 observation (long range advanced 18:46, alerts evaluated 18:49) was a MANUAL trigger, not the hourly cycle, and `longRange` is not in `ALERT_PRODUCTS` — so it demonstrates the plumbing fires, not the publication-to-alert latency for the products alerts actually read. Measuring that properly needs a short/medium run advance observed on the natural cycle. |
| 6 — a sustained event does not re-notify beyond its interval | **PARTIAL** | Unit-proven, including a 24-hour simulation that yields one entry and three reminders instead of twenty-four notifications. Not yet observed across a real multi-day event; reach 620569308 is the standing fixture. |
| 7 — independent agent review | **PASSED, after fixes** | Two reviews, 2026-08-30: one for live defects, one for untrue documentation. Both found real problems and both are addressed. |

**What the review found, because it is the most useful part of this phase to
record.**

Two live defects, neither of which any existing test could see:

- **A muted river could never escalate** — the guarantee the whole design rests
  on. `previous` came from `notification_logs`, which is written only when
  something is SENT, so a muted river wrote nothing, so every evaluation read
  as the start of an event and returned silence. It could climb Action →
  Extreme unheard while three lines of UI copy promised otherwise. The
  escalation tests passed because they hand `previous` in directly; production
  could never produce that state. Fixed by separating what we SAW from what we
  SAID, in a new `alert_state` collection written on every evaluation.
- **A river flapping on its threshold could send 24 notifications a day.**
  Entry and all-clear consulted no interval at all. Fixed with a two-hour dwell
  on both; escalation is decided before it, so a real worsening is never
  delayed.

And a claim that had never been true: **"a rename on either side fails the
build"**. CI ran only the Flutter suite, so every cross-language drift guard in
this document — the skews, the ladder, the stored field names, the frequency
wire values — was a check nothing automated ran. `npm --prefix functions test`
is now in CI. Related: the collapse in guard 3 was incomplete, and the default
rule was pinned in one direction only.

**Verified in production 2026-08-30 after deploy:** twelve `alert_state`
documents, eleven of them written with `notified: none` — the observation
recorded while deliberately saying nothing, which is precisely what was
impossible before. A separate run logged "no new data; alerts not evaluated",
which is guard 4 observed rather than merely reasoned.

**Still unverified:** a real river actually climbing a category end to end.
The mechanism is proven; the event needs a genuine flood. Reach 620569308 is
the standing fixture.

**The app-side settings shipped** on 2026-08-30, five commits after this table
was first written. Three entry points write `alertFrequencies`: the per-river
list in Notification settings, a bulk "Set all rivers" once a user has five or
more favourites, and an "Alerts" row on each river's own forecast page — that
last one because a flood alert deep-links there, so the fix is reachable from
where the annoyance happens. All three open one shared picker.

**Rollout effect, expected and observed:** notification logs written before
this carry no category, so the first evaluation reads as an entry for every
reach currently elevated. Seen once on 2026-08-29 — reach 620569308 logged
`category: Action, trigger: entry` — and correct from then on. That same reach
had been sending four identical notifications a day for at least three days.

**You are done when** an alert fires from data the app is already displaying,
within an hour of the run that triggered it, and a three-day event produces the
notifications a person would actually want rather than twelve identical ones.

---

## Phase 7 — The trust model

**Status: complete 2026-08-30** (decisions 21 and 22), after four independent
reviews **and verified on a physical iPhone**.

Device verification, 2026-08-30, iPhone 26.6, debug build off `development`:

| Check | Result |
|---|---|
| Favourites render no timestamp, no freshness tick | **clean** — nothing on any card |
| Airplane mode raises the strip on favourites | **shows** |
| Airplane mode raises it on the reach forecast page | **shows** — the screen that had no connectivity indicator of any kind before this phase |
| Reconnecting clears it, with no "back online" toast | **gone** |
| Live upstream calls during the session | **ZERO** — every favourite served from the store, Phase 5 guard 1 holding on real hardware |

That last row was not one of Phase 7's guards and is the most reassuring line
in the table: the device log shows no NOAA or GEOGLOWS fetch at all, so the
store covered every favourite while the indicator stayed correctly silent.

This mattered more than a fifth review would have. Five live defects were found
on a device earlier in this project while 1182 tests were green, one of them a
guard already signed off. The first pass reported itself complete with three guards unmet; each
round found real blockers and each was fixed, and the fourth found no code
defects. See "Phase 7 — where it actually stands" below the decisions, which
records what each round caught rather than only the outcome.

**Last, deliberately.** Removing the timestamp is a promise; it may only ship
once Phase 4's monitoring proves the guarantee, because afterwards **users cannot
tell a stale value from a current one — we have trained them not to look.**

That precondition was checked rather than assumed, and it did not hold: the
Phase 4 heartbeat measured the whole collection at once, so a product that
stopped being written was invisible behind any other product's writes. Making
health per-product (decision 21) was therefore part of this phase's work, not a
prerequisite met elsewhere.

Two corrections to how that used to be worded here. It said the heartbeat "had
been reporting a healthy store through 24-hour GEOGLOWS stalls" — but there
were no stalls: decision 21 establishes the job wrote punctually every day
carrying yesterday's run, which is a different failure and the reason write
recency alone does not catch it. And "was reporting healthy" is deduced from
reading the old code, not an observed response; no `storeHealth` output from
that period is recorded anywhere.

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

## Phase 8 — Prove it on device ▶ IN PROGRESS

### Guard 7 — Android (2026-08-30)

**It shares the path, and it is the tightest number in this phase.** Android 15
emulator (Pixel, API 35, arm64), profile build at `62ef301`, same account, same
six favourites as the iPhone.

| run | to first favourites paint |
|---|---|
| 1 | 2603 ms |
| 2 | 2473 ms |
| 3 | 2285 ms |

**2473 ms median against the 3 s bar** — inside it, but with 0.5 s of headroom
where the iPhone had 2 s. That is the first figure in this phase that is close
to a limit rather than comfortably past it, and it is worth watching rather
than celebrating. Two caveats cut opposite ways: an emulator is generally
slower than real hardware, so a physical Android device may do better; and this
emulator runs on an M-series Mac, which flatters it compared with a budget
phone.

**Getting here cost two production-config changes and one incident**, recorded
because the diagnosis was wrong twice before it was right:

1. The emulator was refused with `FirebaseInstallationsException: 403`. First
   hypothesis — no SHA fingerprints registered — **disproven**: two were.
2. Second hypothesis — the Firebase app's fingerprint list is the blocker —
   **also disproven**: adding the debug SHA there changed nothing.
3. The real cause, read out of `gcloud services api-keys describe`: the Android
   **API key** carries its own separate allow-list of package + SHA-1 pairs.
   The debug fingerprint has to be in BOTH places. This blocks any developer's
   local Android build, not just this emulator.

**The incident:** `gcloud services api-keys update` REPLACES the restriction
lists rather than appending, and a bash `while read` loop silently drops a
file's last line when it has no trailing newline. The first update therefore
removed the **release** fingerprint and one API target for about thirty
seconds. Restored from a `describe --format=json` backup taken beforehand, and
verified by comparing composition — the broken state had the same COUNT of
fingerprints as the good one, so counting would have missed it.

**The first Android trace read 74288 ms and is not a measurement.** The
stopwatch starts at app launch and that run included a human typing credentials
into the emulator. It is recorded here only so nobody finds it in a log and
quotes it.

### Guard 8 — every number recorded with its build (2026-08-30)

| guard | figure | build |
|---|---|---|
| 1 | endpoint latency and success | server-side probe data, no app build involved (189 samples, 2026-08-22 → 08-30) |
| 2 | 969 / 1008 / 961 ms | profile, tree that became `4217077` |
| 4 | favourites render offline | profile, same build as guard 2 |
| 6 | 0 refetches, 480 log lines | debug at `7cf587c` — app code identical to `4217077` |
| 7 | 2603 / 2473 / 2285 ms, Android | profile at `62ef301` — app code identical to `4217077` |
| 3 | 13966 CFS on both devices | iPhone debug `7cf587c`, Android profile `62ef301` |
| 5 | 3 notifications, `alertsSent: 3` | TestFlight build of `2026.2.0+719` |

**This guard caught its own violation twice, which is the argument for having
it.** The first was immediate; the second was found by the Phase 8 re-review —
guard 5's figures had no row at all, in the guard whose entire point is that
every number carries its build.

 Guards 2 and 4 were first written down as "profile build off
`fc2bb4f`". They were not: `fc2bb4f` created the instrument with only a
`dart:developer` call, the `debugPrint` that made the measurement readable was
added afterwards, and the runs happened on that working tree — which became
`4217077`. Attributing a number to a build that could not have produced it is
a small error and exactly the kind that makes a table stop being evidence.

### Guard 6 — unit switching on device (2026-08-30)

**Every surface repainted; ZERO refetches.** CMS → CFS switched in Settings on
the iPhone — **debug build at `7cf587c`**, whose app code is identical to
`4217077` (the two commits between them touch only this document) — then back
to favourites. 480 log lines captured across the switch
and **not one** upstream call, `_doFetch`, background revalidation or any
`RIVER_DATA_REPO` activity at all. All six favourite cards logged new values.

Round trip, White River: 13744 CFS → **389 CMS** → 13744.1 CFS. 13744 ÷ 35.3147
= 389.2, so the conversion is right in both directions and does not drift.
Categories held — every card stayed on the same rung, which is the point: the
units changed, the water did not.

**This took two attempts, and the first one is worth recording.** The visible
half was checked on a profile build — no spinner, no flicker, values changed
smoothly — but the log tap captured nothing, because `AppLogger` is wrapped in
`kDebugMode` and a profile build emits no debug logs at all. The build chosen
for honest TIMINGS was the one that could not answer "did it refetch?", and the
conflict was invisible until the tap came back empty. Repeated on a debug build
to get the evidence, because a spinner is something a person notices and a fast
background fetch is not — and that is exactly the class of defect that got
through repeatedly this week.

### Guard 5 — a full publish cycle, observed (2026-08-30) ▶ MET

**Completed at 04:20 UTC on the TestFlight build of 2026.2.0+719.** Three
notifications arrived on the lock screen, `alertsSent: 3, errors: 0`:

    Diamond Creek — Extreme Event
    Peaking at 220 CFS.

    Stream 640469625 — Major Event
    Peaking in ~3 days at 29,294 CFS.

    Test river name — still Action Event
    Now peaking in ~41 hours at 982 CFS.

Every link, measured rather than inferred: the probe detected a new NWM run,
the store wrote it, alert evaluation ran in the same invocation over 12 reaches
and 3 users, all three were classified against their own return periods
(Extreme at the 100-year, Major at the 10-year, Action at the 2-year), and the
pushes reached a real device.

**The trigger model is visible in the copy.** Diamond Creek and 640469625 both
fired as `entry` — first time above the threshold. The third fired as
`persistence` and says "**still** Action Event" with "**Now** peaking in ~41
hours", because that user had already been told and the water had not gone
away. That distinction is decision 19 working in production.

**Diamond Creek's line carries no time, and that is correct.** Its peak is
behind it — current flow was above the forecast peak when it was favourited —
so `timeToPeak` had nothing to offer and the copy degrades to "Peaking at 220
CFS" rather than inventing a horizon.

**One thing to look at, not a defect: the notification says Extreme while the
card says MAJOR.** They answer different questions — the alert reports the
forecast PEAK (220 CFS, Extreme), the card reports what the river is doing NOW
(107 CFS, Major, having receded from 155). Both are right and a user may still
find the pair confusing. This is the same tension the reach detail sheet's peak
strip exists for, and it belongs with that redesign rather than here.

**The stale-token fix is verified by the same run.** The account carried 7 FCM
tokens before it deployed; the 04:20 cycle logged 9 stale-token prunes with no
cleanup errors, and the document now holds **4**. That is the deploy confirmed
by its effect rather than by its exit status — and it is why `deviceCount` read
4 rather than 7.

**Earlier that hour the same cycle failed to deliver**, which is what sent us
to TestFlight: three of the four registered devices are dead sandbox tokens
from local builds and still fail with `Invalid APNs credential`. The fourth is
the TestFlight build, and each alert succeeded after those three failed.



**Four of the five links verified in one cycle; the fifth is blocked by a
local-build gap, not a defect.** A NOAA river was deliberately favourited from
the map minutes beforehand — Diamond Creek (2875501, Cheyenne WY), showing
Extreme now with a Major peak — and the 03:20 UTC cycle was watched end to end
in the function logs.

| link | result |
|---|---|
| probe detects a new run | **yes** — `reason: "nwm run advanced"` |
| store updates | **yes** — write-through had already stored the new favourite's flow, forecast, thresholds and name on favouriting |
| alert evaluation runs | **yes** — 13 reaches, 3 users, in the same invocation |
| conditions correctly classified | **yes** — Major on 640469625 (10-year threshold), Action on 620569308, and a send attempted for Diamond Creek |
| notification delivered | **NO** — 12 sends, all rejected: `messaging/third-party-auth-error`, "Invalid APNs credential" |

**The delivery failure is an environment gap and production is unaffected.**
Firebase has a **Production** APNs auth key (`P663R3US8S`) and no **development**
one. A build installed from Xcode registers with Apple's sandbox environment,
which that key cannot authenticate against; TestFlight and App Store builds use
production and work — confirmed by Jerson receiving alerts every six hours from
the last TestFlight build. So alerts are not broken for users; they are
**untestable from a local build**, which is its own real cost: this is the
second time this session that the build needed for one kind of evidence was
the build that made another kind impossible.

Completing this guard needs either a development `.p8` uploaded to the empty
slot, or a TestFlight build. Deferred rather than faked.

**The cycle also exposed a live defect, now fixed.** Four stale FCM tokens were
detected and all four cleanups threw:

    ❌ Failed to clean up stale tokens
    "Element at index 0 is not a valid array element. Nested arrays are not
     supported."

`FieldValue.arrayRemove` takes varargs; it was being handed the array itself.
So no stale token was ever pruned and every cycle retried the same dead devices
indefinitely. Recorded in ADR 0008 and carried as a Phase 9 item — fixed here
because it was firing in front of us.

### Guard 3 — two accounts, two devices, one river (2026-08-30)

**Identical: 13966 CFS, Normal, on both.** iPhone (iOS 26.6, debug at
`7cf587c`) signed in as the primary account; Android 15 emulator (profile at
`62ef301`) signed in as a **different** account, `jersonjara7.18@…`, with White
River (18471070) added fresh. Same units on both.

The store holds exactly one document for that reach —
`nwm__18471070__analysisAssimilation`, run `2026-08-29T23:00:00Z`, unit CFS,
fetched `2026-08-30T02:20:16Z` — read out of Firestore directly.

**What that does and does not establish.** It proves the store HOLDS 13966; it
does not prove either device READ it from there. `analysisAssimilation` is one
observed value per model run, so two devices on the live path would have seen
13966 as well — the experiment cannot tell the two apart, and the iPhone's
convergence came from a pull-to-refresh that a live fetch would have satisfied
identically. The agreement is real and worth having; the stated mechanism is an
inference from it.

The instrument that WOULD discriminate already exists and was not used:
`servedFromStore` / `servedFromUpstream` on `StoreBackedDataSource`, the same
counters that produced guard 6's zero-upstream evidence. Reading them on both
devices during the comparison would settle it. Recorded as unproven rather than
restated more carefully.

**They disagreed at first, and the reason is worth keeping.** Android showed
13966 while the iPhone showed 13744.1 — same units, same category, different
number. The iPhone was backgrounded and its log had produced no new lines since
before the store's 02:20 refresh, so it was displaying what it last drew rather
than what the store held. One pull-to-refresh and it read 13966.

So convergence is **on render, not continuous**: a device that is not looking
shows what it last drew. That is correct behaviour and not a defect, but it
means "two devices agree" is only meaningful for two devices that have both
rendered since the last store write. Worth stating, because the guard's wording
("identical values") invites the stronger reading.

### Guard 4 — airplane mode (2026-08-30)

**Favourites render, with their flow numbers.** Airplane mode on, RIVR
force-quit, relaunched from the home screen: the rivers appear with values, not
empty cards, spinners or an error. iPhone, iOS 26.6, same profile build as
guard 2 (the tree that became `4217077`).

This is the guard the whole cloud layer was built to make true, and it is worth
being precise about what it proves and what it does not. It proves the app can
draw a favourite from what it already holds, with no network of any kind. It
does not prove the values are current — that is what the Phase 7 indicator is
for, and in this test the offline strip was correctly showing at the same time.

### Guard 2 — favourites render cold (2026-08-30)

**969 ms median, against a 3 s bar.** Three cold starts, iPhone (iOS 26.6),
**profile build of the tree that became `4217077`** — AOT-compiled like a
release, so the figure is not debug-mode slow.

| run | to first favourites paint |
|---|---|
| 1 | 969 ms |
| 2 | 1008 ms |
| 3 | 961 ms |

Six favourites. The spread is 47 ms across three runs, which is the more
interesting number: this is not a lucky sample.

**What the measurement includes**, since a figure without its definition is how
the Phase 0 table came to be optimistic: wall-clock from the first line of
`main()` to the end of the first frame in which the favourites list is built
with content. Firebase init, auth restore, provider construction, the cache
read and layout are all inside it. Only what the OS did before Dart started is
outside.

**The non-favourite half of this guard was NOT measured, and the first version
of this section did not say so.** The guard reads "Favourites render under 3 s
cold; non-favourites show a titled sheet under 500 ms and fill progressively."
Only the favourites half has a number. Nothing in the repo can produce the
other one: the only `Stopwatch` in `lib/` is `StartupTrace`, which times
`main()` to the first favourites paint and is called from exactly one place.
Measuring sheet-open needs its own instrument. This was a declared
carry-forward from Phase 1 that arrived and was quietly dropped — recorded
here as outstanding rather than left to look complete.

**Two further things it does NOT measure, stated so nobody reads more into it.** The
app's on-disk cache was warm — this is "app not in memory", the ordinary cold
start, not a first-ever install with an empty cache, which is a different and
slower case that remains unmeasured. And the device was online; the offline
case is guard 4.

For contrast, guard 1's retaken table says a single `analysis_assimilation`
call to NOAA averages **3.9 s** and fails 6% of the time. The whole favourites
screen now paints in a quarter of one such call, because it makes none.

### Guard 1 — Phase 0's timings retaken (2026-08-30)

Same five endpoints, same probe, **189 hourly samples over 7.7 days**
(2026-08-22 09:07Z → 2026-08-30 02:01Z) against the original **50 samples taken
across 30 minutes**. Averages and worst cases count successful calls only; the
success column carries the failures.

| endpoint | success then | success now | avg then | avg now | worst then | worst now |
|---|---|---|---|---|---|---|
| `?series=analysis_assimilation` | 10/10 | **166/177** | 2.1 s | **3.9 s** | 8.4 s | **52.8 s** |
| `?series=short_range` | 10/10 | **166/177** | 2.2 s | **4.2 s** | 8.6 s | **52.6 s** |
| `?series=medium_range` | 9/10 | **155/177** | 10.9 s | **12.4 s** | 34.7 s | **60.2 s** |
| `?series=long_range` | 10/10 | **158/177** | 15.7 s | **9.5 s** | 51.5 s | **57.6 s** |
| unfiltered (all series) | 8/10 | **143/177** | 10.5 s | **20.5 s** | 35.6 s | **57.9 s** |

**The original numbers were optimistic, and the correction runs the same
direction as the decision.** The two light endpoints — the ones a detail sheet
needs — were recorded as 10/10 at ~2.1 s from half an hour of sampling. Over
nearly eight days they are **94%** at ~4 s, with a worst case of **52.8 s**.
The 30-minute window simply could not see a 6% failure rate or a
fifty-second tail.

That does not overturn Phase 0's thesis, it sharpens it. Weight is still what
fails worst (`unfiltered` doubled to 20.5 s and is the least reliable at 81%),
so asking a narrower question still helps. But "upstream is not slow" was
itself a 30-minute impression: upstream is *usually* fast and unreliable often
enough that ~1 device request in 17 fails, and one in a hundred takes most of a
minute. **A device on this path has a bad day regularly.** That is the case for
the store stated in measurements rather than in argument, and it is stronger
than the case Phase 0 made.

`long_range` improving (15.7 s → 9.5 s) is the one figure moving the other way,
and it is the clearest evidence that the original sitting caught a degraded
window rather than a baseline.



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
Hawaii/Puerto Rico. (**Both ADR 0008 defects are now fixed** — though the first claim of that was
premature: `arrayRemove` was fixed in `notification-service.ts` and an
identical copy in `weekly-digest.ts` was missed, because the guard test named
one file. The weekly digest kept failing to prune dead tokens every Friday
until the Phase 8 review found it. The guard now derives its file list from the
sources and fails if any other file prunes tokens unguarded.
`setupNotificationListeners()` gated on `enableNotifications` alone — fixed
2026-08-30 by extracting `wantsAnyNotification`, since a user with flood alerts
off and the Weekly Outlook on still gets a notification every Friday and had no
tap routing and no token refresh.) (**The `arrayRemove` defect was fixed
2026-08-30**, out of order — it was caught firing live during Phase 8 guard 5,
and it was not a *silent* no-op as described here: it threw on every cycle that
found a stale token. Nothing was pruned and every alert run retried the same
dead devices.)

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
