# 0011 — One source of truth for favourite rivers

**Status:** Phase 0 deployed and collecting. Phase 1 built, in review, unmerged.
Phases 2–9 specified, not implemented.
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
8. **GEOGLOWS syncs once daily**, keyed on `forecast_date`.

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
    classifies independently. Two implementations of one rule is the drift
    ADR 0002 exists to prevent.
14. **Cached payloads carry a schema version.** Entries without a recognised
    version are discarded, not parsed.
15. **Alerts read from the store and evaluate when a new run lands.** The
    existing 6-hour cooldown remains the notification governor.
16. **No timestamps beside values.** Users should trust that what they see is the
    latest available; making that true is our job. A signal appears only when we
    *know* we are out of sync.
17. **The map's coloured streams and legend are finished and out of scope.**

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
  test dies. This has caught more real defects here than any other technique.

Hunt this project's known failure modes: fake guards; unearned "measured"; silent
success; stale docs; a second way to do the thing just centralised.

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

## Phase 1 — The non-favourite experience ▶ BUILT, IN REVIEW

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
2. Values render as they land; a ready flow is visible while a threshold call is
   30 s out.
3. **Medium range is never fetched on a tap** — asserted against the **real**
   `ForecastService` with a recording API client, plus a canary that the bundle
   *does* still fetch it, so the guard cannot become vacuous.
4. One read failing never blocks the others.
5. Exactly three reads, none waiting on another — asserted on recorded start
   times, not list position.
6. Terminal state **names what failed** and offers **Retry**.
7. The forecast page reads the narrow products, never the bundle.
8. Independent agent review passes.

**You are done when** tapping any stream puts a sheet up instantly, titles it as
soon as the cheapest call lands, fills each number independently, never shows a
blank spinner, and "See forecast" does not repeat a wait.

---

## Phase 2 — Device cache discipline

**Nothing prunes the disk cache today** — `evict()` and `clear()` exist and
nothing calls them.

**Build.** Retention keyed on **run supersession**, not wall-clock. LRU cap on
non-favourites. **Favourites pinned**, never evicted. Entries record the run they
came from so supersession is decidable offline, and carry a schema version.

**Guards.**
1. An entry whose run has not advanced is served with **no network call**,
   however old in wall-clock terms. Tap → back → tap again issues nothing.
2. Exceeding the cap evicts least-recently-used non-favourites and **never** a
   favourite — tested with the cap exceeded entirely by favourites.
3. Cache size stabilises under simulated browsing of many reaches.
4. Favouriting a previously-browsed stream renders instantly from cache.
5. **Upgrading over an old install discards unrecognised schema versions** rather
   than parsing them. Every upgrading user hits this once, on first launch.
6. **A unit-preference change re-renders from the same cached entry with zero
   refetches.**
7. Independent agent review passes.

**You are done when** browsing hundreds of streams leaves the cache bounded,
favourites survive eviction unconditionally, and a stream you looked at earlier
still draws instantly with the network off.

---

## Phase 3 — One data path inside the app

**Moved earlier in the rewrite.** Consistency is the goal, and this is what
delivers it *between screens*. It is also a prerequisite for the store being
useful: a shared cloud value is worthless if four widgets still fetch their own.

Today the app is split — `favorites_provider` and `weekly_outlook_page` read
*both* through the repository and directly.

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

## Phase 4 — Cloud store: write path, with monitoring

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

---

## Phase 6 — Alerts on the store

**Free to change: no alert has ever been delivered** — the `notification_logs`
collection does not exist. And the 6-hour cooldown decouples check frequency from
notification frequency, so raising the former cannot spam.

**Build.** `checkRiverAlerts` reads from the store rather than fetching, and
evaluates when a new run lands rather than on a fixed clock.

**Guards.**
1. Alerts issue **zero** upstream fetches.
2. At most one alert per user per river per 6 hours with hourly evaluation.
   **Verify the composite index is deployed, not merely declared** —
   `checkRecentAlert` fails open, so a missing index silently disables dedupe.
3. **The category a user sees and the one the alert fired on come from the same
   code** (decision 13). Reading the same document is not sufficient — identical
   inputs through different implementations can still disagree.
4. No new run → no evaluation, no sends.
5. Time from publication to alert under one hour, versus up to six today.
6. Independent agent review passes.

**You are done when** an alert fires from data the app is already displaying,
within an hour of the run that triggered it.

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
- **Phase 1 opened a divergence that Phase 3 closes.** The map sheet and the
  forecast page now read the narrow products; `favorites_provider` still reads
  `reachSummary`. Before Phase 1 all three shared one entry. They now bottom out
  in the same derivation but sit in *different cache entries fetched at different
  moments*, so the favourites card can legitimately disagree with the sheet — and
  it still pays the 156 KB medium-range fetch. Documented in
  `docs/internal/forecast-data-consistency-audit.md`; closed by Phase 3.
- **Geocoding is now behind `IGeocodingService`.** `GeocodingService`'s statics
  made it impossible to pin either direction — that a geocode does *not* happen
  on the fast path, or that it *does* happen at the consumer — and made widget
  tests issue live Mapbox calls. Both are now counted against a fake. The
  `ForecastService` takes it too, which is what removed the last live network
  call from the suite — proven by instrumenting the real HTTP call and running
  the full suite with zero hits. The statics remain only for surfaces not yet on
  the DI graph — `favorite_river_card`, `weekly_outlook_service`,
  `map_search_service` — which Phase 3 and Phase 9 own.
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
specific to that page. Its NWM rows call `loadCompleteReachData` — always
network, all four products, for a page rendering one series. Once favourites read
through the store, the page draws from documents it already holds.
