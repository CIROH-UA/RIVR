# ADR 0004 — Pre-coloring map streams by flood condition

- **Status:** SUPERSEDED by ADR 0005 (2026-08-19). The runtime `match`-expression
  colouring described here was measured at 8-12s on device for ~85k reaches and
  has been removed from the app entirely; the nine highlight layers and every
  condition API were deleted in the styling reset. Colours are now baked into a
  daily tileset. This decision in particular did not survive: "Reuse the existing
  self-hosted vector tiles — re-tiling daily to bake in a status attribute is
  heavy and slow." Re-tiling daily measured **12 seconds** and **0.43 compute
  units**. Kept for the reasoning and the palette work.
- **Original status:** Accepted — GEOGLOWS (phases 0–4) + NWM (phase 3) delivered and verified on device 2026-07-24/25; merged to `development` 2026-07-25.
- **Date:** 2026-07-25
- **Deciders:** Jerson Garcia (lead)
- **Relates to:** `geoglows-data-architecture.md`, ADR 0002 (`0002-canonical-derived-value-layer.md`, the flood-category ladder), `project_map_stream_conditions` (memory)
- **Context source:** Dr. Ames demo (2026-07-22) — his top technical ask.

## Context and problem

HydroViewer (GEOGLOWS web) and the NWM web viewer both show streams **yellow/orange/red for above-normal conditions without the user tapping**. Dr. Ames asked whether RIVR's map could do the same, and how those viewers do it.

The naive approach is impossible on a mobile map: RIVR renders **2.7M NWM + millions of GEOGLOWS** reaches as vector tiles, and you cannot issue a live forecast request per stream to color them. The web viewers don't either — they **precompute condition server-side** and hand the client a small, already-classified layer. RIVR needed the mobile-native equivalent.

## Decision drivers

- **No per-stream live requests.** Coloring must scale to millions of reaches without N requests.
- **Reuse the existing self-hosted vector tiles** (`byu-hydroinformatics.nwm-channels`, GEOGLOWS `geoglows-world`) — re-tiling daily to bake in a status attribute is heavy and slow.
- **One flood-category ladder.** Colors must mean the same thing as the forecast gauge (ADR 0002): Action/Moderate/Major/Extreme at the 2/5/10/25-yr return periods.
- **Best-effort, never blocking.** A coloring fetch must never stall or break the map.
- **Small server footprint.** Prefer the existing Python (`functions_geoglows`) codebase and public open-data over new infrastructure or secrets.

## Decisions

**D1 — Precompute above-normal reaches server-side; data-drive `line-color` on the existing tiles with a Mapbox `match` expression keyed on `station_id`.** The backend returns a compact blob of only the elevated reaches (`{station_id: categoryIndex}`); the client applies it as `["match", ["get","station_id"], id, color, …, baseColor]` on the existing stream layers. Everything "normal" keeps the base color for free — no re-tiling. Validated on device at the time: a **10,000-entry** expression applied in **~34 ms** with no render lag, and this ADR concluded the blob could therefore be large without viewport chunking. **That conclusion did not hold.** Measured 2026-08-11 (ADR 0005): 85,324 entries take **8-12 s** to apply, 3,946 take 3.4 s, 100 are instant. The cost is not linear in the range that matters, and the map now paints the region under the viewport first and the rest afterwards. Treat the 34 ms figure as valid only near 10k entries. Rejected `feature-state`/`promoteId` (flaky on our vector tiles) and, of course, per-stream requests. The primitive is `MapVectorTilesService.applyConditionColors`.

**D2 — GEOGLOWS is resolved per-VPU, on demand, from a reach the client can see.** GEOGLOWS partitions its ~6.84M rivers into 125 VPUs that are **contiguous** in the forecast river ordering, so each VPU is a slice `[i0,i1)` — bundled as a 3.4 KB `vpu_slices.json`, avoiding a 138 MB metadata-table read at runtime. On map idle the client sends one visible `station_id`; the backend maps it to its VPU (LINKNO→VPU index) and returns that VPU's conditions. Results accumulate client-side so revisiting is instant. Rejected client-side bounding-box resolution — VPU bboxes overlap too much near borders (a point could match four VPUs).

**D3 — NWM is classified per visible reach (no region concept).** NWM has no VPU partition and no clean bulk return-period dataset, so the client sends the **feature_ids currently on screen** (`querySourceFeatures`, ≤800) and the backend classifies exactly those. Forecast **peak** = max streamflow over the short-range `channel_rt` hours (NOAA NWM Open Data, `feature_id` sorted, cached per cycle). **Return periods** come from the CIROH API (`nwm-api.ciroh.org/return-period`, batched ≤~500 large ids/call, cached per reach — they're static). A **min-flow floor (0.5 m³/s)** prevents flagging dry headwater trickles whose tiny thresholds are trivially "exceeded". Rejected a daily full-CONUS precompute: NWM return periods aren't bulk-available (the CIROH API is URL-length-limited and computing them from the 43-yr retrospective is a TB-scale job), and per-viewport classification needs neither.

**D4 — Shared category ladder, legend, and toggle.** Category index and colors are the ADR-0002 ladder (Action=yellow #FFC400, Moderate=orange #FF8C00, Major=red #E53935, Extreme=purple #8E24AA; Normal = the base stream color, **#191970 midnight blue since 2026-07-29 — shared by NWM and GEOGLOWS**, so one legend covers both sources; GEOGLOWS no longer uses its brand teal). A compact, collapsible **FLOOD RISK legend** (swatches must stay in sync with the map colors) and a **"Color by flood risk"** switch in the Stream Data sheet cover both networks. The toggle is persisted (`MapPreferenceService.colorByCondition`, default **on** so the map surfaces conditions without opt-in); off resets the streams to base and hides the legend.

**D5 — Backend lives in the Python `functions_geoglows` codebase; NWM key via `.env`, not Secret Manager.** Three `@https_fn` endpoints: `geoglows_stream_conditions` (us-west1, near the GEOGLOWS us-west-2 buckets) and `nwm_stream_conditions` (us-east1, near the NOAA NWM Open Data bucket), alongside the existing `geoglows_forecast` / `geoglows_reach_coords`. The CIROH API key is read from `functions_geoglows/.env` (gitignored, deployed as env var `NWM_API_KEY`) rather than Secret Manager — the deploy account lacks `secretmanager.secrets.setIamPolicy`, and the key already ships inside the client app (`config.dart`), so it is not a high-secrecy value.

## Consequences

- **Cold-start latency is visible but harmless.** A scale-to-zero function's first call for a new region/cycle takes ~10–40 s (S3 reads); streams show their base color until conditions arrive, then recolor. Everything is best-effort — a failure just leaves streams uncolored.
- **Data facts (for future changes):** GEOGLOWS forecast + return periods share one river ordering; return-period years are `[2,5,10,25,50,100]`; NWM `channel_rt` `feature_id` is sorted (binary-searchable); the CIROH GET URL caps around ~2000 small / ~500 large ids.
- **Not yet:** NWM uses the near-term short-range horizon (medium-range isn't on the mirror we read); the global GEOGLOWS blob is per-VPU on demand rather than a single precomputed world file.

## How to change it safely

- Colors live in **two** places that must match: `MapVectorTilesService` (`_categoryColors`, base colors) and `ConditionLegend._entries`. Change both.
- Category thresholds are the ADR-0002 ladder — keep them aligned with `FlowClassification`.
- Backend: `functions_geoglows/main.py`. Deploy one function with `firebase deploy --only functions:geoglows:<name>`. `vpu_slices.json` is bundled; regenerate it only if the GEOGLOWS river set changes.
