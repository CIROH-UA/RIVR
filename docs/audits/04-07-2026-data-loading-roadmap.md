# RIVR Data Loading & API Resilience Roadmap
**Date:** April 7, 2026
**Based on:** `04-07-2026-data-loading-audit.md`

---

## Overview

Five phases to improve perceived performance, API resilience, and data transparency. Each phase is independently shippable and builds on the previous one.

**Guiding principles:**
- Don't architect around a temporary server bug — build resilience that helps regardless
- Reduce perceived wait, not just actual wait
- Be transparent about where data comes from and why it might be missing
- Each phase should be testable in isolation

---

## Phase 1 — API Fallback for Empty Filtered Responses ✅
**Completed:** April 7, 2026
**Audit findings:** #1 (broken filter), #6 (no fallback), #7 (short range single point of failure)
**Effort:** Small-Medium
**Files:** `noaa_api_service.dart`, `config.dart`, `config.template.dart`

### Goal
When **any** `?series=` filtered request returns 200 but empty data arrays, fall back to the unfiltered endpoint and extract the relevant section. This applies to short range, medium range, and long range equally — any series could be affected.

### Tasks

- [x] Add `_fetchUnfilteredForecast(reachId)` method — hits endpoint without `?series=`, 30s TTL in-memory cache via `_UnfilteredCacheEntry`
- [x] Add `_isForecastSectionEmpty()` helper — checks all sub-keys (series, mean, memberN) for empty data arrays
- [x] Add `_seriesToSectionKey()` — maps `short_range` → `shortRange`, etc.
- [x] Update `fetchForecast()` — detects empty sections, logs warning, falls back to unfiltered
- [x] `fetchCurrentFlowOnly()` inherits fallback (delegates to `fetchForecast('short_range')`)
- [x] `fetchAllForecasts()` now uses unfiltered endpoint as primary, filtered as fallback
- [x] Added `getStreamflowUrl()` to `config.dart` and `config.template.dart`
- [x] 7 new unit tests: no-fallback path, medium/short fallback, cache reuse, both-empty graceful, fetchAllForecasts unfiltered primary, fetchAllForecasts filtered fallback
- [x] Filtered `?series=` remains primary path — auto-uses faster filtered when NOAA fixes the filter

### Acceptance criteria
- All three forecast types load reliably regardless of `?series=` filter status
- Short range failure triggers fallback — overview page still shows current flow
- If both filtered and unfiltered fail, existing graceful degradation applies
- Fallback doesn't double the request count when multiple series fail (shared unfiltered cache)

---

## Phase 2 — Per-Section Loading States in the UI
**Audit findings:** #3 (global loading state), #4 (no data transparency)
**Effort:** Medium
**Files:** `reach_data_provider.dart`, forecast display widgets

### Goal
Each forecast section (short range, medium range, long range, return periods) has its own loading/loaded/error/empty state. Users see content building up progressively instead of one long wait followed by everything at once.

### Tasks

- [ ] Define a `SectionLoadState` enum: `loading`, `loaded`, `empty`, `error`, `unavailable`
- [ ] Add per-section state tracking to the provider (e.g., `Map<String, SectionLoadState>`)
- [ ] Update forecast tab/card widgets to show section-specific loading indicators
- [ ] Design and implement "empty" state messaging per section (see Phase 3 for content)
- [ ] Add subtle transition animations when sections populate (fade-in or slide, keep it light)
- [ ] Ensure section loading indicators match the Cupertino design language (use `CupertinoActivityIndicator` sized per section)

### Acceptance criteria
- Short range chart appears as soon as short range data is available, independent of other sections
- Medium/long range tabs show their own loading state
- Return period badge shows loading → loaded independently
- No regressions in overall load-to-interactive time

---

## Phase 3 — Transparent Data Source Messaging
**Audit findings:** #4 (no transparency), #5 (empty vs. no coverage)
**Effort:** Small-Medium
**Files:** Forecast display widgets, new shared widget for data messaging

### Goal
When a section has no data, tell the user *why* in plain language. Differentiate between server issues and no coverage. Build trust by being upfront about where data comes from.

### Tasks

- [ ] Differentiate error types at the API layer:
  - `unavailable` — HTTP 503, reach not covered by NWPS (permanent for that reach)
  - `emptyResponse` — HTTP 200 but data arrays empty (likely transient server issue)
  - `timeout` — request timed out
  - `error` — other HTTP errors
- [ ] Create a shared `DataSourceMessage` widget that shows contextual messaging:
  - **Loading:** "Fetching [short-range/medium-range/long-range] forecast from NOAA National Water Model..."
  - **Empty (transient):** "The NOAA National Water Model forecast is temporarily unavailable for this section. This usually resolves on its own — try refreshing in a few minutes."
  - **Unavailable (no coverage):** "This reach does not have [forecast type] coverage in the National Water Model."
  - **Timeout:** "The forecast server is responding slowly. Pull down to retry."
  - **Error:** "Something went wrong loading this forecast. Pull down to retry."
  - **Short range empty (special case):** When the primary current-flow source is unavailable, show "Current flow data is temporarily unavailable from the NOAA National Water Model. Checking other forecast sources..." — then if medium/long range provides a value, update to show that with a note like "Current flow estimated from [medium-range] forecast."
- [ ] Add a small, unobtrusive "Data: NOAA National Water Model" attribution label on forecast sections (helps users understand the source)
- [ ] Write widget tests for each message state

### Acceptance criteria
- Users never see a blank section with no explanation
- Transient server issues are communicated as temporary with a retry suggestion
- Permanent no-coverage is communicated differently from transient failures
- Attribution builds trust without cluttering the UI

---

## Phase 4 — Progressive (Non-Blocking) Data Loading
**Audit findings:** #2 (phase gates block on slowest), #7 (redundant re-fetch)
**Effort:** Medium-Large
**Files:** `forecast_service.dart`, `reach_data_provider.dart`

### Goal
Fire all data requests in parallel at the start and notify the UI as each one resolves. No phase gates. The provider holds a `ForecastResponse` that grows incrementally.

### Tasks

- [ ] Refactor the provider to manage a mutable `ForecastResponse` that starts empty and gets fields populated as futures resolve
- [ ] Replace the sequential Phase 1 → 2 → 3 chain with a single `loadAllData(reachId)` method that fires all requests independently:
  ```
  loadAllData(reachId):
    fire fetchReachInfo()        → on done: merge reach, notifyListeners()
    fire fetchShortRange()       → on done: merge short range, notifyListeners()
                                   if empty → fallback already handled by Phase 1
                                   still empty → update current flow from medium/long when they arrive
    fire fetchReturnPeriods()    → on done: merge return periods, notifyListeners()
    fire fetchMediumRange()      → on done: merge medium range, notifyListeners()
                                   if short range was empty → recalculate current flow, notifyListeners()
    fire fetchLongRange()        → on done: merge long range, notifyListeners()
                                   if short+medium were empty → recalculate current flow, notifyListeners()
  ```
- [ ] Implement current-flow recalculation on each merge — `getCurrentFlow()` already has the `short → medium → long` priority chain. After each section merges in, re-run it. If the result changes (e.g., medium range arrives and short range was empty), notify the UI so the current flow display updates.
- [ ] Keep `ForecastService` methods as-is — the provider becomes the orchestrator of parallelism, the service stays as the data-fetching layer
- [ ] Add request cancellation — if user navigates to a different river while requests are in-flight, cancel pending requests (use the existing generation-based cancellation pattern)
- [ ] Remove the Phase 3 re-fetch of short range (it's already loaded)
- [ ] Update `loadOverviewData`, `loadSupplementaryData`, and `loadCompleteReachData` to delegate to the new parallel approach, or deprecate them if no longer needed
- [ ] Unit test: verify that each section's `notifyListeners` fires independently
- [ ] Unit test: short range empty + medium range arrives → current flow updates from medium range
- [ ] Unit test: all series empty → UI shows transparent messaging, no crash
- [ ] Integration test: simulate one slow request and verify other sections render without waiting

### Acceptance criteria
- Reach name/location appears within 1-2s (reach info is small and fast)
- Short range chart appears as soon as short range resolves, regardless of medium/long
- Medium and long range tabs populate independently
- If short range is empty, current flow updates automatically when medium or long range arrives
- If all series are empty, the UI shows transparent messaging (Phase 3) — not a blank page
- Navigating away cancels in-flight requests
- Total data-complete time is same or better than current (fewer total requests)

---

## Phase 5 — Stale-While-Revalidate Caching
**Audit findings:** Related to #2 (perceived performance)
**Effort:** Medium
**Files:** `forecast_service.dart`, `reach_cache_service.dart`

### Goal
For previously visited rivers (especially favorites), show cached data immediately and refresh in the background. User sees content in <100ms for any river they've visited before.

### Tasks

- [ ] Extend the cache to store the full `ForecastResponse` (not just `ReachData`) with a timestamp
- [ ] On river tap: if cached response exists (even if stale), return it immediately to the UI
- [ ] Simultaneously fire background refresh requests
- [ ] When fresh data arrives, merge it into the displayed response and notify — UI updates smoothly
- [ ] Add a subtle "Last updated X minutes ago" indicator when showing stale data
- [ ] Add a visual refresh indicator (e.g., thin progress bar at top) while background refresh is in progress
- [ ] Configurable staleness threshold (e.g., show cached if < 30 min old, force fresh if > 30 min)
- [ ] Ensure unit changes invalidate the forecast cache (flow values are unit-dependent)

### Acceptance criteria
- Tapping a previously visited river shows data in <200ms
- Background refresh completes transparently
- User can distinguish fresh data from stale data (subtle indicator)
- Favorites list loads near-instantly with cached data
- Cache invalidation on unit change works correctly

---

## Sequencing

```
Phase 1 (API fallback)          ← Fixes the immediate data-missing problem
  │
  ▼
Phase 2 (Per-section loading)   ← UI foundation for progressive display
  │
  ▼
Phase 3 (Data source messaging) ← Builds on Phase 2's section states
  │
  ▼
Phase 4 (Progressive loading)   ← Biggest perceived performance gain
  │
  ▼
Phase 5 (Stale-while-revalidate) ← Polish for returning users
```

Phases 1-3 can each be completed in a single session. Phase 4 is the most involved and benefits from having Phases 2-3 in place (the UI is already set up for per-section updates). Phase 5 is an enhancement that can wait until the core loading path is solid.

---

## Risk Notes

- **NOAA API stability:** The `?series=` filter may start working again at any time. Phase 1's fallback handles both states. Don't remove the filtered path — it's faster when it works.
- **Any series can fail:** The audit caught medium/long range failing, but short range could fail the same way. Every code path that fetches a specific series must have the same fallback logic. Don't special-case — the empty-detection + unfiltered-fallback should be generic across all series types.
- **Short range outage cascades:** If short range is empty and the fallback also returns empty, the overview page needs to degrade gracefully — show reach info (name, location, map) without current flow, and clearly communicate the data gap. The page must not appear broken.
- **Provider complexity:** Phase 4 increases the provider's responsibility. Keep the merge logic simple — each request writes to its own field, no cross-section dependencies. The current-flow recalculation on each merge is the one cross-cutting concern — keep it as a single `_recalculateCurrentFlow()` call after every merge.
- **Cache staleness:** Phase 5's stale-while-revalidate must respect unit changes. A cached CFS response shown to a user who switched to CMS would be wrong. The existing `clearUnitDependentCaches()` pattern handles this.
- **Testing:** Each phase should include tests for the new behavior before merging. The existing 509-test suite should not regress. Specifically, add test cases for the "all series empty" scenario — this is the worst case and should not crash or show a blank page.
