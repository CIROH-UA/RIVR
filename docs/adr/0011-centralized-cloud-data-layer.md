# 0011 — Centralized cloud-backed data layer

**Status:** Phase 0 instrumentation deployed 2026-08-22 (collecting; its guards need a week). Phases 1-9 specified, not implemented.
**Supersedes in scope:** ADR 0010 (Weekly Outlook latency) — that page is one symptom of this
**Related:** ADR 0001 (SSOT repository), ADR 0002 (canonical derived values), ADR 0008 (push)

## The bar

**No value in the app takes longer than 3 seconds to appear.** Jerson's bar, as
the app's developer: anything slower is a poor experience, full stop.

Favourites should be effectively instant. Non-favourites get "as fast as the
upstream API allows, shown progressively, never a blank wait" — a different
promise, honestly kept, rather than one promise that breaks unpredictably.

## Why the current design cannot meet it

Measured 2026-08-21/22, 45 samples across 3 reaches, from a wired connection:

| source | min | median | max | failures | payload |
|---|---|---|---|---|---|
| `short_range` | 0.7s | **12.8s** | 28.2s | 0/9 | 2.7 KB |
| `medium_range` | 0.3s | **30.8s** | 60.3s | **3/9** | **156 KB** |
| `long_range` | 0.3s | **30.5s** | 60.5s | **2/9** | 63 KB |
| `return_period` | 1.0s | **1.2s** | 9.1s | 0/9 | 0.2 KB |
| GEOGLOWS (proxy) | 0.2s | **20.7s** | 23.5s | 1/9 | 24 KB |

**5 failures in 45 calls (11%).** No client-side retry policy reaches 3 seconds
against a 30-second median. Only *not waiting for it* does.

The map detail sheet issues **four of these as separate `await`s** — reach info,
current flow, return periods, medium range — for **~45 s at median** before it
draws anything.

### Independently measured endpoints

Sampled 2026-08-22 alongside the table above. These are separate services and
they fail separately, which the design relies on:

| endpoint | latency | payload | notes |
|---|---|---|---|
| NOAA `/reaches/{id}` (metadata) | 0.30–1.11 s | ~0.54 KB | stayed **up** at 0.4 s through the full `/streamflow` outage |
| CIROH `/return-period` | 1.0–9.1 s | 0.2 KB | separate host |
| GEOGLOWS proxy | ~20 s | 24 KB | our own Cloud Function |

**A full `/streamflow` outage was observed on 2026-08-22**: all five series
returned HTTP 504 after exactly ~60 s, filtered and unfiltered alike, six
consecutive attempts — while reach metadata, return periods and GEOGLOWS all
answered normally. During that window the app could not show a flow value for
any NWM river, because nothing renders from cache.

### MEASURED — endpoint weight, not endpoint choice, is what fails (2026-08-22)

Raised by Jerson: the failure rate above, and the Phase 0 probe, both measure the
**unfiltered** `/streamflow` response — the heaviest thing the API returns. If
the filtered `?series=` endpoints survive when unfiltered does not, the probe is
a worst-case sensor rather than a measure of service availability.

**10 rounds, 3 minutes apart, all five variants fired simultaneously each round
so a bad window cannot favour one. 50 samples.**

| endpoint | success | avg | worst |
|---|---|---|---|
| `?series=analysis_assimilation` | **10/10** | **2.1 s** | 8.4 s |
| `?series=short_range` | **10/10** | **2.2 s** | 8.6 s |
| `?series=medium_range` | 9/10 | 10.9 s | 34.7 s |
| `?series=long_range` | 10/10 | 15.7 s | 51.5 s |
| unfiltered | 8/10 | 10.5 s | 35.6 s |

**Confirmed:** under stress the heavy requests fail and the small ones do not.
All three failures fell in the degraded rounds 1–2; `analysis_assimilation` and
`short_range` came through untouched.

**Not confirmed:** that the unfiltered endpoint is *specifically* fragile. The
failures cluster by time, not by endpoint — unfiltered twice and `medium_range`
once, in the same two rounds. Separating "this URL is weak" from "those minutes
were bad" needs failures spread across rounds, which this run does not show.

**The consequence that matters.** The two products the map detail sheet needs
for current flow averaged **2.1 s at 10/10**, through a window where heavier
calls were timing out. That is inside the 3-second bar with no caching at all —
so a meaningful share of the latency problem is *which call we make*, not
*whether we cache*.

**And the Phase 0 probe measures the wrong thing.** It requests the heaviest
response, so "5 of 7 samples failed" describes the worst case, not whether the
app's own calls would have succeeded. Unverified and worth measuring: what the
failure rate looks like for `analysis_assimilation` + `returnPeriods`
specifically, which is what a user actually waits on. Probe design pending
Jerson's call.

### The 0.3s entries are the tell

Same URL, same reach, sometimes 0.3s and sometimes 60s. Upstream is fast when
warm and very slow when cold. A single fast sample is not a baseline — an early
measurement in this investigation recorded 300 ms and was wrong to present it as
typical.

## What the data actually publishes

Sampled at 06:45Z and again at 07:23Z:

| series | at 06:45Z | at 07:23Z | nominal cycle |
|---|---|---|---|
| analysis_assimilation | 21 Aug 20:00Z | — | hourly |
| short_range | 21 Aug 23:00Z | 22 Aug **05:00Z** | hourly |
| medium_range | 21 Aug 18:00Z | 22 Aug **00:00Z** | 6-hourly |
| long_range | 21 Aug 12:00Z | — | 6-hourly |

**The 00Z medium-range run appeared ~7 hours after its nominal cycle time.**
Publication lag is large and variable, which is why cycle-aligned cron schedules
systematically miss.

**`referenceTime` is the freshness signal, not elapsed time.** An 8-hour-old
value *is* the latest available if nothing newer has published. The app currently
expires short-range hourly on the assumption a new run exists, and would refetch
up to 156 KB to receive identical bytes.

`referenceTime` was **identical across 8 sampled favourite reaches**
(`2026-08-22T05:00:00Z`, 8/8, no failures). That is consistent with atomic
publication but does not prove it — see Phase 3 guard 4, which is designed so the
answer does not matter.

## NOAA's documented cadence, and where the app disagrees with it

From [NOAA's National Water Model page](https://water.noaa.gov/about/nwm),
their wording:

| configuration | official cadence | horizon | members |
|---|---|---|---|
| Analysis & Assimilation (CONUS) | "cycles hourly" | real-time | 1 |
| Short Range (CONUS) | "cycles hourly" | 18 h | 1 |
| Medium Range (CONUS) | "executed four times per day" | 10 d / 8.5 d | 6 |
| Medium Range Blend | "executed four times per day" | 10 d | 1 |
| Long Range (CONUS) | "cycles four times per day" | 30 d | 16 |
| **Alaska Short Range** | **"cycles every three hours"** | 15–45 h | 1 |
| **Hawaii / Puerto Rico Short Range** | **"cycles two times per day"** | 48 h | 1 |

`NwmDataSource.validUntil` matches this **for CONUS** — hourly for
analysis/short, 6-hourly for medium/long.

**Bug: it applies the CONUS rule to every reach.** Alaska short range cycles
every three hours and Hawaii/Puerto Rico twice a day, so for a non-CONUS reach
the app expires short-range data hourly and refetches up to 24× a day for
something that changes 2–8×. Wasted calls against an API measured at 11%+
failure, and on a product where a wasted call is the difference between a warm
cache and a spinner. Not urgent — coverage there is thin — but it belongs to
whichever phase touches `validUntil`.

**It also confirms the publication-lag finding is real.** The 00Z medium-range
run was observed appearing ~07:20Z. Against a documented 6-hourly cadence that
is genuinely late, not a misreading of the schedule — the previous run remains
the newest available for most of the window.

## Decisions

1. **Our cloud is the source of truth for favourited reaches.** The app never
   calls NOAA or GEOGLOWS directly for them.
2. **Storage is per-reach and shared across all users and accounts**, so the same
   stream shows the same number everywhere. Not per-user bundles — those are
   written at different times and reintroduce divergence.
3. **One store in the app.** Every widget reads through it. No widget fetches.
4. **Freshness is keyed on `referenceTime`** (NWM) / `forecast_date` (GEOGLOWS),
   never on wall-clock TTL.
5. **An hourly probe decides *when to try*; each reach records the
   `referenceTime` it actually returned.** Progressive publication or a transient
   per-reach failure then costs a retry, not stale data under a fresh label.
6. **Non-favourites keep the live path.** With millions of streams, two users
   hitting the same reach before it changes is effectively never, so caching them
   in the cloud is cost without return.
7. **The detail sheet opens immediately and fills progressively**, issues its
   calls in parallel, defers the 156 KB medium-range fetch, and prefetches long
   range in the background so "See forecast" does not wait twice.
8. **Device cache retains until superseded by a newer run**, with an LRU cap and
   favourites pinned.
9. **No reference counting on unfavourite.** The work list is derived from the
   union of all favourites each run; orphans are garbage-collected.
10. **GEOGLOWS syncs once daily**, keyed on `forecast_date`.
11. **Alerts read from the store and evaluate when a new run lands.** The
    existing 6-hour cooldown remains the notification governor.
12. **No timestamps beside values.** Users should trust that what they see is the
    latest available; making that true is our job. A signal appears only when we
    *know* we are out of sync.
13. **The map's coloured streams and legend are finished and out of scope.**
14. **The store holds one canonical unit; conversion happens at read.** Today
    `NwmDataSource.fetch` stamps the payload with `_unitService.currentFlowUnit`
    — *the fetching user's* preference. A per-reach document shared between a
    CFS user and a CMS user cannot carry one user's unit. `RiverDataEntry.unit`
    already exists for exactly this ("read-time conversion goes from this to the
    user's current unit"); the store must populate it with the upstream native
    unit and never with a user preference.
15. **Derived values are computed in exactly one place.** `weekly-digest.ts:242`
    has `categoryIndexFor()` server-side while the client classifies
    independently — two implementations of one rule, which is the drift ADR 0002
    exists to prevent. Either the store carries the derived values and the client
    renders them, or the client derives and the server reads the same code. It
    cannot be both.
16. **Cached payloads carry a schema version.** `RiverDataEntry` has key, window,
    unit and payload — **no version**. Phase 3 changes the payload shape (storing
    only `mean`), so an upgraded app would decode old entries against a new
    reader. Entries without a recognised version are discarded, not parsed.

## Existing assets this builds on

| asset | state |
|---|---|
| `RiverDataRepository` | SWR, keyed `(source, reachId, product)`, in-flight dedup — already the single-store mechanism |
| `RiverDataKey.storageKey` | emits `nwm__23021904__mediumRange` — usable directly as a Firestore document ID |
| `NwmDataSource` / `GeoglowsDataSource` | registered in DI; `mediumRange` and `returnPeriods` already first-class products |
| `return_period_cache` | Firestore, **keyed by reach ID**, server-written — the pattern already in production |
| `checkRiverAlerts` | already fans out over every distinct favourite 4×/day, then discards the data |
| 6-hour alert cooldown | `checkRecentAlert`, with its composite index declared |
| `remote-notification` background mode | declared and unused |

Current scale: **18 users, 14 with favourites, 36 favourite rows, 29 distinct
reaches.** Cost scales with distinct reaches × cadence, not with user count.

---

# Phases

**Discipline that applies to every phase.** Each guard must include at least one
test *demonstrated to fail before the change and pass after*. A guard that passes
against the current code is not a guard — this repo has produced two of those
(ADR 0009 phase 4, and a `strings` check that passed against both the fixed and
broken IPA).

**No legacy paths survive a phase.** Whatever a phase replaces, it deletes in the
same phase — not later, not behind a flag, not "just in case". Work happens on
`development` and every previously working version is committed on `main`, so
deleted code is recoverable from history and does not need to be recoverable from
the working tree. A dual path kept for comfort is a second source of truth, which
is the problem this ADR exists to remove.

The one exception is the Phase 4 kill switch, which is a deliberate, monitored,
time-boxed fallback — and it is removed in Phase 9 once the store has proven
itself.

**Stale documentation is a defect.** Each phase updates the docs it invalidates
as part of the phase, and Phase 9 sweeps whatever slipped through.

## The review gate — the last guard of every phase

**No phase is complete until an independent agent review passes.** This is the
final numbered guard in each phase below, and it is a gate, not a formality: a
phase that fails it is not done, regardless of how the other guards look.

**Why.** The person who wrote the code is the worst judge of whether it meets the
spec, because they have already convinced themselves. This repo has the receipts:
a guard in ADR 0009 phase 4 that would have passed against the broken code, a
`strings` check that passed against both the fixed and the broken IPA, a
"measured" claim in ADR 0008 that was never measured, and a Phase 5 scope
estimate in this very document that was wrong until it was checked. Every one was
caught by looking again with fresh eyes, and every one had already been declared
finished.

**How it runs.**

- A **fresh agent with no context from the implementation.** It must not inherit
  the assumptions that produced the work.
- It is given: the phase's guards, its "you are done when", and the diff. It is
  **not** given a summary of what was done — summaries are where self-deception
  hides.
- It **verifies independently** — running tests, reading source, executing
  commands. Claims in commit messages, code comments, or this ADR are treated as
  assertions to check, never as evidence.
- Its posture is **adversarial**: for each guard, actively try to construct a case
  where the code fails it. The question is "how is this still broken", not "does
  this look right".

**Required output.** Per guard: `MET` / `NOT MET` / `CANNOT VERIFY`, each with
concrete evidence — a command and its output, or a `file:line`. Then a single
overall verdict.

- **`CANNOT VERIFY` counts as a failure.** A guard that cannot be checked is a
  guard that isn't real, and it must be rewritten until it can be.
- The reviewer **reports and does not fix**. Fixing is the implementer's job;
  merging the two roles recreates the problem the gate exists to solve.

**It must specifically hunt this project's known failure modes:**

1. **Fake guards** — would this test also pass against the code *before* the
   change? If yes, it proves nothing. This is the single most valuable check.
2. **Unearned "measured"** — is every number traceable to a run, or was it
   inferred and then stated as fact?
3. **Silent success** — if this failed halfway, would anything actually notice,
   or would it exit 0 with partial data? Five operations in this repo have done
   exactly that.
4. **Stale documentation** — what did this change make untrue that is still
   written down?
5. **Legacy left behind** — is there now a second way to do the thing this phase
   centralised?

**The reviewer also answers the phase's "you are done when" in its own words**,
from the evidence rather than from the ADR's phrasing. If it cannot, the phase is
not done.

Phases 1 and 2 are app-only. Phase 3 is server-only. They can proceed in
parallel.

---

## Phase 0 — Baseline and instrumentation

**Why first.** Every number above came from one window in which NOAA was
returning 504s. The probe interval, the cache cap, and the monitoring thresholds
all depend on knowing typical behaviour, and none of them can be chosen honestly
from a single sitting.

**Build.**
- A scheduled job logging `referenceTime` per series plus HTTP status, hourly,
  from one reach. No app change required.
- Device-side timing instrumentation: elapsed ms per row, per fetch, per phase of
  the detail sheet and the Weekly Outlook, plus cache hit/miss.
- Capture on device for warm cache, cold cache after reinstall, and a forced
  degraded network.

**Guards.**
1. Seven consecutive days of hourly `referenceTime` samples, with no gaps
   exceeding one hour.
2. Publication lag is characterised per series — median and worst observed —
   rather than inferred from the two samples in this ADR.
3. The dominant cost in the detail sheet is named with a number, not a
   hypothesis. **Note the ADR's own "~45 s at median" is arithmetic on the
   per-source medians, not an observed end-to-end time — the sum of medians is
   not the median of the sum.** This guard is not met by that figure.

   *Deviation, 2026-08-22:* the device-side timing instrumentation is folded
   into Phase 1 rather than built separately here, because Phase 1 rewrites the
   exact code paths that would be instrumented and doing it twice is waste.
   Phase 1 therefore carries the obligation to emit these numbers, and this
   guard cannot close until it does.
4. Upstream failure rate is measured over the week, so the 11% in this ADR is
   confirmed or corrected. **Scope limit, found in review:** the probe issues one
   unfiltered NOAA call, whereas the 11% spans five different endpoints including
   CIROH return periods and the GEOGLOWS proxy. The probe measures NOAA
   `/streamflow` availability only, and cannot by itself confirm or correct that
   figure — say which number is being reported.
5. ~~Which reaches are actually opened is logged~~ — **deferred, 2026-08-22.**
   `firestore.rules` default-denies everything except `users/{uid}`, so a client
   write needs a new rule, and a counter any client may increment is an abuse
   surface. `logForecastLoaded` already emits `reach_id` to Firebase Analytics,
   so the data exists if a BigQuery export is ever enabled. Decision 6 therefore
   still rests on the scale argument rather than on measurement — stated plainly
   rather than quietly skipped. It gates nothing; revisit if usage grows.
6. **Any claim in this ADR contradicted by the data is corrected here before code
   is written.** At least one correction is expected.
7. **Independent agent review passes** (see *The review gate*).

**You are done when** you can state, with a week of data: how often each series
actually publishes, how late it typically is, how often it fails, and how long
the app currently takes to draw a detail sheet on a warm and a cold cache.

---

## Phase 1 — The non-favourite experience

**Why.** Independent of all cloud work, ships alone, and fixes the most-used
surface. Non-favourites will always take the live path, so this is permanent
value rather than a stopgap.

**Build.**
- Issue the detail sheet's four calls in **parallel** — nothing about them is
  ordered.
- **Defer medium range.** The headline is name, current flow, flood category. The
  156 KB fetch exists for the forecast-peak strip and can wait until that section
  is reached.
- **Draw progressively.** The sheet appears immediately with a skeleton naming
  the river; each value fills as it lands.
- **Prefetch long range in the background** after the sheet's own calls complete,
  so "See forecast" does not wait a second time. Failures are silent.

**Guards.**
1. The sheet is on screen in **under 500 ms** with a skeleton, before any network
   call completes. *The tile carries only `station_id` — `_riverName` comes from
   the fetch, so the sheet cannot be titled instantly.*

   **Open, and honestly unmet.** There is no test and no device measurement, and
   "prioritised" is aspirational: the three reads are issued together with no
   head start for `reachMetadata`. What *has* been fixed is the thing that
   invalidated the guard's premise — an earlier attempt at the Location fix put
   a serial `reverseGeocode` inside `reachMetadata`, and since that helper
   catches internally and never throws, nothing bounded it but a 30 s HTTP
   timeout. Geocoding now happens after the title is on screen. Closing this
   guard needs the Phase 0 device capture.
2. With reads of differing latency, every value appears as it lands — a ready
   flow value is visible while a 30 s threshold call is still outstanding. The
   sheet issues **three** reads, not four; the fourth call in the original
   framing was the medium-range series, which this phase removed.
3. Medium range is **not** requested until the forecast section is reached.
   Assert against a request-recording fake.
4. One read failing never blocks the others — losing the flood category must
   not cost the river's name or its flow.
5. **The sheet issues exactly its three reads and nothing else**, and none of
   them waits on another — asserted on recorded start times, not list position.

   *Corrected twice, and the second correction matters more than the first.*

   Originally this required prefetching `longRange`. Review found the forecast
   page never reads that product — it reads `reachSummary` and takes its
   long-range series from `ReachDataProvider` — so the prefetch warmed an entry
   nothing read: 63 KB and a 30.5 s median per tap for nothing. Removed.

   **But deleting it outright was also wrong, and review caught that too.**
   Before this phase the sheet read `reachSummary` *itself*, which is the same
   key the forecast page reads, on an hourly TTL — so "See forecast" was already
   a warm hit. Splitting the sheet into narrow products silently removed that
   side effect, which would have moved the entire bundled wait onto the "See
   forecast" tap and made it **slower than before the optimisation**. A local
   improvement that is a global regression.

   **A third review rejected the warm as well, and it was right.** Warming
   `reachSummary` still pulled the 156 KB medium-range series on every tap — two
   layers below where the sheet's test could see it — and it put the same
   current-flow number in two independently-cached entries, which is the
   divergence decision 3 exists to prevent. The real fix was to stop the
   forecast page reading the bundle at all: it now reads the **same three narrow
   products**, so "See forecast" is warm with nothing warming it, and both
   screens show one cache entry rather than two.

   Guard 3 is now additionally asserted at the **API layer**
   (`data_sources_test.dart`), because a repository-level fake is structurally
   blind to a fetch that happens inside `ForecastService`.

   **Measured, not assumed** (`river_data_repository_test.dart`): after the
   sheet has read its three products, the forecast page issues **zero** further
   fetches, and both surfaces receive the *identical* entry — verified by
   changing what the source would return next and confirming the page still
   gets the sheet's value. "Warm with nothing warming it" is a test result, not
   an argument from key equality.

   Ordering assertions alone are not sufficient: review mutation-tested the
   original guard by moving the prefetch to start concurrently with first paint
   and it still passed, because it only checked position in a list recorded at
   call time.
6. With the network black-holed, the sheet reaches a terminal, non-spinner state
   **naming what failed** — "Failed to load current flow", not a constant
   string — **and offering Retry**. A card that says the same thing whatever
   broke teaches people to ignore it, and a terminal state with no way out is a
   dead end.
7. **Independent agent review passes** (see *The review gate*).

**You are done when** tapping any stream on the map — favourite or not, on a cold
cache — puts a sheet on screen instantly, titles it as soon as the cheapest call
lands, fills each number as it arrives, never shows a blank spinner, and tapping
"See forecast" does not repeat a wait the user already served.

---

## Phase 2 — Device cache discipline

**Why.** **Nothing prunes the disk cache today** — `evict()` and `clear()` exist
and nothing calls them. Deliberately caching every browsed stream on top of that
would grow without bound.

**Build.**
- Retention keyed on **run supersession**, not wall-clock: an entry is valid
  until a newer `referenceTime` / `forecast_date` exists.
- **LRU cap on entry count** for non-favourites.
- **Favourites are pinned** and never evicted.
- Entries record the run they came from, so supersession is decidable offline.

**Guards.**
1. An entry whose run has not advanced is served **without any network call**,
   however old it is in wall-clock terms.
2. Exceeding the cap evicts least-recently-used non-favourites, and **never** a
   favourite. Test with the cap exceeded entirely by favourites.
3. Cache size stabilises under simulated browsing of many reaches.
4. Favouriting a previously-browsed stream renders instantly from cache, with no
   fetch.
5. A cold cache still works — no path assumes an entry exists.
6. **Upgrading over an old install does not read stale-shaped entries.** Entries
   without a recognised schema version are discarded and refetched, not parsed
   optimistically. Test by installing over a build with the previous payload
   shape — every user upgrading hits this path exactly once, and a decode failure
   there is a crash on first launch.
7. A unit-preference change re-renders from the same cached entry without a
   refetch, converting at read.
8. **Independent agent review passes** (see *The review gate*).

**You are done when** browsing hundreds of streams leaves the cache bounded,
favourites survive eviction unconditionally, and a stream you looked at earlier
still draws instantly with the network off.

---

## Phase 3 — Cloud store: write path

**Why.** This is the source of truth. Server-only; no app changes; fully
verifiable before any client depends on it.

**Build.**
- **Hourly probe:** one unfiltered request against a single reach yields every
  series' `referenceTime`. ~24 requests/day regardless of favourite count.
- **On advance, fetch the affected products** for every reach in the derived work
  list.
- **Work list is derived** each run from the union of all users' favourites.
  Nothing is reference-counted.
- **Per-reach records** at `nwm__<reachId>__<product>`, matching
  `RiverDataKey.storageKey` so the document ID *is* the client cache key.
- **Store the trimmed payload** — the app reads `mediumRange['mean']`; storing
  only that should cut 156 KB by roughly 6× and keeps documents far from
  Firestore's 1 MiB limit.
- **Each record carries the `referenceTime` it actually received.**
- **Per-reach retry across cycles** — a reach that fails at one run is retried at
  the next, not left stale.
- **GEOGLOWS on its own daily schedule**, keyed on `forecast_date`, retried until
  it advances.
- **Return periods** stay on their existing slow path.
- **Write-through on favourite.** A newly-favourited reach is otherwise absent
  from the store until the next hourly run. The client already holds it from
  browsing (Phase 2 guard 4), but a reach favourited from search may never have
  been viewed. Favouriting therefore triggers an immediate server-side fetch for
  that reach, and the UI renders from the device cache meanwhile.
- **GC:** documents whose reach is absent from the union and unrefreshed for ~7
  days are deleted.
- **Security rules — a hard blocker for Phase 4, found 2026-08-22.**
  `firestore.rules` opens with a catch-all `match /{document=**}` denying read
  and write, then grants access **only** to `users/{userId}`, plus a
  `notification_logs` block that also denies all client access. The app therefore cannot read
  any store collection today; `return_period_cache` is server-written and
  client-unreadable for exactly this reason. Phase 4 does not work at all until a
  rule is added: store documents readable by any authenticated user, writable
  only by the Admin SDK. They hold no user data — the key is a reach, not a
  person — but they must never be client-writable.
- **Monitoring, shipped with this phase, not after:** the probe's
  `referenceTime` compared against every stored record; a heartbeat alerting when
  no successful write lands in N hours; and a **count assertion** of reaches
  updated versus expected on every run.

**Guards.**
1. No new run → **zero** fetches beyond the probe.
2. A new run → every reach in the work list is updated, and the count assertion
   equals the expected number.
3. **A reach returning an older `referenceTime` than the probe is stored with its
   own value and retried — never written under the probe's run.** This is the
   guard that makes atomic publication irrelevant.
4. A reach failing entirely leaves its previous record intact and is retried next
   cycle.
5. Unfavouriting everywhere removes the reach from the work list; its document
   survives the GC window and is then deleted.
6. Two users favouriting the same reach produce **one** document and one fetch.
7. Stored documents are materially smaller than the raw upstream payload —
   measured, not assumed.
8. **Silent failure is impossible:** kill the fetch mid-run and confirm the count
   assertion fires. This repo has five documented cases of operations exiting 0
   while producing wrong or partial data; exit status has never caught one.
9. Favouriting a never-viewed reach produces a store document within seconds, not
   at the next hourly run.
10. **Documents are stored in the upstream native unit**, never a user's
    preference. Test: two users with opposite unit settings favourite one reach
    and the document is byte-identical regardless of who triggered the fetch.
    This is the guard that stops a shared store from being poisoned by whoever
    happened to fetch first.
11. **Overlapping runs cannot write backwards.** If a slow run is still going
    when the next fires, a write carrying an older `referenceTime` must not
    replace a newer one. Test by interleaving two runs deliberately.
12. Every stored document carries a schema version, and a reader rejects an
    unrecognised one rather than parsing it.
13. Firestore reads and writes per day are **measured** against the documented
    free quota (50k reads / 20k writes) and recorded, so the scaling law —
    distinct reaches × cadence — is confirmed rather than assumed.
14. **Independent agent review passes** (see *The review gate*).

**You are done when** the store has held correct, current values for every
favourited reach across several publish cycles with nobody watching, a
deliberately broken run raises an alarm rather than passing quietly, and you can
answer "is the store fresh right now?" from a dashboard rather than by
inspection.

---

## Phase 4 — Cloud store: read path

**Build.** Point `NwmDataSource` and `GeoglowsDataSource` at the store instead of
upstream, for favourited reaches. The repository, keys, products and freshness
logic are unchanged — this is a data-source swap.

Non-favourites continue to the live path.

**How the app learns of new data.** It reads the store on app open and on
foreground resume — a single ~250 ms document read per favourite, which is well
inside the bar and needs no background execution. It does **not** poll while
open, and it does **not** depend on iOS background refresh, which cannot be
scheduled and can be disabled by the user. If a run lands while the app is open,
it is picked up on the next resume; that is acceptable because the value on
screen is still the latest that existed when it was drawn.

**Kill switch.** A Remote Config flag forces every device back to the live path.
The flood pipeline already uses Remote Config this way, and an app release takes
days — if the store serves something wrong, the fix must not wait on the App
Store.

**Guards.**
1. A favourite renders with **zero** upstream calls from the device.
2. Two devices, and two different accounts, sharing a reach show **identical**
   values. This is the requirement that motivated the design.
3. A favourite renders in **under 3 seconds** on a cold device cache — the bar.
4. Values match what the old path produced for the same run, field by field.
5. A missing or malformed store document degrades to the live path without an
   error shown.
6. **No other surface changes behaviour.** Full suite green.
7. **The kill switch works**: flipping the Remote Config flag returns every
   device to the live path within one launch, verified on a real device — not
   just in code review.
8. Older app versions still on the direct path keep working throughout rollout;
   the store is additive, never a breaking change to the API contract.
9. **Independent agent review passes** (see *The review gate*).

**You are done when** two phones signed into different accounts, both favouriting
the same river, show the same number at the same time — and each renders it
within 3 seconds of a cold start.

---

## Phase 5 — Single data path

**Why.** "All widgets consume the same data" is the decision; today the app is
split, with `favorites_provider` and `weekly_outlook_page` reading *both* through
the repository and directly.

**Build.** Remove direct `ForecastService` / `NoaaApiService` use from
`reach_data_provider`, `reach_data_cache_mixin`, `hydrograph_page`,
`interactive_chart`, and the mixed paths in `favorites_provider` and
`weekly_outlook_page`.

**`ReachDataProvider` is the bulk of this phase — measured, not guessed.** It is
939 lines, mixes in `ReachDataCacheMixin` (a further 179), and is referenced from
`main.dart` plus **nine** forecast widgets: `hydrograph_page`,
`reach_forecast_page`, `chart_preview_widget`, `current_flow_status_card`,
`forecast_category_grid`, `horizontal_flow_timeline`, `interactive_chart`,
`long_range_calendar`, and `favorites_page`, plus `geoglows_forecast_provider`.

It is therefore **rewired to read through the repository, not deleted.** Scope
this phase around that migration; treating it as a leftover would badly
underestimate the work, and every one of those nine widgets is a regression
surface.

**Delete `ForecastService`'s competing cache layer** — `_currentFlowCache`,
`_flowCategoryCache`, `_recentResponseCache` and its `_forecastCacheService`
writes. These are a second cache alongside the repository, with their own TTLs,
and two caches holding different values for the same reach is precisely the
divergence this ADR exists to eliminate. This is a correctness change, not
cleanup.

Whatever methods fall out of use go with them — `loadCompleteReachData` first,
since Phase 4 removes its last caller.

**Guards.**
1. `grep -rn "NoaaApiService\|IForecastService" lib/ui/` returns nothing.
2. Every surface showing the same reach shows the same value simultaneously —
   favourites card, detail sheet, forecast page, hydrograph.
3. Two widgets mounting the same reach together issue **one** fetch.
4. A unit flip repaints every surface without refetching.
5. Full suite green; no surface silently loses data.
6. **Exactly one cache holds forecast values.** `ForecastService`'s in-memory and
   disk caches are gone; a reach cannot be represented twice with two different
   TTLs.
7. No method survives with zero callers — verified by search, not by intent.
8. **All ten `ReachDataProvider` consumers render correctly after the rewire** —
   each of the nine widgets plus `geoglows_forecast_provider` exercised, not
   assumed. This is the phase's main regression risk.
9. **Independent agent review passes** (see *The review gate*).

**You are done when** there is exactly one way for a value to reach the screen,
and no widget can fetch on its own even if someone tries.

---

## Phase 6 — Alerts on the store

**Why.** Free to change: **no alert has ever been delivered** — the
`notification_logs` collection does not exist. And the 6-hour cooldown decouples
check frequency from notification frequency, so raising the former cannot spam.

**Build.** `checkRiverAlerts` reads from the store rather than fetching, and
evaluates when a new run lands rather than on a fixed clock. The cooldown is
untouched.

**Guards.**
1. Alerts issue **zero** upstream fetches.
2. A user crossing a threshold is alerted at most once per 6 hours per river,
   with hourly evaluation. **Verify the composite index is deployed, not merely
   declared** — `checkRecentAlert` catches its own errors and returns `false`, so
   a missing index silently disables dedupe and would send 24 alerts a day.
3. Alert values equal what the app shows for the same reach — by construction,
   same document.
4. No new run → no evaluation, no sends.
5. Time from publication to alert is under one hour, versus up to six today.
6. **The flood category a user sees and the one the alert fired on are produced
   by the same code.** `categoryIndexFor()` in `weekly-digest.ts:242` and the
   client's classification are two implementations of one rule; decision 15 says
   pick one. Test: a reach near a threshold boundary classifies identically in
   the notification body and on screen. Reading the same document is not
   sufficient — identical inputs through different code can still disagree.
7. **Independent agent review passes** (see *The review gate*).

**You are done when** an alert fires from data the app is already displaying,
within an hour of the run that triggered it, and a user sitting above threshold
for a week receives a defensible number of notifications.

---

## Phase 7 — The trust model

**Why last.** Removing the timestamp is a promise. It may only ship once Phase 3
monitoring proves the guarantee, because afterwards **users have no way to tell a
stale value from a current one — we have trained them not to look.**

**Build.**
- No timestamps beside values.
- One unobtrusive indicator only when the app *knows* it is out of sync — offline,
  or the store has not advanced past an expected cycle. Silence means current.
- The map legend keeps its date: a once-daily product where the date is real
  information. Out of scope by decision.

**Guards.**
1. No value view renders a timestamp.
2. Offline shows the indicator; healthy shows nothing.
3. A store deliberately frozen past its expected cycle raises the indicator
   **without** a user-visible error.
4. The indicator is driven by the same signal that alarms operationally — one
   source of truth for "are we fresh".
5. **Independent agent review passes** (see *The review gate*).

**You are done when** a user has no reason to pull-to-refresh, because the number
on screen is provably the latest published — and when it isn't, the app says so
before they have to wonder.

---

## Phase 8 — Prove it on device

**Guards.**
1. Phase 0's timings retaken and compared **in the same table**.
2. Favourites render under 3 s cold; non-favourites show a titled sheet under
   500 ms and fill progressively.
3. Two accounts, two devices, one river, identical values.
4. A full publish cycle observed end to end: probe detects, store updates,
   devices converge, alert fires.
5. Android checked — it shares this code path entirely.
6. Every number recorded with the build it came from.
7. **Independent agent review passes** (see *The review gate*).

**You are done when** the originally reported journey — tapping a Friday digest
on a cold start — renders rivers in under 3 seconds, and you have the numbers to
prove it rather than the impression.

---

## Phase 9 — Sweep: kill the legacy, fix the docs

**Why a phase and not an afterthought.** Every phase deletes as it goes, but
cross-cutting leftovers only become visible once the whole thing is standing.
This is affordable precisely because work happens on `development` and every
working version is committed on `main` — nothing needs to be kept in the tree to
be recoverable.

**Build — code.**
- **Remove the Phase 4 kill switch** and its Remote Config parameter, once the
  store has run clean through Phase 8. A permanent fallback is a permanent second
  source of truth.
- Delete every method, provider and mixin left with no callers. **The list is
  derived at the time, not predicted here** — an earlier draft of this ADR named
  `reach_data_provider` and `reach_data_cache_mixin` as candidates and was wrong
  (see Phase 5).
- Delete tests that only covered deleted paths; keep any that assert behaviour
  still promised, rewritten against the new path.
- Resolve the two server defects already logged in ADR 0008 rather than carrying
  them: `arrayRemove(staleTokens)` passes an array to a varargs API in
  `weekly-digest.ts:348` and `notification-service.ts:566`, so stale-token pruning
  is a silent no-op; and `setupNotificationListeners()` is gated on
  `enableNotifications` alone, so a weekly-only user never gets tap routing.

**Build — documentation.**
- **CLAUDE.md**: the architecture and data-flow sections describe an app that
  fetches upstream directly. Rewrite, including the `ForecastService` phased-load
  description, which will no longer be how data arrives.
- **ADR 0001**: Step 7 (retire the `ForecastResponse` fork) is closed or narrowed
  by Phase 5 — say which, with evidence.
- **ADR 0002**: Stage 2b was gated on "the next detail-carrying source"; record
  what actually triggered it.
- **ADR 0003**: the back-off flaw is documented but unfixed — decide and record
  whether the reset moves to tap.
- **ADR 0010**: already marked superseded; confirm its Phases 1–2 landed inside
  this ADR's Phase 1 or say why not.
- **`app_releases.md` / `notifications_history.md`**: an entry per shipped phase.

**Guards.**
1. `grep -rn "loadCompleteReachData" lib/` returns nothing.
2. No Remote Config parameter remains for the fallback, and no code reads one.
3. `flutter analyze` reports zero unused-element warnings across touched files.
4. Every ADR listed above is either updated or explicitly confirmed still
   accurate, with a dated line saying so.
5. A reader following CLAUDE.md alone would build the current architecture, not
   the previous one. **Test this by reading it as if new** — every stale-doc
   incident in this repo started with a doc that was true when written.
6. Full suite green with no skipped tests carried forward.
7. **Independent agent review passes** (see *The review gate*).

**You are done when** nothing in the tree describes or implements the old data
path, the two known server defects are fixed rather than documented, and someone
joining the project would not find a second way to fetch a river.

## Sequencing

```
Phase 0 ──┬── Phase 1 ── Phase 2 ─────────────┐
          └── Phase 3 ── Phase 4 ── Phase 5 ──┴── Phase 6 ── Phase 7 ── Phase 8 ── Phase 9
```

Phases 1–2 (app) and Phase 3 (server) run in parallel after Phase 0. Phase 4
needs 3. Phase 5 needs 4. Phase 7 needs Phase 3's monitoring proven in
production. Phase 8 proves it on device. Phase 9 removes the kill switch and the
last of the old path — it must come after 8, because the fallback has to survive
until the store is proven.

**Phases 1, 2, 3 and 6 each improve the product on their own** and are
independently shippable.

## What this does to the Weekly Outlook

ADR 0010's 3–5 minute stall is closed by **Phases 4 and 5**, not by anything
specific to that page. Its NWM rows currently call `loadCompleteReachData` —
always network, all four products, for a page that renders one series. Once
favourites read through the store, the page draws from documents it already has.
Phases 1 and 2 of ADR 0010 (per-row rendering, bounded wait) remain worth doing
as resilience, and are unaffected by this ADR.

## Review pass — what a second read caught

Recorded because each of these was wrong or missing in the first draft:

1. **Phase 1 guard 1 was unachievable.** It required the sheet to show the river
   name before any network call; the tile carries only `station_id`, and
   `_riverName` comes from the fetch. Rewritten around a skeleton plus a
   prioritised `fetchReachInfo`.
2. **A newly-favourited reach had no path into the store** for up to an hour.
   Write-through on favourite added.
3. **No kill switch.** An app release takes days; a bad store needed a
   same-minute revert. Remote Config flag added, with a device-verified guard.
4. **How the app learns of new data was unspecified** — the decision is
   read-on-open and on-resume, explicitly *not* iOS background refresh, which
   cannot be scheduled and can be disabled.
5. **No security rules and no cost guard.** Both added to Phase 3.
6. **Access-distribution logging was listed as an open question but never
   built.** Added to Phase 0, so decision 6 rests on data.
7. **No cleanup discipline and no doc review at all** (raised by Jerson). The
   first draft would have left `ForecastService`'s three in-memory caches running
   alongside the repository — a second source of truth, which is the problem this
   ADR exists to solve. Added: a standing delete-as-you-go rule, cache deletion
   as a Phase 5 correctness guard, and Phase 9 as a sweep.

8. **Four drift risks the plan did not cover** (raised by Jerson asking whether
   it was actually complete). Storage unit was unspecified while `fetch` stamps
   the *fetching user's* preference; derived values are implemented twice
   (`categoryIndexFor()` server-side, classification client-side); cached entries
   carry no schema version although Phase 3 changes the payload shape; and
   overlapping server runs could write an older run over a newer one. All four
   would have produced exactly the divergence this ADR exists to remove — three
   of them silently. Added as decisions 14–16 with guards in Phases 2, 3 and 6.

   *Checked and clear:* the map search widget displays place categories from
   geocoding, not flow values, so it is not a value surface and needs no
   migration.

9. **An independent agent review is now the final guard of every phase** (asked
   for by Jerson). Specified in *The review gate*: a fresh agent, given the
   guards and the diff but deliberately **not** a summary of the work, verifying
   each guard independently and adversarially. `CANNOT VERIFY` counts as a
   failure, and the reviewer reports without fixing.

   Writing it surfaced a numbering bug in this document — Phase 3's guards ran
   `9, 11, 12, 13, 10` because a later insertion landed before an earlier one.
   Fixed, and all ten phases are now verified contiguous. Fitting, for a gate
   whose purpose is that the author is the worst judge of their own work.

**Correction to an earlier claim.** During discussion it was suggested that
routing through our cloud would move `nwmApiKey` out of the app. **It does not.**
Non-favourite reaches keep the live path, and that path fetches return periods
from `nwm-api.ciroh.org` with the key — so it stays client-side unless
non-favourite return-period calls are also proxied, which is not currently
proposed.

## Open and unverified

- **Probe interval.** Hourly is the recommended default; Phase 0 confirms or
  corrects it.
- **Atomic publication.** 8/8 reaches agreed in one sample. Phase 3 guard 3 is
  designed so the answer does not matter.
- **Access distribution.** Whether non-favourite browsing ever shows enough
  overlap to justify caching is unmeasured; decision 6 says no at current scale.
- **Trimmed payload size.** The ~6× reduction from storing only `mean` is an
  estimate from the 156 KB measurement, not a measured result.
