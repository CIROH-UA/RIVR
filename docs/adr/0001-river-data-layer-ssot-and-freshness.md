# ADR 0001 — River data layer: single source of truth, per‑source caching, and push‑driven freshness

- **Status:** Accepted (2026-07-10)
- **Date:** 2026-07-10
- **Deciders:** Jerson Garcia (lead)
- **Supersedes / relates to:** `docs/geoglows-data-architecture.md`, `docs/internal/forecast-latency-plan.md`
- **Context source:** three investigations (data/cache architecture, favorites+notification machinery, external freshness/caching patterns) run 2026-07-10.

## Context and problem

RIVR fetches river data from two sources — NWM (NOAA, via `NoaaApiService` → `ForecastService`) and GEOGLOWS (via `GeoglowsApiService` → Cloud Function proxy). The current design has structural problems that will get worse as we add sources and lean on push notifications:

1. **Duplicate fetches.** Tapping a reach loads data in the map bottom sheet, then the forecast page loads it *again*. For GEOGLOWS this is two full proxy round‑trips (each a ~16 s S3 read ± cold start) for identical data, because `GeoglowsApiService` has **no cache at all**.
2. **No single source of truth.** Caches live in many places keyed inconsistently (`ForecastService` in‑memory maps, `ReachCacheService`, `ForecastCacheService`, provider‑scoped session caches, favorites' own `_sessionData`). A value fetched by one surface does not reliably feed the others.
3. **Unit conversion happens *before* caching** (both sources), so a cached value is in the wrong unit after the user flips CFS/CMS. The app compensates by *clearing* caches on every unit flip — fragile, and it leaves live providers stale.
4. **Cache keys are `reachId`‑only**, not `(source, reachId)` — sources would collide if they ever shared an id namespace.
5. **Not extensible.** Routing is hard‑coded `if (source.isGeoglows)`. `ForecastResponse` is NWM‑shaped, so GEOGLOWS had to fork a parallel model/provider/page. A third source repeats the fork and edits every `if/else`.
6. **Freshness is coarse and disconnected from notifications.** Favorites refresh only on app‑open or pull‑to‑refresh; there is no background refresh. The Cloud Functions already run 4×/day, fetch NWM, compute return‑period threshold crossings, and send an FCM `data` payload containing `forecastFlow`/`threshold`/`returnPeriod` — but **the app ignores those values**; the notification pipeline and the displayed values are entirely disconnected.

We also confirmed the hard platform reality: **reliable client‑side background polling is impossible.** iOS `BGAppRefreshTask` gives ~30 s on an OS‑decided budget (and never runs when force‑quit); Android `WorkManager` floors at 15 min and is deferred by Doze. "Refresh every 15 min in the background" is not achievable — freshness must be **server‑driven via push**.

## Decision drivers

- One network response should be cached once and reused by every widget that needs it.
- Widgets that must stay current should update automatically when fresher data arrives (foreground revalidation *or* push).
- Freshness cadence should follow each source's real publish schedule, not an arbitrary global timer.
- Adding a new data source must be "implement an interface + register it," not a reshape.
- Stay within the existing Flutter stack (Provider/ChangeNotifier + GetIt + the numbered clean‑architecture layers). No new state‑management dependency mid‑project.
- Correctness under unit changes, offline, and app restarts.

## Decisions

**D1 — A single `RiverDataRepository` is the source of truth.** Every read of reach/forecast/current‑flow data routes through it. It owns caching, deduplication, freshness/revalidation, and DTO→domain mapping. UI never calls a source API or a cache directly; it observes the repository.

**D2 — Cache key = `(source, reachId, product)`; store native units; convert at read.** Products are e.g. `analysis`, `shortRange`, `mediumRange`, `longRange`, `returnPeriods`, `geoglowsForecast`. Values are stored in **native m³/s** with `fetchedAt` + `validUntil`. Conversion to the user's display unit happens at **read time** via `FlowUnitPreferenceService`. This eliminates the clear‑on‑unit‑flip logic entirely — flipping units just re‑reads the same cache. Two tiers: in‑memory (instant fan‑out) backed by disk (survives restarts). Reuse the existing `getWithFreshness`/`store`/`CacheResult`/`CacheFreshness` contracts and JSON disk mechanism — only the key gains a `source` dimension.

**D3 — Freshness = publish‑aligned TTL + stale‑while‑revalidate (SWR).** Each entry's `validUntil = nextPublishTime(source, product)`. Before `validUntil`: serve cached, **no network**. After: serve the stale value immediately, revalidate in the background, and notify all listeners when fresh data lands. Publish alignment (not a flat TTL) is correct because our sources publish on fixed, known cadences.

| Source / product | Publishes | `validUntil` |
|---|---|---|
| NWM analysis / short‑range | hourly | top of next hour + small skew |
| NWM medium / long‑range | every 6 h | next 6‑hour cycle |
| GEOGLOWS forecast | daily 00Z | next 00Z |

**D4 — Sources are pluggable behind `IRiverDataSource`, resolved through a `SourceRegistry`.** Each source implements one interface (`fetchReach`, `fetchForecast(product)`, `fetchCurrentFlow`, returning native‑unit DTOs) and **declares its supported products and publish cadence as data**. A `Map<ForecastSource, IRiverDataSource>` registered in GetIt replaces every `if (source.isGeoglows)`. The repository and router resolve `source → dataSource`; the cache/freshness engine reads cadence from the source and is otherwise source‑agnostic.

**D5 — Cross‑widget observation uses Flutter‑core primitives, not a new library.** The repository exposes an observable per cache key (a keyed registry of `ValueNotifier`/`Listenable`, or a broadcast `Stream`). Existing providers become thin subscribers. We stay on Provider/ChangeNotifier + GetIt — no Riverpod/Bloc migration.

**D6 — Freshness delivery is server‑push‑driven; client background refresh is best‑effort only.** The Cloud Functions already detect publishes/threshold crossings; they send FCM **data** messages carrying the fresh values. The app's background/data handler writes the payload into the shared cache → the repository notifies → the UI is current without the app being opened. Where it matters (flood threshold), also send a user‑visible notification. Optional `WorkManager`/`BGAppRefreshTask` may *supplement* freshness but nothing depends on it.

**D7 — The target domain model is source‑agnostic (`RiverForecast` with a products/capabilities map); we reach it incrementally.** Long term, retire the `ForecastResponse` vs `GeoglowsForecast` fork so a source declares which products it provides and the UI renders from a uniform model. Short term, keep per‑source models behind adapters so we can unify the *plumbing* (cache, repository, freshness, registry — where the bugs live) before unifying the *model* (the largest, riskiest change), which lands last.

**D8 — Reuse, don't rewrite, the cache layer.** Extend the existing disk/in‑memory caches and their contracts with the `source` key dimension and native‑unit storage. Do not introduce a new persistence engine (e.g. Room‑style DB) at this time.

## Alternatives considered

- **Client background polling (WorkManager/BGTask every N min).** Rejected — OS limits make it unreliable (D6). Kept only as an opportunistic supplement.
- **Keep parallel per‑source stacks (status quo).** Rejected — the source of the duplication, unit‑flip bugs, and non‑extensibility (D1, D4).
- **Adopt Riverpod/Bloc for the observable layer.** Rejected — mid‑project churn and risk; Provider/ChangeNotifier is sufficient (D5).
- **Convert units before caching (status quo).** Rejected — forces cache clearing on every unit flip and blocks a single shared cache (D2).
- **One global TTL.** Rejected — sources publish on different cadences; publish‑aligned TTL is both fresher and cheaper (D3).
- **Big‑bang rewrite to the unified domain model first.** Rejected — highest‑risk change; sequence it last behind adapters (D7).

## Consequences

**Positive**
- Duplicate fetches disappear structurally (one key → one in‑flight request → all listeners).
- Widgets bound to a key auto‑update on revalidation or push — directly solving "values that must stay current."
- Unit flips need no cache clearing (native storage + convert‑at‑read).
- Freshness follows real publish cadence: fewer wasted requests, and genuinely fresh data.
- Adding a source = implement `IRiverDataSource` + one registry entry.
- The server work we already pay for (threshold detection, 4×/day) finally reaches the UI.
- Offline‑first: cached values render instantly on cold start.

**Negative / risks**
- Real upfront refactor; touches the data layer broadly. Mitigate with staged, independently shippable slices and integration tests at each stage.
- Cache‑invalidation correctness is subtle (publish skew, timezone/UTC for GEOGLOWS 00Z, DST for NWM's Denver‑time server). Encode `validUntil` in UTC and test boundaries.
- The unified domain model (D7) generalizes the whole detail‑page/section machinery — the largest change; staged last.
- Silent/data push has delivery caveats (throttled; not delivered when force‑quit) — pair with visible pushes for anything critical; treat push freshness as an enhancement over the publish‑aligned TTL, not a replacement.

## Target architecture (sketch)

```
UI (widgets/providers)  ──observe──►  RiverDataRepository  ── SSOT
                                        │  cache: (source, reachId, product) → { nativeValue, fetchedAt, validUntil }
                                        │  read: fresh? serve : SWR(serve stale + revalidate + notify)
                                        │  convert native → display unit at read
                                        ▼
                               SourceRegistry: Map<ForecastSource, IRiverDataSource>
                                        ├─ NwmDataSource     (products: analysis/short/medium/long/returnPeriods; cadence: hourly / 6h)
                                        └─ GeoglowsDataSource (products: forecast/ensemble; cadence: daily 00Z)

FCM data push ("new publish" / "threshold crossed on reach X, flow=Y")
        └─► background handler ─► repository.ingest(payload) ─► cache write ─► notify listeners
```

## Development plan (logical, dependency‑ordered)

**Execution note (2026-07-10):** on acceptance we optimize the order for clean architecture — **build bottom‑up, contracts/vocabulary first**, so every later layer depends only on stable abstractions. The throwaway "Stage 0" GEOGLOWS service‑level cache is **dropped**; the double‑fetch is fixed properly when UI migrates onto the repository (a cache inside the source is exactly the scattered caching we are removing). Executed steps:

1. **Data‑layer vocabulary** — `ForecastProduct`, `RiverDataKey(source, reachId, product)`, `CacheFreshness` value types + unit tests. *(done 2026-07-10; analyze clean, 14 tests pass)*
2. Shared `RiverDataCache` (memory+disk, native units, keyed by `RiverDataKey`, publish‑aligned freshness).
3. `IRiverDataSource` + `SourceRegistry`; NWM & GEOGLOWS adapters declaring products + cadence.
4. `RiverDataRepository` SSOT — SWR read logic, convert‑at‑read, observable fan‑out.
5. Migrate UI surfaces onto the repository — GEOGLOWS first (kills the double‑fetch), then NWM, then favorites.
6. Push → cache freshness (wire the FCM `data` payload the server already sends).
7. Unified source‑agnostic domain model (retire the `ForecastResponse`/`GeoglowsForecast` fork).

The original ADR staging (kept below for rationale/effort) maps onto these: old Stage 1 → new 1–2, old Stage 2 → new 4–5, old Stage 3 → new 3, old Stage 4 → new 6, old Stage 5 → new 7.

Each stage is independently shippable and leaves the app working. Hour ranges are rough (evenings/weekends).

- **Stage 0 — GEOGLOWS quick cache (tactical, ~1–2 h).** Add a publish‑aligned TTL memo inside `GeoglowsApiService` (native‑unit‑aware). Kills the double proxy fetch now; independent of the rest. *Unblocks the pain immediately.*
- **Stage 1 — Shared cache foundation (~6–10 h).** Re‑key caches to `(source, reachId, product)`; store native units + `fetchedAt` + `validUntil`; convert at read. Migrate NWM read/write paths; behavior unchanged. *Removes the unit‑flip clearing; sets up SSOT.*
- **Stage 2 — `RiverDataRepository` SSOT + observation (~10–16 h).** Introduce the repository with SWR read logic and observable fan‑out; route every read (bottom sheet, forecast page, favorites) through it; retire ad‑hoc/provider caches. *Duplication gone structurally; "always‑updated" widgets solved.*
- **Stage 3 — `IRiverDataSource` + `SourceRegistry` (~8–12 h).** Refactor NWM + GEOGLOWS behind the interface; sources declare products + cadence (drives real publish‑aligned `validUntil`); replace all `if (isGeoglows)` routing. *Now extensible; a new source "just joins."*
- **Stage 4 — Push → cache freshness (~6–10 h).** Wire the FCM `data` payload the server already sends into `repository.ingest`; add silent/data‑message handling and a lightweight server "new publish" ping; reconcile the server's *max‑forecast* metric vs the card's *current* metric. *Freshness without opening the app.*
- **Stage 5 — Unified domain model (~10–16 h, optional/last).** Retire the `ForecastResponse`/`GeoglowsForecast` fork via a capability‑based `RiverForecast`; remove adapters; generalize the detail pages. *Full extensibility; highest risk, so last.*

**Recommended sequencing:** ship **Stage 0** immediately; then **1 → 2 → 3** as the core rearchitecture (this is where all six problems above get fixed except the model fork); then **Stage 4** to light up notification‑driven freshness (high value, cheap because the server already computes it); defer **Stage 5** until the data layer has earned it. Total ≈ 40–65 h across the effort.

## Open questions

- GEOGLOWS ensemble/return‑period products: fold into the same cache/registry now, or when the ensemble‑fan UI lands?
- Server "new publish" detection: piggyback on the existing 4×/day cron, or add a lighter publish‑watch trigger?
- Do we want a home‑screen widget later? If so, D6's push‑to‑`reloadTimelines` path should be designed into Stage 4.
