# ADR 0005 — Colored-stream latency (NWM + GEOGLOWS)

- **Status:** Accepted for GEOGLOWS — daily precompute built, deployed and
  measured 2026-08-10/11. Still the running research log; the NWM half is
  untouched and remains on-demand.
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

### No pre-derived GEOGLOWS product exists (2026-08-10)

The largest hoped-for cost lever. **Answer: it does not exist.**

`geoglows-v2-forecasts/{date}00.zarr/.zmetadata` lists exactly four arrays:

| array | shape | dtype | chunks |
|---|---|---|---|
| `Qout` | `[52, 280, 6838900]` | `<f4` | `[52, 280, 686]` |
| `ensemble` | `[52]` | `<i8` | `[52]` |
| `rivid` | `[6838900]` | `<i4` | `[213716]` |
| `time` | `[280]` | `<i4` | `[280]` |

No median, mean, or summary array. The bucket root holds only dated `.zarr`
directories, and `geoglows-v2/` holds `hydrography`, `hydrography-global`,
`hydrosos`, `retrospective`, `routing-configs`, `sources`, `tables`,
`transformers` — none of which is a per-reach forecast summary.

**The chunking is the binding constraint.** Each chunk is `[52, 280, 686]` —
the *entire* ensemble and *entire* time axis for 686 rivers. There is no way to
read fewer members or fewer timesteps; any reach you want costs all 52 members
× 280 steps. Classifying the world therefore means moving
**52 × 280 × 6,838,900 × 4 bytes ≈ 398 GB per day**.

That reconciles the earlier throughput number: 6,838,900 ÷ 950/s ≈ 7,199s, and
398 GB over 7,199s ≈ 55 MB/s of sustained S3 read. The ~$5-15/month estimate is
the genuine floor for computing GEOGLOWS ourselves, not something better
engineering removes.

### Forecast publish times (2026-08-10)

Measured from S3 `Last-Modified` on `{date}00.zarr/.zmetadata`:

| run | landed (UTC) |
|---|---|
| 2026-08-10 | 10:26:37 |
| 2026-08-09 | 10:13:04 |

So the GEOGLOWS daily run lands around **10:15-10:30 UTC**; a cron at ~11:00
UTC has margin. Two samples — enough to schedule against, not enough to call a
guarantee. NOAA is hourly, ~45 min behind its reference time (above).

### End-to-end verification on device (2026-08-10)

The pipeline was run for real and confirmed in the app, not just in the bucket.

- Scheduler fanned out **125/125** regions; workers wrote **125/125** blobs;
  the merge published `latest.json`.
- **85,324 elevated reaches worldwide** for 20260810 — 62,485 Action, 6,519
  Moderate, 4,245 Major, 12,075 Extreme. File is **1.30 MiB**.
- Endpoint timing: **0.5s warm, 7.5s cold** (was 40-300s of computation per
  region, with the largest regions unable to finish at all).
- Cloud Function access logs show the app fetching it on every launch:
  `Dart/3.11`, HTTP 200, 1,365,455 bytes.
- **Rendered correctly on the simulator** over the Yarlung Tsangpo (Tibet),
  with all four categories visible simultaneously.

**Unverified #1 is resolved.** The concern was whether a `match` expression far
larger than the 10,000 entries validated in ADR 0004 would stall the map. At
**85,324 entries** it renders with no visible stutter. Not instrumented, so
this is an observation rather than a measurement — but it clears the risk that
gated the global-blob design.

**Testing note worth keeping.** Three separate sessions showed "no colours"
and none of them were bugs: northern Chile (Atacama — almost no rivers) and
Provo, Utah (inside the US, where GEOGLOWS is masked out and NWM owns the map,
so the GEOGLOWS world file cannot apply). **Only test GEOGLOWS colouring
outside the US, in a region with known elevated reaches.**

### Where the colour delay actually is (2026-08-11)

Measured across five continents, then isolated with a controlled experiment.

**Per-site timings** (from app launch; streams = map has drawn the network,
colour = first flood colours visible):

| Site | Continent | streams | colour |
|---|---|---|---|
| Yarlung Tsangpo, Tibet | Asia | 2.6s | 2.6s |
| Patagonia, Chile | South America | 2.2s | 3.0s |
| Tanana valley, Alaska | North America | 1.7s | 5.2s |
| Halmahera, Indonesia | Oceania / SE Asia | 2.6s | 5.2s |
| Nile Delta, Egypt | Africa | 2.6s | 9.5s |

**The isolating experiment.** Same location (Patagonia), same binary, varying
only how many reaches are handed to Mapbox:

| reaches applied | streams | colour |
|---|---|---|
| 85,324 (whole world) | 2.6s | **8.3 - 12.0s** |
| 3,946 (one VPU) | 2.6s | **3.4s** |
| 100 | 2.6s | **2.6s** |

**Conclusion: the cost is applying the expression, and it scales with entry
count.** Not the download, not tile loading, not the function hop.

Corollaries:

- **The org policy forbidding public buckets is NOT responsible for the delay.**
  The endpoint answers in 0.5-0.6s warm and, since the fetch now starts in
  `initState`, the data is in hand at ~1.5s — before the map has drawn
  anything. Serving from a public CDN would save ~0.3-0.4s and would not touch
  the 3-9s gaps.
- **ADR 0004's "10,000 entries in ~34 ms" does not extrapolate.** At 85,324 the
  apply costs seconds, not ~290 ms. Whatever the cost curve is, it is not
  linear in the range that matters.
- Earlier readings of "3.0s" for the full set were outliers; repeated runs give
  8.3, 8.3, 9.1, 12.0s.

**Design implication.** Apply only what the viewport needs, then fill in the
rest. The blocker is that the world file carries ids and categories but **no
coordinates and no grouping**, so the client cannot select "the ones near me".
The cheapest fix is to group the published file by VPU — the backend already
computes it that way — so the client can apply the region it is looking at
first and the remainder afterwards.

### Final measurements after region-first painting (2026-08-11)

The shipped behaviour. Times from app launch; "streams" is the map drawing the
river network, "colour" is the first flood colours visible.

| Site | Continent | streams | colour | gap | before |
|---|---|---|---|---|---|
| Yarlung Tsangpo, Tibet | Asia | 2.6s | 2.6s | 0.0s | 0.0s |
| Patagonia, Chile | South America | 2.6s | 2.6s | 0.0s | 0.8s |
| Nile Delta, Egypt | Africa | 2.6s | 3.4s | 0.9s | 6.9s |
| Halmahera, Indonesia | Oceania / SE Asia | 1.7s | 3.4s | 1.7s | 2.6s |
| Tanana valley, Alaska | North America | 2.6s | 6.0s | 3.4s | 3.5s |

Four of five are inside two seconds. **Alaska is the exception and the reason
is structural:** it is inside the US, where the GEOGLOWS base layers are masked
out, so the viewport probe finds no reach, no region resolves, and the map
falls through to applying the whole world. Any US location behaves this way for
GEOGLOWS colouring.

### Streams at zoom 0 — not possible with the current tiles

Asked 2026-08-11. The `geoglows-world` tileset has **minzoom 3**, so below zoom
3 there is no GEOGLOWS geometry to draw at all, coloured or otherwise. NWM goes
to zoom 0, so US streams can render there. Three ways round it, none built:

1. Generate the forthcoming split US / outside-US GEOGLOWS tilesets from zoom 0.
   A tiling parameter, no app work — much the cheapest.
2. Draw points rather than lines below zoom 3. Needs coordinates, which the
   published file does not carry; adding lat/lon for the ~85k elevated reaches
   roughly doubles it.
3. One marker per region (116 of them) coloured by its worst category. Tiny,
   works at any zoom, and arguably the honest picture at world scale where an
   individual river is far below one pixel.

### Why NWM streams render as broken stripes below zoom 8 (2026-08-17)

Jerson reported that `nwm-channels` looks progressively wrong from z7 down to
z0 — vertical strips of stream fragments rather than a river network — and asked
whether Mapbox could thin the network at low zoom instead. Measured by fetching
live tiles from the Vector Tiles API and decoding them with GDAL's MVT driver
(one tile per zoom, centred 39.4N 98.3W, Kansas):

**Tile bytes are pinned at a ceiling below z8.**

| Zoom | `nwm-channels` bytes | features | `geoglows-world` bytes | features |
|---|---|---|---|---|
| 3 | 613,029 | 16,302 | 81,515 | 4,612 |
| 4 | 655,987 | 16,924 | 167,203 | 8,199 |
| 5 | 678,173 | 19,396 | 213,977 | 8,468 |
| 6 | 690,210 | 21,344 | 336,749 | 11,553 |
| 7 | 706,353 | 21,548 | 144,889 | 3,950 |
| 8 | **317,195** | 8,546 | 60,927 | 1,076 |

NWM sits at 613-706 KB for z3-z7 then halves at z8 — a plateau, i.e. the tiler
was discarding features to fit a byte budget at every zoom below 8. z8 is the
first zoom that fits, and z8 is exactly where the render looks correct. GEOGLOWS
never exceeds 337 KB and so never hits the ceiling.

**The primary defect: no order-aware thinning. NWM's stream-order mix is
identical at every zoom.**

| Zoom | order ≤2 | order ≥5 |
|---|---|---|
| 3 | 76.2% | 6.7% |
| 4 | 75.2% | 7.4% |
| 5 | 73.6% | 7.0% |
| 6 | 73.4% | 7.6% |
| 7 | 75.0% | 7.2% |
| 8 | 75.4% | 6.1% |

Frozen across five zoom levels. A z3 tile spends three-quarters of its byte
budget on order-1 and order-2 headwater creeks that are far below one pixel at
that scale, and discards most of the network to afford them. What renders is a
uniform ~0.6% sample of the smallest streams — noise, not a river network. **This
is the cause of "looks broken", independent of the striping.**

**Secondary: strong longitude density banding at low zoom.** Vertex counts per
longitude bin, tile-edge bins excluded:

| Zoom | bin width | max/min density | band period | as % of tile width |
|---|---|---|---|---|
| 3 | 0.5° | 44× | ~2.03° | 4.5% |
| 5 | 0.125° | 65× | ~0.49° | 4.4% |
| 6 | 0.0625° | 14× | ~0.23° | 4.1% |

GEOGLOWS at z4 for comparison: **3×**, i.e. essentially uniform. A 44× density
swing on a ~2° period is what reads visually as vertical stripes.

**What is NOT established:** which build setting produced the banding. The band
period is a roughly constant *fraction* of tile width (4-4.5%) at every zoom
rather than a fixed number of degrees, which **disproves the earlier guess that
the bands are longitude bundle seams** — a fixed longitude split would give a
constant period. It is consistent with tippecanoe's density-based feature
dropping operating on a per-zoom grid, and with `geoglows-world` having been
built with `--drop-densest-as-needed` (uniform result) while NWM was assembled
from bundles without it. Not reproduced; do not state as fact.

**Conclusion.** The fix for both problems is the same and it is a build-time
filter, not a render-time one: include a feature only from the zoom at which it
is visible (e.g. order ≥8 from z0, ≥6 from z5, ≥5 from z7, all from z9). Then no
low-zoom tile is ever over budget, so nothing is dropped, so there is no banding
and no creek-dominated sample. Render-time `streamOrder` filters in the app
cannot fix this — the feature must survive into the tile before a style filter
can act on it.

**Sizing estimate (Estimated, not measured):** order ≥7 is 2.9% of the z3
sample. Because dropping is order-blind and proportional, that ratio should
hold for the full population, giving ~78,000 order-≥7 reaches nationally out of
2.7M — comparable to the elevated-reach set, which tiles comfortably.

### Build cost is driven by max zoom, from the account's own billing (2026-08-17)

Read off the Mapbox tileset pages for the byu-hydroinformatics org:

| Tileset | Zoom extent | File size | **Compute units** |
|---|---|---|---|
| `geoglows-world` | 3-12 | 7.2 GB | **0.92** |
| `nwm-channels` | 0-16 | 3.3 GB | **77.55** |

NWM cost **84× the CU of GEOGLOWS while carrying half the data**. The
distinguishing variable is max zoom (16 vs 12). At $0.90/CU beyond the 20 free
per month, `nwm-channels` is a ~$52 rebuild and `geoglows-world` is free. This
is the measured basis for capping every new tileset at z12.

Free tiers as of this billing period: **0/20 CU, 0/10,000 processing MB, 64/750
tileset hosting days**, Vector Tiles API 5,984/200,000 requests.

### Where the geometry can be sourced (2026-08-17)

Checked because rebuilding needs source linework, and **no NWM geometry exists on
this machine** (searched `~/Developer`, `~/Downloads`, `~/Documents`,
`~/Desktop`; the `~/Developer/geoglows-tiles` workdir from July is gone). 1.2 TB
free, so capacity is not a constraint.

- **Elevated reaches, US — solved, geometry included.** The NWM high-flow
  services on `https://maps.water.noaa.gov/server/rest/services/nwm` return
  `esriGeometryPolyline` with `returnGeometry=true&outSR=4326`, alongside
  `feature_id`, `strm_order`, `huc6`, `recur_cat_5day`, and the 2/5/10/25/50-year
  thresholds. `maxRecordCount` is **2,000** and `supportsPagination` is true.
  Measured: one 2,000-feature page with geometry = **3.1 MB in 1.29s**.
  Counts on 2026-08-17: CONUS 5-day **89,383**, CONUS analysis 74,465, Alaska
  5-day **40,156**, Hawaii 48hr **1,541**, PRVI 48hr **95**. The four 5-day/48hr
  services total ~131,000 features ≈ 66 requests ≈ under two minutes.
  Note `recur_cat_5day` uses NOAA's own ladder (`2,4,10,20,50,>50`), not RIVR's
  2/5/10/25 (ADR 0002) — a mapping is required, not a passthrough.
- **Full CONUS network — available, public, no auth.**
  `https://dmap-data-commons-ow.s3.amazonaws.com/NHDPlusV21/Data/NationalData/NHDPlusV21_NationalData_Seamless_Geodatabase_Lower48_07.7z`,
  **7.81 GB**. NWM CONUS `feature_id` is the NHDPlus V2 COMID, so this is the
  correct key space. Hawaii/PR/VI/Pacific:
  `..._Seamless_Geodatabase_HI_PR_VI_PI_03.7z`, 104.8 MB.
  **Needs `brew install p7zip` — no 7z extractor on this machine.**
- **Ruled out.** There is no full channel-network geometry service at NOAA:
  `maps.water.noaa.gov/.../nwm` publishes only high-flow, anomaly, inundation
  and arrival-time products (all elevated-reach subsets); `nwm/nwm_channels`
  under both `mapservices.weather.noaa.gov/static` and `/eventdriven` returns a
  404 **in a HTTP 200 body** — an earlier probe that checked only the status code
  wrongly reported these as present.
- **Ruled out.** `lynker-spatial` hydrofabric v2.2/v2.3/v3.0 — the bucket
  *listing* is public but every object returns `AccessDenied` (403) over plain
  HTTPS on both `s3.amazonaws.com` and `s3-us-west-2.amazonaws.com`. Likely
  requester-pays; would need AWS credentials.
- **Open gap.** Alaska is not in NHDPlus V2. The NWM v3 Alaska domain uses a
  separate fabric and no source for its 40,156-reach linework has been
  identified. Alaska base-network coverage is therefore unresolved.

### HydroShare gdb vs NHDPlus — the HydroShare file wins for CONUS (2026-08-17)

Jerson supplied the HydroShare resource the current tileset was built from
(`hydroshare.org/resource/35f3fd9bb2f64c36bb52c2f0ef8775e3`, downloaded as
`~/Downloads/ee992dff-c005-4562-a4ff-842a6b98e8a1.zip`, 965 MB → inner
`NWM_app_data.zip` → `nwm_app.gdb`, **3.3 GB extracted**, dated **2018-01-09**).

**It is provably the source of the live `nwm-channels` tileset.** Layer
`channels`, and every identifying number matches the tileset page exactly:

| | HydroShare gdb | live tileset |
|---|---|---|
| Features | 2,699,225 | OBJECTID 1 – 2.7m |
| `station_id` range | 101 – 1,170,023,962 | 101 – 1.2b |
| `streamOrder` range | 1 – 10 | 1 – 10 |
| Fields | station_id, streamOrder, Shape_Length, OBJECTID | same four |
| Extent | -124.724424, 24.874269, -66.988396, 52.864521 | -124.73, 24.87, -66.98, 52. |

SRS is NAD83 (EPSG:4269); other layers present are `grid_land`, `reservoirs`,
`usgs_gauge`.

**Not stale, and not simplified.** Sampled 6,000 `feature_id`s from NOAA's live
CONUS 5-day high-flow service: **6,000/6,000 present in the 2018 gdb.** Then
compared vertex counts for eight reaches between NOAA's service geometry and the
gdb: **identical for all eight** (35/35, 383/383, 114/114, 2/2, 8/8, 5/5, 4/4,
2/2). NOAA is serving the same linework this file holds.

**Coverage by region** — sampled service ids tested for membership:

| Region | Source that has it | Match |
|---|---|---|
| CONUS | HydroShare `nwm_app.gdb` (2,699,225) | **6,000/6,000 (100%)** |
| Hawaii | NHDPlus V21 HI_PR_VI_PI, layer `NHDFlowline_Network` (33,273) | **1,343/1,343 (100%)** |
| PR/VI | same file | **95/95 (100%)** |
| Alaska | **neither** | **0/4,000 (0%)** |

Alaska's NWM ids are 14-digit (`19020190000003`…`75005400047345`) — a different
key space from NHDPlus COMID entirely. Hawaii/PRVI ids sit in the 800M–921M
COMID band that the NHDPlus island file covers. `NHDFlowline_Network` carries
both `ComID` and `StreamOrde` in one layer, so no VAA join is needed there
either.

**Consequence for the plan: the 7.81 GB NHDPlus V21 Lower48 seamless download is
unnecessary.** Cancelled. The HydroShare gdb is already pre-filtered to the NWM
channel network, pre-joined (station_id + streamOrder on the feature), pre-named
to RIVR's attribute contract, and verified id-identical to what NOAA publishes.
Only the 105 MB `NHDPlusV21_NationalData_Seamless_Geodatabase_HI_PR_VI_PI_03.7z`
is still wanted, to add Hawaii and Puerto Rico. `p7zip` installed 2026-08-17.

### Exact stream-order histogram for the ladder (2026-08-17)

Counted directly from `nwm_app.gdb` — these replace the earlier estimate.

| Order | Count | Share | Cumulative ≥ |
|---|---|---|---|
| 1 | 1,420,615 | 52.6% | 2,699,225 |
| 2 | 597,944 | 22.2% | 1,278,610 |
| 3 | 316,551 | 11.7% | 680,666 |
| 4 | 174,148 | 6.5% | 364,115 |
| 5 | 95,990 | 3.6% | 189,967 |
| 6 | 54,512 | 2.0% | 93,977 |
| 7 | 26,195 | 0.97% | 39,465 |
| 8 | 9,451 | 0.35% | 13,270 |
| 9 | 3,267 | 0.12% | 3,819 |
| 10 | 552 | 0.02% | 552 |

**Correction.** An earlier entry estimated order ≥7 at 2.9% ≈ 78,000 reaches,
extrapolated from the z3 tile sample. The true figure is **1.46% = 39,465** —
roughly half. High orders are over-represented in the z3 tile relative to the
population, which also means the tiler's dropping was not perfectly order-blind,
only close to it. The ladder sizing below uses the counted values.

At the proposed ladder, features per zoom band: z0-3 → 13,270; z4-5 → 39,465;
z6 → 93,977; z7 → 189,967; z8 → 364,115; z9 → 680,666; z10-12 → 2,699,225.
z0-3 carrying 13,270 lines nationally is roughly 0.5% of what the current z3
tile tries to hold.

### `nwm-channels-v2` built and published — the ladder works (2026-08-17)

Phase 0 (local proof on one basin) and Phases 1-2 (national build + publish)
executed. Workdir `~/Developer/rivr-tiles/`.

**Phase 0, controlled experiment.** Same 409,112 reaches (Missouri/Mississippi
confluence, bbox -100 36 -88 44), tiled twice at z0-12 with `-r1` (dropping
disabled) so any overflow surfaces as an error rather than silent loss.

- *Without* the ladder — the current recipe — **the build fails at zoom 2**:
  `tile 2/1/1 size is 843949 with detail 12, >500000`,
  `tile 2/0/1 has 197515 (estimated 263214) features, >200000`,
  `*** NOTE TILES ONLY COMPLETE THROUGH ZOOM 1 ***`. At 409k features, not 2.7M.
- *With* the ladder — exit 0, **zero size warnings**, tilestats count 409,112 =
  source count exactly, max tile 60 KB.

This is the direct evidence that the original tileset's damage was forced: the
recipe cannot produce low zooms without discarding features.

**The ladder** (tippecanoe `-J` feature filter on `$zoom`):
z0-3 → order ≥8; z4-5 → ≥7; z6 → ≥6; z7 → ≥5; z8 → ≥4; z9 → ≥3; z10-12 → all.

**Phase 2 national build.** 2,729,961 features, `-Z0 -z12 -r1`, **2m20s**,
675 MB, **zero warnings**. Uploaded via the Mapbox Uploads API (staged in 70s,
processed in 227s).

**Cost: 0.5151 CU** — read from `GET /tilesets/v1/byu-hydroinformatics`. Against
the 20 free CU/month with 0 used, this was **free**.

| Tileset | Zoom | Features | Size | **CU** |
|---|---|---|---|---|
| `nwm-channels` (old) | 0-16 | 2,699,225 | 3.3 GB | **77.55** |
| `nwm-channels-v2` | 0-12 | 2,729,961 | 675 MB | **0.5151** |

**150× cheaper.** Confirms max zoom, not feature count, is the CU driver — the
new tileset carries *more* features than the old one.

**Live verification** — same tile coordinates fetched from the Vector Tiles API
for both tilesets, Kansas 39.4N 98.3W:

| z | old bytes | old feats | old ≤order2 | new bytes | new feats | new min order |
|---|---|---|---|---|---|---|
| 0 | 564,379 | 22,124 | 80.7% | **27,177** | 2,758 | 8 |
| 1 | 586,347 | 22,093 | 80.3% | **47,630** | 4,821 | 8 |
| 2 | 618,320 | 21,768 | 78.3% | **63,644** | 6,010 | 8 |
| 3 | 613,029 | 16,302 | 76.2% | **56,563** | 4,539 | 8 |
| 4 | 655,987 | 16,924 | 75.2% | **147,010** | 11,051 | 7 |
| 5 | 678,173 | 19,396 | 73.6% | **93,296** | 6,547 | 7 |
| 6 | 690,210 | 21,344 | 73.4% | **62,103** | 3,890 | 6 |
| 7 | 706,353 | 21,548 | 75.0% | **41,099** | 1,913 | 5 |
| 8 | 317,195 | 8,546 | 75.4% | **29,815** | 988 | 4 |

Every zoom respects its ladder floor; no tile exceeds 147 KB against the 500 KB
limit. Decoding four live z3 tiles and rendering them yields 9,539 segments
forming a recognisable Mississippi/Missouri/Ohio/Columbia/Colorado network —
the thing that was previously impossible below z8.

**New coverage.** Bounds are now `-160.247034, 17.673740, -64.565196,
52.864521`: Hawaii (15,223) and Puerto Rico/VI (15,513) are included for the
first time. Sourced from NHDPlus V21 HI_PR_VI_PI `NHDFlowline_Network`, filtered
to those two regions only (Guam/CNMI 1,180 and American Samoa 1,357 excluded —
NWM publishes no products for them). Zero id collisions with the CONUS set,
verified before merging; the COMID ranges overlap numerically so this mattered.

**Attribute contract preserved:** layer `channels`, fields `station_id` and
`streamOrder`, both Number. `Shape_Length` and `OBJECTID` were dropped as unused.

**Traps hit, for the next build.** (1) On these geodatabases the **SQLite
dialect returns `"geometry":null`** — use the default OGR dialect with `-spat`
for spatial filtering instead of `-dialect SQLITE` with a `WHERE`. (2)
`-overwrite` does **not** truncate a GeoJSONSeq output file; it appends. Both
were caught by the null-geometry/count gates, not after tiling.

**Not yet done:** the app still points at `byu-hydroinformatics.nwm-channels`.
`config.dart`'s `vectorTilesetId` is a one-line change once the new tileset is
reviewed on device. The new tileset's `visibility` is **private**, same as the
others; the app's `pk` token reads it fine.

### `geoglows-world-v2` built and published — zoom 0 now exists (2026-08-17)

**Global stream-order histogram**, counted from `geoglowsv2` in the
map-optimized GDB (6,838,900 total). It behaves nothing like NWM, so NWM's
ladder could not be reused:

| Order | Count | Share | Cumulative ≥ |
|---|---|---|---|
| 1 | 219,290 | 3.2% | 6,838,900 |
| 2 | 2,979,846 | 43.6% | 6,619,610 |
| 3 | 1,829,210 | 26.7% | 3,639,764 |
| 4 | 967,973 | 14.2% | 1,810,554 |
| 5 | 481,181 | 7.0% | 842,581 |
| 6 | 225,259 | 3.3% | 361,400 |
| 7 | 89,060 | 1.3% | 136,141 |
| 8 | 32,060 | 0.47% | 47,081 |
| 9 | 14,041 | 0.21% | 15,021 |
| 10 | 980 | 0.014% | 980 |

Order 1 is 3.2% here versus 52.6% in NWM — TDX-Hydro prunes headwaters, so the
mass sits at order 2-3.

**GEOGLOWS' own pmtiles embeds Riley's recipe** (read from the PMTiles v3
metadata block of `s3://geoglows-v2/hydrography-global/streams.pmtiles`):
`-Z0 -z12 --drop-densest-as-needed --simplification=10` with
`-j '{"*":["any",[">=","strahlerOrder",6],["all",[">=","strahlerOrder",4],[">=","$zoom",6]],[">=","$zoom",8]]}'`.
So GEOGLOWS independently arrived at a stream-order ladder — external
corroboration of the approach. Not copied, for two reasons: they tiled **50
regions separately then `tile-join --no-tile-size-limit`** (the architecture that
banded NWM), and they left `--drop-densest-as-needed` on, which must be firing
at z0 with 361,400 order-≥6 features. Their fields are `riverId`/`strahlerOrder`
in a layer named `streams`, and PMTiles is unreadable by the Flutter Mapbox SDK,
so it is not a drop-in either.

**Zoom-0 probe before committing.** Extracted the 47,081 order-≥8 reaches alone
and tiled z0-3: **z0 = 211.5 KB**, zero warnings. The full build later produced
**exactly 211.5 KB** at z0, so the cheap probe was an exact predictor — worth
repeating for future tilesets.

**Ladder used** (identical shape to NWM's): z0-3 → ≥8; z4-5 → ≥7; z6 → ≥6;
z7 → ≥5; z8 → ≥4; z9 → ≥3; z10-12 → all.

**Both gates passed.** Feature count **6,838,900 exact**; no tile over 500 KB at
any zoom; 3,081,641 tiles; bounds `-171.592466,-55.387306,178.490028,80.325887`
(global, and **no antimeridian wrap** despite the EPSG:3857 → 4326 reprojection).

| Zoom | tiles | max KB |
|---|---|---|
| 0 | 1 | 211.5 |
| 1 | 4 | 188.5 |
| 2 | 10 | 165.1 |
| 4 | 70 | 111.3 |
| 9 | 39,578 | 42.5 |
| 12 | 2,280,082 | 8.2 |

**Cost: 0.752 CU**, 6.66 GB published.

| Tileset | Zoom | Size | CU |
|---|---|---|---|
| `geoglows-world` (old) | 3-12 | 7.74 GB | 0.9187 |
| `geoglows-world-v2` | **0-12** | 6.66 GB | **0.752** |
| `nwm-channels` (old) | 0-16 | 3.54 GB | 77.5468 |
| `nwm-channels-v2` | 0-12 | 0.68 GB | 0.5151 |

(Sizes read from `GET /tilesets/v1/byu-hydroinformatics`; an earlier entry quoted
`nwm-channels` as 3.3 GB from the Studio screenshot — the API says **3.54 GB**.)

**Live verification, old vs new, same tile coordinates:**

| Site | z0 old | z0 new | z2 old | z2 new |
|---|---|---|---|---|
| Amazon | 404 | 200 / 216,537 b | 404 | 200 / 57,881 b |
| Congo | 404 | 200 / 216,537 b | 404 | 200 / 35,018 b |
| Ganges | 404 | 200 / 216,537 b | 404 | 200 / 169,016 b |
| Mekong | 404 | 200 / 216,537 b | 404 | 200 / 83,146 b |
| Danube | 404 | 200 / 216,537 b | 404 | 200 / 169,016 b |
| Patagonia | 404 | 200 / 216,537 b | 404 | 200 / 57,881 b |

Zooms 0-2 went from **404 everywhere** to served. At z4 the new tiles are also
*smaller* than the old ones (Ganges 324,905 → 83,534 b; Danube 170,644 →
34,961 b) because the ladder removes sub-pixel streams instead of paying to
carry then discard them.

**THE BUILD TRAP THAT ALMOST SHIPPED A BROKEN TILESET.** `ogr2ogr` reading the
whole 6.8M-feature GDB in one pass **silently stops at ~680,000 features** —
twice, reproducibly (680,778 writing to a file, 679,108 through a pipe). **Exit
code 0, empty log, no warning.** The resulting tileset built cleanly with zero
tippecanoe warnings and contained **only VPUCodes 101-110 — Africa**, bounds
`-7.0,-34.8,54.4,30.2`. It is **not corrupt data**: VPU 111, past the failure
point, reads 114,294/114,294 on its own.

Fix: **export each of the 125 VPUs separately with a per-region count check
against a manifest, then feed all 125 files to ONE tippecanoe pass.** Per-region
*export* is safe; per-region *tiling* is what caused the NWM banding. All 125
matched exactly; concatenated total 6,838,900. 69 GB of intermediate GeoJSONSeq.

**The only defence against this class of failure is the feature-count gate.**
Exit status and absence of warnings proved nothing. Never publish without
comparing tilestats `count` to the known source count.

**Operational note:** long builds must run under **tmux**, not `nohup … &` in a
harness background task. Three separate long jobs were killed mid-run when their
watcher task was stopped; `setsid` does not exist on macOS. `tmux new-session
-d -s <name>` survived everything. Timings: NWM 2,729,961 features → 2m20s;
GEOGLOWS 6,838,900 → 61 min (z0 alone took ~20 min single-threaded before
parallelism engaged at z6+).

**Not yet done:** the app still points at `geoglows-world` and `nwm-channels`.
`config.dart` needs `vectorTilesetId` → `byu-hydroinformatics.nwm-channels-v2`
and `geoglowsTilesetId` → `byu-hydroinformatics.geoglows-world-v2`. Field
contract is unchanged (`channels` / `station_id` / `streamOrder`, plus `VPUCode`
on GEOGLOWS), so no service code changes. `geoglows-us` has **not** been rebuilt
— Gwen's CONUS-border clip and the lake-crossing decision are still open.

### Flood-flagged reach counts by flow threshold (2026-08-17)

Counted from `mrf_nbm_5day_max_high_flow_magnitude` (CONUS) with
`returnCountOnly`, to decide whether the 17.66 cfs minimum-flow floor is set
sensibly. Service total that day: 89,383.

| Flow threshold | Reaches flagged |
|---|---|
| any | 85,801 |
| ≥ 1 cfs | 55,209 |
| ≥ 5 cfs | 39,396 |
| **≥ 17.66 cfs (current floor)** | **29,575** |
| ≥ 50 cfs | 21,933 |
| ≥ 100 cfs | 17,918 |
| ≥ 500 cfs | 11,511 |
| ≥ 1,000 cfs | 9,388 |
| ≥ 5,000 cfs | 5,298 |

**Correction.** An earlier claim in this session — that the 17.66 cfs floor is
what reduces NOAA's ~89k flagged reaches to the ~4,000 our pipeline publishes —
is **wrong**. The floor accounts for roughly 3× (85,801 → 29,575), not 20×.
**Some other step removes a further ~25,000 reaches and has not been
identified.** Do not build the daily flooded tileset on the current pipeline
output until that is explained.

**Sizing is not a constraint.** Even 85,801 reaches would tile comfortably —
GEOGLOWS' 47,081 order-≥8 reaches produced a 211 KB zoom-0 tile against the
500 KB limit. The floor is therefore a *meaning* decision, not a cost one.

### RESOLVED — the "missing 25,000 reaches" (2026-08-17)

**There are two filters in `_classify_nwm_row` (`functions_geoglows/main.py`),
not one, and the second is the large one.** Counts from NOAA's own service, same
day:

| Filter | Reaches remaining |
|---|---|
| NOAA's flagged set | 85,801 |
| …flow ≥ 17.66 cfs | 29,575 |
| …**and flow ≥ its own `flow_2yr`** | **5,459** |

`5,459` matches the ~4,000 the pipeline publishes, allowing for a different day
plus the Alaska/Hawaii/PRVI services. **Not a bug — deliberate**, and already
documented in that function: NOAA's `recur_cat_5day` includes anything above a
regional *high-water* threshold, which sits below a 2-year event; RIVR's ladder
starts at the 2-year mark (ADR 0002), so a river coloured on the map reads
"Action" or worse when tapped.

Also dropped: **3,110 reaches with a null or zero `flow_2yr`** — a degenerate
return-period curve that cannot be classified.

**Correction to the entry above.** The recommendation of "~5 cfs → 39,396
reaches" was wrong: 39,396 is the count *without* the 2-year gate. Applied
together with it, the floor options are:

| Floor (with 2-year gate) | Reaches |
|---|---|
| 17.66 cfs | 5,459 |
| **5 cfs** | **8,130** |

For reference, relaxing the *gate* instead: no floor + 2-year gate = 21,720;
floor only, no gate = 29,575; everything NOAA flags = 85,801.

### DECIDED — flood inclusion rules (2026-08-17)

- **Minimum flow floor lowered from 17.66 cfs to 5 cfs.** 17.66 was a round
  metric number (0.5 m³/s), not a hazard threshold; flash flooding on small
  creeks is what NWM is uniquely good at. 5 cfs still removes trickles — a
  sampled row showed a 2-year event on a reach flowing 1.06 cfs.
- **The 2-year gate stays.** Consistency with RIVR's own ladder (ADR 0002)
  matters more than volume: dropping it would colour rivers the app's own
  forecast gauge calls Normal.

Net effect: ~5,459 → ~8,130 coloured US reaches.

### DECIDED — horizon labelling (2026-08-17)

GEOGLOWS is 15-day, NOAA CONUS 5-day, Hawaii/PR 48-hour: one tileset, three
horizons. Jerson's decision:

1. **The legend stays vague and honest** — it already reads "Peak risk in the
   days ahead", which is true for all three. No work.
2. **Tap gives the truth** — the reach detail sheet shows that reach's actual
   window ("next 5 days" / "next 15 days" / "next 48 hours"). One line.

Rejected: varying the legend text by camera position. It flickers when panning
across a border and is simply wrong when two regions are on screen at once.

### DECIDED — daily tileset identity and freshness (2026-08-17)

- **One dated tileset per day**, `rivr-flooded-YYYYMMDD`. Mapbox caches tiles
  for 12 hours on device and states the CDN cache cannot be broken; a new ID
  each day has no cache history, so yesterday's colours cannot leak through.
- **Retention 3 days**, then delete. Bounds hosting days and bounds how far the
  app can fall back.
- **Firebase Remote Config is the source of truth** for the current ID plus the
  data date, written by the build job as its **last** step, after Mapbox
  confirms processing — so the note never points at a half-published tileset.
  Chosen over deriving the ID on-device because it keeps control after release:
  kill switch, renaming, staged rollout, no App Store round trip (which matters
  while the Apple account is locked out).
- **On-device date arithmetic is the fallback** if Remote Config is
  unreachable: compute today's ID, step back up to 3 days.
- **Show the data date** above the legend whenever it is not today's, e.g.
  "Conditions from 16 Aug".

### DECIDED — where the daily build runs (2026-08-17)

**Cloud Scheduler → Cloud Run job.** Jerson's earlier "no Cloud Functions"
constraint applies to *painting* streams at request time — the path that sat
between the user and seeing colour — not to an unattended nightly build, where
ten minutes costs nobody anything.

It must be **Cloud Run rather than a Cloud Function** for a concrete reason:
the build needs **tippecanoe**, a compiled binary, which the managed Functions
runtime cannot host. Cloud Run takes a custom container. The Mapbox secret
token moves from `~/.config/rivr/mapbox_sk.token` into Secret Manager.

Not a scale problem: the flooded set is ~220k reaches, and Phase 0 tiled
409,112 in 90 seconds, so the 30-minute scheduled-job ceiling that forced the
old conditions fan-out is not in play.

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

1. ~~Cost of a large `match` expression on device.~~ **RESOLVED — and the
   2026-08-10 answer was WRONG.** It renders without stutter, but it takes
   **8-12 seconds** to apply 85,324 entries; 3,946 takes 3.4s and 100 takes
   2.6s. "No visible stutter" was true and irrelevant — I measured whether the
   map janked, not how long the paint took. The single global blob is NOT
   viable as-is.
2. ~~Whether GEOGLOWS publishes a pre-derived, non-ensemble product.~~
   **RESOLVED 2026-08-10 — it does not.** See Measured. The forecast zarr holds
   only `Qout` plus coordinates, and its chunking forces full ensemble + full
   time reads, so ~398 GB/day is unavoidable when computing from the ensemble.
   This lever is closed; the cost estimate stands as the floor.
3. **GEOGLOWS forecast horizon.** If it is materially longer than NWM's 18
   hours, the same "Extreme" purple means different things by source under one
   legend. Possible correctness issue, not just cosmetic.
4. **Whether station ids partition cleanly by VPU.** Observed non-overlapping
   for 3 of 125 VPUs (410→`440…`, 613→`660…`, 614→`670…`), elevated reaches
   only. If true at full scale, the client could resolve a VPU locally with a
   125-entry table and skip a server round trip.
5. **Cloud Storage bucket existence and write permission** for
   `ciroh-rivr-app` under `jersondevs@gmail.com`. **BLOCKED 2026-08-10:** the
   machine's active gcloud account is `admin@oqupa.com`, which must never be
   used for this project, and its tokens need an interactive re-auth. Nothing
   was run against gcloud. Switch accounts and re-authenticate to unblock.
6. ~~Publish times of the GEOGLOWS daily zarr and NWM cycles.~~ **RESOLVED
   2026-08-10.** GEOGLOWS lands ~10:15-10:30 UTC (two samples); NOAA is hourly,
   ~45 min behind reference time. See Measured.
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
