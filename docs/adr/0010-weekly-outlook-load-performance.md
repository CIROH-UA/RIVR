# 0010 — The Weekly Outlook takes minutes to load

**Status:** Problem measured, options ranked, nothing implemented
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

## Not yet verified

The per-favourite breakdown above is derived from reading timeout constants,
retry counts, and call graphs — **no instrumented timing has been taken on
device.** The 165-second Firestore observation bounds the total but does not
attribute it. Before choosing between A and D, log elapsed time per row and per
call so the dominant cost is measured rather than inferred; these pipelines have
a long history in this repo of failing in ways that reading did not predict.
