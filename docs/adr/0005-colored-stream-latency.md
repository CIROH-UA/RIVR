# ADR 0005 — Colored-stream latency (NWM + GEOGLOWS)

- **Status:** Proposed — no decision made yet. This document is the running
  research log for making flood-condition colors appear instantly while panning.
- **Date opened:** 2026-08-05
- **Deciders:** Jerson Garcia (lead), Dr. Ames (approved pursuing a paid
  Cloud Functions path, 2026-08-05)
- **Relates to:** ADR 0004 (`0004-map-stream-condition-coloring.md` — the
  coloring architecture this builds on), `project_map_stream_conditions` (memory)
- **Scope:** *Only* the latency of getting condition data to the client. The
  visual treatment (widths, colors, draw order, minZoom bands) is settled and
  explicitly out of scope — see ADR 0004 and "Out of scope" below.

## How to use this document

Every finding about colored-stream latency gets logged here, **labelled by
confidence**, with the date and how it was obtained. Sections:

- **Measured** — someone ran it and recorded the number. Includes the method.
- **Estimated** — derived or extrapolated. States the basis and the sample size.
- **Unverified** — believed, not checked. Nothing may be built on these.
- **Disproven** — claims that turned out false. Kept so they are not re-proposed.

A claim moves between sections only when new evidence justifies it. Never delete
a disproven entry.

## Context and problem

Flood-condition colors are computed on demand. Panning to a region nobody has
loaded today triggers a fresh computation, and the user waits — observed at
40s to several minutes on device, sometimes never completing. The data changes
at most once a day (GEOGLOWS) or hourly (NWM), so computing it per request is
the wrong shape.

## Out of scope

Confirmed by Jerson 2026-08-05: stream widths, category colors, the
low-zoom exaggeration curve, and the heat-map read at continental zoom are
**final**. Do not revisit them under this ADR.

---

## Measured

All from 2026-07-29 → 2026-08-05 unless noted.

### GEOGLOWS compute cost

| VPU | rivers | time | conditions | rate |
|---|---|---|---|---|
| 613 | 53,126 | 55.9s | warm, serial | 950/s |
| 420 | 15,286 | 16.2s | warm, serial | 944/s |
| 410 | 36,265 | 41.3s | cold, serial | 878/s |
| 210 | 57,819 | 132s | concurrency 3 | 440/s |
| 126 | 45,542 | 77s | concurrency 3 | 589/s |
| 509 | 28,876 | 61s | concurrency 3 | 470/s |
| 702 | 27,499 | 41s | concurrency 3 | 672/s |
| 305 | 15,562 | 52s | concurrency 3 | 302/s |

- **Serial throughput ≈ 950 rivers/s. Under concurrency 3 it drops to 300-670/s.**
- **Cold start is not the dominant cost** — cold and warm rates are close. The
  work is linear in river count.
- Method: timed `curl` against `geoglows_stream_conditions?vpu=<n>`.

### GEOGLOWS timeout failures

VPUs 605 (286,905), 714 (223,906), 406 (120,911), 105 (114,704) all returned
HTTP error at **exactly 180s** — the function's own `timeout_sec=180`
(`functions_geoglows/main.py`).

### The two timeouts are inverted (bug)

- `geoglows_stream_conditions`: `timeout_sec=180`
- `StreamConditionsService._timeout`: **120s**

**The client gives up before the server does.** At 950 rivers/s that caps the
app at ~114,000 rivers, which means **14 of 125 VPUs — 33% of the world's
rivers — can never display coloring today.** They fail silently as a
best-effort no-op.

### VPU size distribution

125 VPUs, 6,838,900 rivers total. min 15,286 · median 39,307 · mean 54,711 ·
max 286,905. Source: `functions_geoglows/vpu_slices.json`.

### Elevated-reach rate

2,515 elevated of 304,566 rivers across 9 sampled VPUs = **0.83%**. Same-day
counts ranged 0 (VPU 420) to 2,102 (VPU 613, central Chile, all four
categories: 1416 Action / 307 Moderate / 163 Major / 216 Extreme).

### Blob size

VPU 613 — the largest elevated set observed, 2,102 reaches — serialises to
**33,695 B raw / 7,898 B gzipped**.

### NWM compute cost

| operation | time |
|---|---|
| Cold — reads 9 NetCDF files, peak over all 2.78M reaches | **27.5s** |
| Warm, 1 id | 1.7s |
| Warm, 400 ids | 3.3s |

The 27.5s cold read computes peak flow for **every CONUS reach at once**; it is
a fixed cost, not per-reach. The `≤800 ids` client limit exists only because of
the CIROH return-period API, not the forecast read.

`nwm_stream_conditions`: us-east1, 4 GB, `timeout_sec=300`.

### Why GEOGLOWS is ~106× slower per river than NWM

- GEOGLOWS reads `Qout[ensemble, time, rivers]` — the **full 52-member
  ensemble** per river, then median-over-ensembles, max-over-time.
- NWM reads a single deterministic `streamflow` scalar per reach per hour, for
  9 hours (`range(1, 19, 2)`).

Effective rates: NWM ≈ 101,000 rivers/s vs GEOGLOWS ≈ 950/s. The gap is data
volume, not code structure.

### NWM forecast horizon

`short_range`, hours 1-17 — an **18-hour** horizon. NWM `short_range` publishes
**hourly** (t00z…t23z); the code takes the newest cycle.

### Platform limits (verified against Google docs)

| trigger | max duration |
|---|---|
| HTTP | 60 min |
| Scheduled / task queue | 30 min |
| Event-driven (Pub/Sub) | 540s |

Cloud Run pricing (Tier 1): **$0.000018/vCPU-second**, **$0.000002/GiB-second**.
Free tier: 240,000 vCPU-s and 450,000 GiB-s per month.

Consequences: full-world GEOGLOWS serial ≈ 120 min, which **exceeds the 30-min
scheduled ceiling** — a single scheduled job cannot do it. The largest single
VPU ≈ 302s, which **fits inside the 540s event-driven ceiling** — so per-VPU
fan-out is viable.

### Project configuration

`firebase.json` declares `firestore` and `functions` (codebases `default`,
`geoglows`). **There is no `storage` block.**

---

## Estimated

- **~56,000 elevated reaches worldwide.** Basis: 0.83% × 6,838,900. Sample is
  9 of 125 VPUs (4.5% of rivers) and VPU 613's 4% rate skews it upward. Wide
  error bars.
- **Global blob ≈ 900 KB raw / ≈ 210 KB gzipped.** Basis: the above count at
  VPU 613's measured 16 bytes/entry.
- **GEOGLOWS precompute ≈ $5-15/month.** Basis: 7,200-13,700 function-seconds
  per day (measured serial and concurrent rates) at verified Cloud Run pricing.
  **Assumes 2 vCPU at 4 GiB and request-based billing** — both unverified, and
  vCPU is ~90% of the cost.
- **NWM precompute ≈ $0/month.** Basis: ~27.5s/run; even hourly (24 runs/day
  ≈ 11 min/day) stays inside the monthly free tier.
- **NWM return-period backfill ≈ 2.5 hours, one time.** Basis: 2.78M ÷ 500 ids
  per call ≈ 5,560 calls at ~1.6s each (one sample). Return periods are static,
  so this is not recurring.

---

## Unverified — do not build on these

1. **Cost of a ~56,000-entry `match` expression on device.** ADR 0004 verified
   10,000 entries at ~34 ms. 56k is 5.6× and untested. **This gates the choice
   between a global blob and per-VPU blobs.**
2. **Whether GEOGLOWS publishes a pre-derived, non-ensemble product.** If a
   median/summary dataset exists in their S3, it could cut GEOGLOWS cost ~50×.
   Currently the single largest open lever.
3. **GEOGLOWS forecast horizon.** If it is materially longer than NWM's 18
   hours, the same "Extreme" purple means different things by source under one
   legend. Possible correctness issue, not just cosmetic.
4. **Whether station ids partition cleanly by VPU.** Observed non-overlapping
   for 3 of 125 VPUs (410→`440…`, 613→`660…`, 614→`670…`), elevated reaches
   only. If true at full scale, the client could resolve a VPU locally with a
   125-entry table and skip a server round trip.
5. **Cloud Storage bucket existence and write permission** for
   `ciroh-rivr-app` under `jersondevs@gmail.com`.
6. **Publish times** of the GEOGLOWS daily zarr and NWM cycles — needed so the
   cron fires after the data lands.
7. **CIROH rate limits and permission** for a 5,560-call backfill against
   `nwm-api.ciroh.org`.
8. **vCPU allocation at 4 GiB**, and whether this workload qualifies for
   instance-based rather than request-based billing.

---

## Disproven — do not re-propose

- **"The GEOGLOWS discovery query is cheap."** False. `firstVisibleGeoglows-
  StationId` used `querySourceFeatures` with an empty filter, which serialises
  every feature in every loaded tile across the platform channel. Returning on
  the first hit truncates only the Dart-side loop, after the payload has
  already crossed.
- **"The `within` US-mask filter caused the low-zoom freeze."** Never
  confirmed. The freeze resolved after per-band `minZoom` landed, but the cause
  was never isolated. Stated as a finding when it was a hypothesis.
- **"The probe is broken at low zoom / minZoom caused a regression."** False.
  Verified on device 2026-07-30: conditions load at z6 without zooming in. The
  claim was inferred from a screenshot and code reading, not tested.
- **"GEOGLOWS could read once like NWM and cut the cost."** False. The cost is
  ensemble data volume (52 members per river), not per-VPU slicing. Reading the
  zarr once moves the same bytes.
- **ADR 0004 D3's reasoning that a full-CONUS NWM precompute is impractical.**
  It rejected the idea partly because return periods "aren't bulk-available."
  True per request, but they are **static** — so it is a one-time backfill, not
  a recurring cost. The conclusion deserves revisiting; the measurement above
  is the basis.
- **`MapboxMap.getSize()` is usable on iOS.** False — the plugin's Swift throws
  `"Not available."` unconditionally. Screen size must come from MediaQuery.

---

## Candidate shape (not yet decided)

```
Cloud Scheduler (daily, after the forecast lands)
  └─> 125 Pub/Sub messages, one per VPU
        └─> worker (4 GB, 540s, us-west1) computes one VPU, writes its blob
  └─> final step concatenates all 125 into one global blob
Client reads the static blob from Cloud Storage — a CDN read, no compute.
```

NWM runs the same way but as a single job, and probably **hourly** rather than
daily, because `short_range` updates hourly and a daily blob would be up to 23
hours stale.

Open design question gated on Unverified #1: one global blob (kills the probe
and all per-pan fetching) versus per-VPU blobs (smaller payload, keeps today's
client flow).

## Next actions

1. Resolve Unverified #2 (pre-derived GEOGLOWS product) — largest cost lever.
2. Resolve Unverified #5 and #6 — cheap, unblock scheduling.
3. Fix the inverted client/server timeout. Independent of everything else and
   currently guarantees failure for 33% of the world.
4. Measure Unverified #1 on device, then pick the blob shape.
