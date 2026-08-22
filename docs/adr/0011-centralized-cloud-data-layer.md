# 0011 — Centralized cloud-backed data layer

**Status:** Specified, nothing implemented
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
   hypothesis.
4. Upstream failure rate is measured over the week, so the 11% in this ADR is
   confirmed or corrected.
5. Which reaches are actually opened is logged, so decision 6 — that caching
   non-favourites is not worth it — rests on data rather than on an argument
   about probability.
6. **Any claim in this ADR contradicted by the data is corrected here before code
   is written.** At least one correction is expected.

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
   the fetch (`reach_details_bottom_sheet.dart:434`), so the sheet cannot be
   titled instantly.* `fetchReachInfo` is the cheapest call at ~0.5 s median and
   0.5 KB; it must be prioritised so the title lands first.
2. With four calls of 1s / 5s / 10s / 30s, every value appears as it lands —
   the 1s value is visible while the 30s call is outstanding.
3. Medium range is **not** requested until the forecast section is reached.
   Assert against a request-recording fake.
4. A failed long-range prefetch surfaces **no** error, and "See forecast" still
   works — falling back to its own progressive fetch.
5. The prefetch starts only after the sheet's own calls resolve, so it cannot
   compete for the first paint. Assert on request ordering.
6. With the network black-holed, the sheet reaches a terminal, non-spinner state
   naming what failed and offering retry.

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
- **Security rules:** store documents are readable by authenticated users and
  writable only by the service account. They contain no user data — the key is a
  reach, not a person — but they must not be world-writable.
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
10. Firestore reads and writes per day are **measured** against the documented
    free quota (50k reads / 20k writes) and recorded, so the scaling law —
    distinct reaches × cadence — is confirmed rather than assumed.

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

**Guards.**
1. `grep -rn "NoaaApiService\|IForecastService" lib/ui/` returns nothing.
2. Every surface showing the same reach shows the same value simultaneously —
   favourites card, detail sheet, forecast page, hydrograph.
3. Two widgets mounting the same reach together issue **one** fetch.
4. A unit flip repaints every surface without refetching.
5. Full suite green; no surface silently loses data.

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

**You are done when** the originally reported journey — tapping a Friday digest
on a cold start — renders rivers in under 3 seconds, and you have the numbers to
prove it rather than the impression.

---

## Sequencing

```
Phase 0 ──┬── Phase 1 ── Phase 2 ─────────────┐
          └── Phase 3 ── Phase 4 ── Phase 5 ──┴── Phase 6 ── Phase 7 ── Phase 8
```

Phases 1–2 (app) and Phase 3 (server) run in parallel after Phase 0. Phase 4
needs 3. Phase 5 needs 4. Phase 7 needs Phase 3's monitoring proven in
production. Phase 8 closes.

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

## Open and unverified

- **Probe interval.** Hourly is the recommended default; Phase 0 confirms or
  corrects it.
- **Atomic publication.** 8/8 reaches agreed in one sample. Phase 3 guard 3 is
  designed so the answer does not matter.
- **Access distribution.** Whether non-favourite browsing ever shows enough
  overlap to justify caching is unmeasured; decision 6 says no at current scale.
- **Trimmed payload size.** The ~6× reduction from storing only `mean` is an
  estimate from the 156 KB measurement, not a measured result.
