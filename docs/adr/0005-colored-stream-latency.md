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

**Also out of scope — reclassification (confirmed by Jerson 2026-08-10).**
Researching how NWPS and HydroViewer solve latency meant comparing their
classification ladders, and that surfaced three real issues. None of them
blocks this ADR's goal, and all of them are app-wide rather than map-local:

- RIVR has no 50-year band; both reference viewers do.
- RIVR's **Moderate** and **Major** borrow NWS's official flood-category words
  but redefine them by return period rather than by impact.
- RIVR's colors sit one band off HydroViewer's for the same return periods.

These are findings, **not dependencies**. The latency work ships without
touching a category, name, or color. They belong to **ADR 0002**
(`FlowClassification` — consumed by 8 files including the forecast gauge, the
timeline, favorites cards, and `weekly_outlook_service`), and the supporting
measurements are kept in this document only because the comparison research
happened here. Anyone acting on them should do so under ADR 0002.

The single classification-adjacent item that **is** in scope is the inverted
client/server timeout below — it is a latency bug, not a taxonomy question.

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

### How the reference viewers do it (2026-08-05)

Investigated because both NWPS and HydroViewer already show pre-colored
high-flow streams. **Neither uses Mapbox — both are Esri/ArcGIS.** Method:
fetched each site's HTML and JS bundles, extracted service URLs, then read the
ArcGIS service and layer JSON including the renderer.

**water.noaa.gov (NWPS)** — `maps.water.noaa.gov/server/rest/services/nwm/…`

- Services exist per horizon: `ana_high_flow_magnitude` (analysis /
  assimilation, i.e. current), `srf_48hr_max_high_flow_magnitude` (short range
  48h max), `mrf_nbm_5day_max_high_flow_magnitude` (medium range 5-day max),
  each with `_ak`, `_hi`, `_prvi` regional variants. Also
  `*_inundation_extent` services.
- Layer 0, "Est. Annual Exceedance Probability", polyline.
- Fields: `feature_id`, `name`, `strm_order`, `huc6`, `state`, `nwm_vers`,
  `reference_time`, `valid_time`, `max_flow`, `recur_cat`,
  `high_water_threshold`, `flow_50yr`, `flow_25yr`, `flow_10yr`, `flow_5yr`,
  `flow_2yr`.
- Renderer: `uniqueValue` on **`recur_cat`** (annual exceedance probability):
  `2%`, `4%`, `10%`, `20%`, `50%`, `>50% AND > High Water Threshold`,
  `Insufficient Data`.
- **The service contains only reaches at or above high-water thresholds** —
  NOAA has already done the filtering. It *is* a published elevated-reach set.
- **63,826 CONUS reaches** returned by an anonymous count query.
- `capabilities: Map,Query,Data`, `maxRecordCount: 2000`, formats JSON/geoJSON/PBF.

**hydroviewer.geoglows.org** — `livefeeds3.arcgis.com/arcgis/rest/services/GEOGLOWS/GlobalWaterModel_Medium/MapServer`

- Layer 0, "Flow Forecast (m³/sec)", polyline.
- Fields: `comid`, `outletcomid`, `region`, `vpu`, `upstreamarea`,
  `geodesiclength`, `streamorder`, `rivercountry`, `outletcountry`,
  `timevalue`, `meanflow`, `thickness`, `returnperiod`.
- Renderer: `uniqueValue` on **`returnperiod`** — `0` Normal (teal), `2`
  Exceeds 2yr (yellow), `10` Exceeds 10yr (orange), `25` Exceeds 25yr (red),
  `50` Exceeds 50yr (purple). Nearly the same palette RIVR already uses.
  Note a `thickness` field — they data-drive line width too.
- **48,173 elevated reaches worldwide** (`returnperiod > 0`), anonymous count.
- `maxRecordCount: 2000`.

**Both services answered anonymous queries with no token.**

Implication, and it is large: both organisations already publish the
precomputed elevated-reach set we are planning to compute ourselves. Paging at
2,000 records gives ~32 requests for CONUS and ~25 for the world. If these are
usable, most of the backend in this ADR — and its cost — may be unnecessary.
See Unverified #9-#13 before acting on that.

### Do the published ids join to ours? Yes — both (2026-08-06)

**GEOGLOWS: proven.** Pulled every `returnperiod > 0` reach for `vpu=613` from
the Esri service and intersected with our own backend's elevated set for the
same VPU, same day:

| | count |
|---|---|
| RIVR backend, VPU 613 | 559 |
| Esri service, VPU 613 | 419 |
| intersection | **419** |
| ids only in Esri's set | **0** |

Every id Esri publishes is one we also know. `comid` and our `station_id` are
the same TDX-Hydro LINKNO space. **But we flag 140 more reaches than they do
(25% more)** — the sets are not equivalent, only nested.

**NWM: proven.** Our function returned 0 of 40 NOAA-flagged reaches, which
looked like an id mismatch but is not. CIROH resolves NOAA's `feature_id`
values (`3939`, `13648`, and a known-good `946020371` all return return-period
data), so the id space is shared.

The zero overlap is explained by two *deliberate* differences in our classifier:

1. **Our 0.5 CMS min-flow floor** (ADR 0004 D3). `feature_id 3939` has
   `rp2 = rp50 = 0.03 m³/s` — a flat, trivially-small curve. NOAA flags it as a
   2% AEP event; we exclude it by design as a dry headwater trickle.
2. **Ladder start.** Our lowest band is the 2-year event. NOAA publishes
   anything above its high-water threshold, including `>50%` AEP — more
   frequent than a 2-year event, i.e. below our floor.

**So NOAA's 63,826 CONUS reaches are far more permissive than RIVR's
classification.** Adopting their categories wholesale would fill the map with
tiny streams RIVR deliberately excludes.

### What each service would let us reuse

This is the practical difference between the two:

- **NOAA exposes the raw inputs**: `max_flow`, `high_water_threshold`, and
  `flow_2yr` / `flow_5yr` / `flow_10yr` / `flow_25yr` / `flow_50yr` per reach.
  That is everything our classifier needs — we could apply **our own floor and
  our own ladder to their published numbers**, and skip both the NWM file read
  and the CIROH backfill entirely.
- **GEOGLOWS exposes only the verdict**: `meanflow` and a pre-classified
  `returnperiod` (2/10/25/50). No thresholds are published, so we **cannot**
  re-derive our 5-year band from it. Using it means accepting their ladder and
  losing the Moderate class.

### Terms of use (2026-08-06)

**NOAA — usable.** `copyrightText` is "National Water Model, NOAA/NWS National
Water Center". The NWS disclaimer (weather.gov/disclaimer) puts NWS information
in the public domain, "may be used without charge for any lawful purpose",
commercial use included. Conditions that apply to us: don't claim copyright,
don't imply NOAA endorsement, don't present modified content as official, and
follow their automated-access guidance — know the refresh rate, request only
what you need, respect HTTP error codes and retry limits. Attribution is
required if the work is predominantly NWS material.

**GEOGLOWS via Esri — not established, and this is a blocker.** The
livefeeds3 service's own description says it is "available to all ArcGIS
Online users with organizational accounts" and links to
`goto.arcgisonline.com/livefeeds3/GWM_Medium` for terms. That shortlink is
dead — it 301s to the arcgis.com root.

Searching the ArcGIS Online item registry for the service returns exactly one
Esri-owned GEOGLOWS item: *"GEOGloWS ECMWF Streamflow System (6 Day
Forecast)"* (`5c2e6d2137bb4d2187db387979db2f31`). It is licensed under the
**Esri Master License Agreement**, points at **livefeeds2** (not the
livefeeds3 endpoint HydroViewer actually uses), and its own snippet marks it
**"(Retiring)"**.

So: the endpoint we would depend on answers anonymously, but has no findable
published terms, and its closest documented sibling is under a commercial
license and being retired. **Anonymous access working is not permission.**

### Refresh cadence (measured 2026-08-06 ~16:25 UTC)

**NOAA — hourly, confirmed two ways.** The service description says "Updated
hourly", and the record timestamps agree: `reference_time` 2026-08-06 15:00:00
UTC, `update_time` 15:45:10 UTC, `nwm_vers` 3.0. So each hourly cycle is
published roughly **45 minutes behind its reference time**.

**GEOGLOWS via Esri — a full day stale at the time of measurement.** Queried
min and max of `timevalue` across the whole layer: both are
**2026-08-05T00:00:00 UTC**. A 0-hour span, so it is a single snapshot rather
than a time series, taken from the 2026-08-05 00Z run. At the moment of
measurement that was ~40 hours old, while **our own backend was already
serving the 20260806 run**.

Caveat: this is one observation. It establishes that the service *was* a day
behind us at that moment; it does not by itself establish the steady-state
cadence. But it is enough to say we would be trading fresher data for
precomputed data, not getting both.

### Category naming collides with NWS (2026-08-10)

Surfaced while comparing ladders. Recorded here because the comparison research
lives in this ADR, but it implicates **ADR 0002** — `FlowClassification` is the
app's canonical ladder, consumed by 8 files including `weekly_outlook_service`,
so any rename changes push-notification copy and the forecast gauge too.

**NWS official flood categories are Minor / Moderate / Major** (weather.gov).
"Action" is a monitoring *stage*, not a flood category.

RIVR uses **Action / Moderate / Major / Extreme** — borrowing NWS's exact words
but defining them by **return period** rather than by **impact**. NWS "Major
flooding" means extensive inundation of structures and roads; RIVR "Major"
means flow exceeded the 10-year recurrence. Those can disagree — a 10-year flow
through a well-leveed reach may inundate nothing. For a US app whose users also
read NWS products, that is a misstatement risk, not a style preference.

**US Drought Monitor ladder** (verified, droughtmonitor.unl.edu): D0 Abnormally
Dry, D1 Moderate, D2 **Severe**, D3 **Extreme**, D4 **Exceptional**. An
established hydrologic severity vocabulary whose top three terms do not collide
with NWS flood categories.

### 5-band palette validation (2026-08-10)

Run with the `dataviz` skill's `validate_palette.js`, light and dark surfaces.

**The current 4-band palette already fails** the categorical normal-vision
floor: Action↔Moderate (`#FFC400`↔`#FF8C00`) at ΔE 13.2, below the floor of 15.
Pre-existing, not introduced by adding a band.

Candidate for 5 bands — `#FFC400`, `#FF8C00`, `#F4511E`, `#C62828`, `#7B1FA2`:

- Lightness 0.607 → 0.400 → 0.252 → 0.137 → 0.078. **Monotonic**, evenly
  stepped — correct behaviour for an ordered scale.
- CVD separation **passes** all adjacent pairs (worst 9.6 deutan, 8.1 tritan).
- Normal-vision floor **fails**: worst pair 10yr↔25yr at ΔE 12.2. Inherent to
  five warm bands; the categorical rule fights the ramp.
- Contrast vs light surface weak for yellow (1.56) and orange (2.27) — also
  already true of the current palette.
- Against a dark surface, purple `#7B1FA2` drops to 2.12.

Side effect worth noting: inserting a 50-year band shifts 10yr/25yr down one
slot, which lands 2yr-yellow / 10yr-orange / 25yr-red / 50yr-purple — the same
anchoring HydroViewer uses. The off-by-one documented above resolves itself.

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
9. ~~Terms of use for both ArcGIS services.~~ **RESOLVED 2026-08-06.** NOAA is
   public domain and usable commercially with attribution and responsible
   automated access. GEOGLOWS-via-Esri has **no findable terms** for the
   livefeeds3 endpoint; its documented sibling is under the Esri Master
   License Agreement and is retiring. Treat GEOGLOWS-via-Esri as **not
   cleared**. See Measured above.
10. ~~Whether the id fields match ours.~~ **RESOLVED 2026-08-06 — they do,
    for both sources. See Measured above.** What remains open is not the join
    but the *disagreement*: we flag 25% more GEOGLOWS reaches than Esri does,
    and NOAA flags far more NWM reaches than we do. Which set is correct for
    RIVR is a product question, not an engineering one.
11. ~~Refresh cadence and staleness of both services.~~ **RESOLVED 2026-08-06.**
    NOAA is hourly, published ~45 min behind reference time. The Esri GEOGLOWS
    layer was serving the 2026-08-05 00Z run while our own backend served
    20260806 — a full day behind us. See Measured above. Still open: whether
    that one-day lag is the steady state or a one-off.
12. **Category ladder mismatch.** NOAA publishes AEP (`2/4/10/20/50%`),
    GEOGLOWS publishes return period (`2/10/25/50`), RIVR uses `2/5/10/25`
    (ADR 0002). AEP maps to return period arithmetically, but neither source
    exposes a 5-year class, so RIVR's Moderate band has no direct equivalent.
13. **Rate limits and paging reliability** for pulling ~32 + ~25 pages daily.
14. **Whether a thin dark casing fixes low-zoom contrast** for the yellow and
    orange bands on a light basemap, and for purple on a dark one. Asserted
    2026-08-10 without testing. The validator measures fill-vs-surface contrast,
    not the perceptual effect of an outline. Cheapest test: render the five
    bands as cased lines over both basemaps and look. Note this touches visual
    treatment, which is out of scope unless Jerson reopens it.

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

The two blocking questions are now answered, and they split the two sources:

1. **Fix the inverted client/server timeout.** Independent of every other
   question and currently guarantees failure for 33% of the world's rivers.
2. **NWM — the published NOAA service is a genuine option.** Public domain,
   hourly, and it exposes `max_flow` plus `flow_2yr`…`flow_50yr`, so RIVR's own
   floor and ladder can be applied to their numbers. That removes the NWM
   forecast read and the CIROH backfill entirely. Next: confirm paging ~32
   pages hourly is acceptable under their automated-access guidance, and decide
   whether to keep RIVR's stricter classification.
3. **GEOGLOWS — the Esri route is not viable as things stand.** No findable
   terms, a retiring documented sibling under a commercial licence, and it was
   a day staler than our own pipeline when measured. So GEOGLOWS still needs
   the precompute this ADR was originally scoped around: resolve Unverified #2
   (pre-derived non-ensemble product), then #5 and #6, then measure #1 on
   device and pick a blob shape.
4. *(Deferred, ADR 0002 — not this ADR.)* RIVR flags more GEOGLOWS reaches
   than HydroViewer and far fewer NWM reaches than NWPS, has no 50-year band,
   and its category names collide with NWS's. Findings only; see Out of scope.
