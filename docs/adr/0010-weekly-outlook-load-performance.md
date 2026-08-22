# 0010 — The Weekly Outlook takes minutes to load

**Status:** Problem measured; six-phase plan with gates below; nothing implemented
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
instantly and refresh underneath. Closes ADR 0001 step 5b. *Largest win, lowest
risk — the machinery is built, registered, and already in use by the other
source.*

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
