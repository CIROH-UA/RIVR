# 0010 — The Weekly Outlook takes minutes to load

**Status:** Superseded in scope by **ADR 0011** (centralized cloud data layer), which absorbs Option G and the server-store decisions. Phases 1-2 here (per-row rendering, bounded wait) remain valid as UI resilience. Nothing implemented.
**Related:** ADR 0001 (river data layer SSOT), ADR 0008 (push notifications)

## Symptom

Tapping the Friday digest on build 2026.1.3+561 routes correctly to the Weekly
Outlook, then shows a white screen with a spinner for **three to five minutes**
before any river appears. Reported from device, 2026-08-21.

**Corroborated independently.** `weeklyDigestsSinceOpen` resets only inside
`_recordOutlookOpen`, which runs after `buildOutlook` returns. Polling Firestore
during that same tap showed the reset landing at **t≈165s** — matching the
report without relying on it.

This is not the 8-second grace period added in 561. That gates only the empty
state; the spinner after it is `buildOutlook` doing network work.

## Measured — where the time goes

Per NWM favourite, `WeeklyOutlookService._buildNwmRow` calls
`ForecastService.loadCompleteReachData`, which:

1. reads reach info + return periods (cached after first use), then
2. **always** calls `fetchAllForecasts` — Step 5 is commented *"Always get fresh
   forecast data"*, with no cached-first path.

`fetchAllForecasts` issues one unfiltered request at `_longTimeout` = **30s**
with `maxRetries = 2` and backoff delays of 1s and 2s:

> worst case before the fallback even begins: 30 + 1 + 30 + 2 + 30 = **93 s**

On failure it falls back to `_fetchAllForecastsFiltered`, which issues several
more requests, each with its own retry ladder. The server-side digest run on the
same reaches logged `Request timeout after 30000ms` retries at attempts 1 and 2,
so this ladder is being climbed in practice, not theoretically.

`buildOutlook` wraps the rows in `Future.wait`, so **the slowest favourite gates
the entire page**. Three favourites, one of them on the retry ladder plus the
filtered fallback, reaches minutes.

### Five structural causes, in rough order of cost

1. **It fetches everything and needs almost nothing.** The outlook renders one
   series — the medium-range mean over seven days — but `loadCompleteReachData`
   pulls short, medium, long, and analysis-assimilation for every favourite.
2. **Nothing renders from cache.** That path always goes to the network. The app
   already holds recent flow data for these very reaches (the favourites cards
   show it), and `_forecastCacheService.store` is written to but never read here.
3. **All-or-nothing.** `Future.wait` is a barrier. One slow reach hides two fast
   ones that are ready to draw.
4. **The retry ladder has no overall deadline.** Nothing bounds total wait, and
   the UI cannot distinguish "slow" from "hung".
5. **Reverse-geocoding is awaited inline.** `_locationLabel` runs per row inside
   `_assemble`, adding latency to a label that is decoration, not data.

**The GEOGLOWS path is already better.** `_buildGeoglowsRow` goes through
`_riverData.read(...)` — the SSOT repository from ADR 0001. Only the NWM path
still uses the old `ForecastService`.

## Measured — the fix is largely built already

`RiverDataRepository.read()` implements true stale-while-revalidate:

| behaviour | line |
|---|---|
| fresh → return with no network at all | `river_data_repository.dart:39-40` |
| stale → return cached immediately, revalidate in background | `:44-52` |
| in-flight dedup so parallel rows share one request | `:78-82` |

`NwmDataSource` exists (`nwm_data_source.dart:37`) and **is registered in DI**
(`forecast_dependencies.dart:62`). So NWM already has a working SSOT data source;
the Weekly Outlook simply does not call it.

**This is ADR 0001's outstanding Step 7** — retire the
`ForecastResponse`/`GeoglowsForecast` fork so NWM surfaces read through the
repository — and equivalently ADR 0002's deferred Stage 2b. Both were parked as
"not required for the Step 1–5 win", and ADR 0002 gated Stage 2b on "the next
detail-carrying source". **This page is a second, sharper trigger: not a new
source, but a user-visible multi-minute stall on the path a push notification
sends people down.**

Note the Weekly Outlook is not a *detail* page — it needs one series, not the
short/medium/long fork. So it may not require the full Step 7 migration to move
onto the repository; that is worth establishing before scoping the work.

## Measured — the server already computed all of this

`weekly-digest.ts` builds a `DigestRow` per favourite *seconds before sending the
push*: name, peak flow, peak day, trend, category index. Compared against what
`OutlookRow` renders:

| OutlookRow needs | server has it? |
|---|---|
| `displayName`, `peakFlow`, `peakTime`, `trend`, `category`, `categoryIndex` | **yes**, already computed |
| `sparkline` | in memory (peak is derived from it), simply not persisted |
| `location` | not server-side, but the app persists `favoriteLabels` to the user doc |

So the notification path recomputes on a cold, slow mobile connection exactly
what a warm server finished moments earlier and threw away.

## Options

Ranked by value for effort. Not mutually exclusive; A+C+E is the likely shape.

**A. Route the NWM row through the SSOT repository.** Mirror
`_buildGeoglowsRow`. Cached favourites render with no network; stale ones render
instantly and refresh underneath. *Largest win, lowest risk — the machinery is
built, registered, and already in use by the other source.* (Related to ADR 0001
Step 7 but, per the section below, does not require it.)

**B. Fetch only the medium-range mean.** Stop calling `loadCompleteReachData` for
a page that uses one series. Cuts payload and parse cost even on a cache miss.

**C. Render rows as they arrive.** Replace the `Future.wait` barrier with
per-row completion so two fast rivers are not held hostage by one slow one.

**D. Persist a server-computed snapshot at digest time.** Write the rows (plus
sparkline) to Firestore when the Friday push is sent; the app renders instantly
on tap and refreshes in the background. *Best possible cold-start latency —
one Firestore read — and it makes the notification path structurally fast rather
than incidentally fast. Costs a schema and a write.*

**E. Bound the wait.** An overall deadline with partial results beats an
unbounded spinner. Whatever else is done, the page should never show an
uninformative white screen for minutes.

**F. Move geocoding off the critical path.** Render the row, fill the label when
it arrives.

## Recommendation

**A + C + E** as the immediate fix — they are small, they use machinery that
already exists, and together they turn the common case (cached favourites) into
an instant render and the worst case into a bounded one with partial results.

**D** afterwards, if the notification path specifically needs to be fast on a
cold cache — which is precisely the case a Friday-morning digest creates.

**B** is worth doing whenever the NWM path is touched, but is subsumed by A if
the SSOT source already requests narrowly.

## Option G — a server-maintained store for favourited reaches

Raised by Jerson, 2026-08-21: *"why isn't it better to just have a place in the
cloud where all the streams that are added as favorites are stored and recorded,
and make the app read from there only and cache until the storage gets new
values?"*

This generalises option D from "a snapshot at digest time" to "the favourites
data layer". The research below says it is the strongest option available, and
that most of it already exists.

### Measured — the fan-out already runs, and already throws the data away

`checkRiverAlerts` runs **four times a day** — four Cloud Scheduler jobs at
00/06/12/18 America/Denver — and calls `batchFetchReachData`, which per distinct
favourited reach fetches, in parallel:

- `getForecast` → **short range + medium range** (`ReachData.forecast`)
- `getReturnPeriods`
- `getRiverName`

It evaluates alerts against that and **discards it**. Option G is not a new
pipeline; it is persisting a fan-out that is already paid for.

### Measured — the scale is bounded by favourites, not by the network

Counted from Firestore, 2026-08-21:

| | |
|---|---|
| users | 18 |
| users with ≥1 favourite | 14 |
| favourite rows | 36 |
| **distinct reaches to fetch** | **29** |

29 reaches × 4 runs/day ≈ **116 fetches/day, already happening**. Persisting adds
roughly the same number of Firestore writes. Free quota is documented at 50,000
reads and 20,000 writes per day, so the volume is ~170× below the write
threshold. *(Caveat: that quota table is documented for projects without billing
enabled and RIVR is on Blaze; the per-write list price could not be extracted —
the pricing page truncates. The conclusion is insensitive to this, being three
orders of magnitude clear.)*

> **MEASURED BASELINE (2026-08-24).** The 116/day above is a *projection* of
> what persisting would add, not a reading. For reference, actual Firestore
> traffic before that work ships — Cloud Monitoring,
> `firestore.googleapis.com/document/{read,write}_count`, 2026-08-19 → 08-24 —
> is **93 reads/day and 57 writes/day**, 0 deletes. So the projection sits
> inside the same order of magnitude as today's whole workload, and the
> headroom is wider than assumed here: **~535× on reads, ~350× on writes**
> against the documented free tier. Nothing in this entry needs revising.
>
> **This baseline PREDATES the ADR 0011 Phase 4 store**, which went live on
> 2026-08-25 and writes one document per followed reach per product whenever
> upstream advances (116 on its first run). Quote these numbers as "the app's
> own traffic before the store", not as current total usage — the store's
> share is reported separately by `storeRefreshHourly`'s own usage log.

**The scaling law matters more than today's number:** cost grows with *distinct
favourited reaches × cadence*, not with users and not with the 2.7M channel
network. Overlap between users is free. This is the same economics as the flood
tileset, which the project already runs successfully.

### Measured — cadence: 4×/day is exactly right for the broken page

NWM does not publish everything at one rate. From `NwmDataSource.validUntil`,
which is the in-repo authority:

| product | publishes | served from a 6-hourly store |
|---|---|---|
| **medium range** | every 6h (00/06/12/18Z) | **exact — no fresher data exists** |
| long range | every 6h | exact |
| return periods | static (30-day TTL) | trivially fine |
| short range / analysis | **hourly** | up to 6h stale |

**The Weekly Outlook reads medium range.** So for the page this ADR is about, a
6-hourly server store is not a compromise — it matches the model's own cadence.
Current flow on the favourites cards is the product that genuinely wants hourly,
and should stay on-demand.

### Corrected — the cron is aligned, contrary to a claim made earlier

An earlier assertion in discussion — that the Denver-scheduled cron is offset
from the UTC model cycles and would need re-aligning — is **wrong for most of the
year**:

| | cron fires (UTC) | vs cycles 00/06/12/18Z |
|---|---|---|
| Mar–Nov (MDT) | 06, 12, 18, 00 | **exactly on cycle** |
| Nov–Mar (MST) | 07, 13, 19, 01 | one hour after |

Eight months a year it is exactly aligned; the other four it fires one hour
*late*, which is the safe direction — the cycle has certainly published. If
anything the **MDT alignment is the riskier one**, since firing at cycle time
races publication; the client adds a 5-minute skew for precisely this reason
(`nwm_data_source.dart:34`). Any store built on this schedule should carry a
similar skew rather than being re-aligned.

### Trade-offs, stated honestly

**For:** instant render; works offline; NOAA's 30s×3 retry ladder moves to a
server where retries are free and invisible; one fetch serves every user sharing
a reach; and the app and the digest agree **by construction** — which is exactly
the class of divergence ADR 0002 exists to prevent.

**Against:**
1. **It cannot be the only path.** Users browse and search reaches they have not
   favourited; the client fetch stays for those. Option G shrinks the hot path,
   it does not delete it.
2. **A newly-added favourite is not in the store** until the next cycle — needs
   write-through on add, or the client path as fallback.
3. **It makes the backend a dependency for viewing data**, not just for
   notifications. A store outage must degrade to the client path, not to a blank
   page.
4. **Two computations of the same derived values** (category, trend, peak) unless
   the client reads them rather than recomputing — ADR 0002's problem returning
   in a new place.

### Effect on the plan

Option G does not invalidate the phases; it changes what they are for.

- **Phase 5 stops being conditional** and becomes the destination.
- **Phase 3 remains worth doing** — it is the fallback path when the store is
  cold, missing, or the reach is not a favourite.
- **Phases 1, 2 and 4 are unaffected.** Per-row rendering, a bounded wait and
  off-critical-path geocoding are UI resilience and matter whatever feeds them.
- **Phase 0 still comes first.** If measurement shows the medium-range fetch is
  the dominant cost, Option G is the answer and Phase 3 is the safety net; if the
  cost is elsewhere (geocode, parse, return periods), the ordering changes.

**Measured — the retained payload is sufficient.** `ForecastData`
(`notification-service.ts:45`) is `values: Array<{value, validTime}>` — the full
point series, not extrema. Together with return periods and river name, that
covers every field `OutlookRow` needs except `location`, which the app already
persists as `favoriteLabels` on the user doc. So a store built from
`batchFetchReachData`'s existing output requires **no additional fetching** — the
sparkline and `peakTime` both derive from the series it already holds.

## What `_buildNwmRow` actually needs

Grounding for the plan below. The heavy `loadCompleteReachData` call is used for
exactly four things:

| needed | where it comes from today | cached product that already exists |
|---|---|---|
| `mediumRange['mean'].data` | full forecast fetch | `ForecastProduct.mediumRange` → `fetchForecast(id, 'medium_range')` |
| `reach.returnPeriods` | reach info fetch | `ForecastProduct.returnPeriods` |
| `reach.riverName` | reach info fetch | already falls back to `favorite.displayName` |
| `reach.latitude/longitude` | reach info fetch | already **prefers** `favorite.latitude/longitude` |

`NwmDataSource.fetch` implements both products with their own freshness windows
(`nwm_data_source.dart:94`, `:104`). So the outlook can be served by two narrow,
cached, deduplicated reads — and **this does not require ADR 0001's Step 7**,
because the outlook is not a detail page and never touches the
short/medium/long `ForecastResponse` fork.

Options A and B therefore collapse into a single change.

---

# The plan

**Target, and the definition of done for the whole plan:**

| case | first row visible | all rows |
|---|---|---|
| warm cache (favourites opened recently) | < 1 s | < 2 s |
| cold cache, healthy network | < 5 s | < 10 s |
| cold cache, NOAA degraded | < 5 s (partial + honest state) | bounded, never unbounded |

**Never**, in any configuration: a featureless white screen for more than 10
seconds.

**A guard that passes against today's code is not a guard.** Every phase below
must include at least one test demonstrated to *fail* before the change and pass
after — the discipline that caught a fake guard in ADR 0009 phase 4 and was
applied again to the 561 race guards (6 of 7 verified failing first).

---

## Phase 0 — Measure before choosing

Everything in this ADR is inferred from constants and call graphs. No timing has
been taken. Phase 3 and Phase 5 are different-sized bets and the measurement
decides whether Phase 5 is needed at all.

**Build.** Temporary instrumentation: elapsed ms per row, per `read`/fetch, and
per phase of `_buildNwmRow`; log cache hit vs miss. Capture on device for
(a) warm cache, (b) cold cache after `flutter clean` + reinstall, (c) cold cache
with airplane-mode-then-restore to force the retry ladder.

**Gates.**
1. The dominant cost is named **with a number**, not a hypothesis — e.g. "medium
   fetch p50 = X s, return periods = Y s, geocode = Z s".
2. Warm-cache and cold-cache totals are both recorded, so Phase 3's improvement
   can be stated as a ratio rather than an impression.
3. If the measurement contradicts this ADR, **the ADR is corrected before any
   code is written.** The Disproven section is the expected outcome for at least
   one claim here.

---

## Phase 1 — Render rows as they arrive

**Problem.** `Future.wait` in `buildOutlook` is a barrier: three favourites, one
slow, nothing renders.

**Build.** Replace the barrier with per-row completion — the page holds a list
that fills in as each row resolves, ordered by newsworthiness once complete.
A failed row is dropped, not fatal.

**Gates.**
1. With one row resolving in 100 ms and another in 60 s, the fast row is on
   screen **before** the slow one resolves. Test with controlled delays.
2. A row that throws does not prevent the others from rendering.
3. Final ordering after all rows resolve is identical to today's.
4. Existing outlook tests still pass unchanged.

---

## Phase 2 — Bound the wait, and never show a bare spinner

**Problem.** No overall deadline; the UI cannot distinguish slow from hung.
Depends on Phase 1, because partial results are only possible once rows complete
independently.

**Build.** An overall deadline. On expiry: show whatever rows arrived, plus an
honest state for the rest ("Couldn't load 2 rivers — Retry"). Replace the bare
spinner with per-row skeletons naming the rivers being loaded, which the app
already knows from `favoriteLabels` before any network call.

**Gates.**
1. With the network black-holed, the page reaches a terminal, non-spinner state
   within the deadline. **This is the guard that directly answers the reported
   defect.**
2. With 1 of 3 rows timing out, the other two render and the third shows a retry
   affordance.
3. Retry re-requests only the failed rows.
4. The skeleton names real favourites, so the screen is never featureless.

---

## Phase 3 — Route the NWM row through the SSOT repository

**Problem.** The NWM row always hits the network and fetches four products for a
page that uses one. The GEOGLOWS row already does this correctly.

**Build.** Mirror `_buildGeoglowsRow`: read `ForecastProduct.mediumRange` and
`ForecastProduct.returnPeriods` through `IRiverDataRepository`. Take name and
coordinates from the favourite, which is already the fallback. Delete the
`loadCompleteReachData` call from this path only.

**Gates.**
1. A warm cache renders with **zero** network calls. Assert against a fake
   source that records requests — this is the whole point of the phase.
2. A stale cache renders immediately from cache and revalidates in the
   background.
3. Two favourites on the same reach issue **one** fetch (in-flight dedup).
4. Values are unchanged: peak, trend, category, sparkline identical to the
   `loadCompleteReachData` path for the same fixture. **Regression risk is the
   real danger here, not performance.**
5. **No other surface changes behaviour.** The map bottom sheet, favourites
   cards, and NWM forecast detail pages still use `ForecastService`; full suite
   green.
6. Measured against Phase 0's baseline: warm-cache render meets the target
   table.

---

## Phase 4 — Take geocoding off the critical path

**Build.** Render the row without `location`; fill the label when it resolves.

**Gates.**
1. A row renders while the geocode is still pending.
2. A geocode that never resolves leaves a usable row, not a spinner.
3. The label still appears when it does resolve.

---

## Phase 5 — Server-computed snapshot *(conditional)*

**Only if Phase 3 + Phase 0 show cold-cache render still misses the target.** A
Friday digest arrives precisely when the cache is coldest, so this may still be
needed even after Phase 3.

**Build.** `weekly-digest.ts` already computes name, peak, peak day, trend and
category per favourite, and holds the series it derived the peak from. Persist
those rows plus a sparkline to Firestore at send time; the app renders from one
read on tap, then revalidates through the repository.

**Gates.**
1. Tapping a digest renders rows before any forecast API call completes.
2. The snapshot is clearly stamped with its generation time and the UI says so —
   **a stale snapshot presented as live is worse than a slow page.**
3. A missing or malformed snapshot falls back to the Phase 3 path with no error
   shown.
4. Snapshot values match what the app computes for the same reach and run.
5. Firestore write cost is measured per digest run, not assumed negligible.

---

## Phase 6 — Prove it on device

Config review is not evidence; this repo's history is layers reporting success
while nothing worked.

**Gates.**
1. Timings retaken on device for all three Phase 0 scenarios and compared to
   baseline **in the same table**.
2. The originally reported journey — tap a Friday digest from a cold start —
   renders rivers within target, verified on a real iPhone.
3. `weeklyDigestsSinceOpen` still resets, proving the row build completed
   (the server-side check that worked in 561).
4. Android checked at least once; it shares this code path entirely.
5. Every number recorded with the build it came from.

---

## Sequencing and why

0 → 1 → 2 → 3 → 4 → (5) → 6.

Phase 0 first because Phases 3 and 5 are different-sized bets. Phase 1 before 2
because partial results require per-row completion. Phase 2 early because it
removes the *reported* symptom — an uninformative white screen — even before the
data gets faster, and it protects the degraded-network case permanently. Phase 3
is the actual fix and the largest win. Phase 4 is cheap cleanup. Phase 5 is
deliberately conditional; it adds a schema, a write path, and a staleness
question, and should not be paid for unless measurement says so.

**Phases 1, 2 and 3 are independently shippable** and each improves the page on
its own, so there is no long-lived branch.

## Not yet verified

The per-favourite breakdown above is derived from reading timeout constants,
retry counts, and call graphs — **no instrumented timing has been taken on
device.** The 165-second Firestore observation bounds the total but does not
attribute it. Before choosing between A and D, log elapsed time per row and per
call so the dominant cost is measured rather than inferred; these pipelines have
a long history in this repo of failing in ways that reading did not predict.
