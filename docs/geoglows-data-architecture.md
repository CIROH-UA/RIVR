# GEOGLOWS data access + geometry hosting — architecture & licensing

Status: Accepted · Last updated: 2026-07-02

This is the decision record for how RIVR consumes GEOGLOWS (River Forecast System v2 /
"RFS v2") data: forecast values and the river-network geometry. Read this before changing
the GEOGLOWS forecast client, the proxy Cloud Function, or the Mapbox stream tileset.

---

## 1. Forecast data — thin Cloud Function proxy (DECISION)

**Decision:** RIVR does NOT read GEOGLOWS forecast data directly on-device. A small
Google Cloud Function (Firebase Functions v2, Python) reads the data server-side via the
maintained `geoglows` Python package and returns slim per-river JSON to the Dart app.

### Why (the constraints that force this)
- **The GEOGLOWS REST API is being retired.** Per Riley Hales (GEOGLOWS Technical Director,
  2026-06/07): it will not be updated for the next model version (~start of 2027) and will be
  shut down at some point later in 2027. So we must not build on `geoglows.ecmwf.int/api`.
- **The data on S3 is Zarr v2 (Blosc/Zstd-compressed chunked arrays).** One river's forecast
  lives in a ~15 MB chunk shared with ~686 neighbor rivers.
- **Dart cannot read Zarr/Blosc.** There is no Dart library for Zarr or Blosc/Zstd. Reading it
  on-device would mean writing a Zarr + Blosc + Zstd decoder in Dart from scratch (large,
  fragile, ongoing maintenance).
- **RIVR is a native mobile app, not a web app.** Riley suggested using JS + node modules
  (zarrita) via Dart JS interop (`dart.dev/interop/js-interop`). That only works for **Flutter
  Web** (Dart compiled to JavaScript). RIVR compiles to native ARM for iOS/Android; there is no
  JS runtime on-device, so js-interop / node modules are not available. This is the decisive
  point — the browser-based approach the GEOGLOWS Hydroviewer uses is not portable to mobile.
- **15 MB per tap on cellular is poor UX** even if the format weren't a blocker.

### Alternatives considered (and rejected)
| Option | Verdict |
|---|---|
| Keep using the REST API | Rejected — being deprecated (~2027). |
| Client-side JS/zarrita via Dart js-interop | Rejected — web-only; RIVR is native mobile. |
| Pure-Dart Zarr + Blosc/Zstd reader | Rejected — no library exists; large + fragile. |
| **Thin server proxy (chosen)** | ~90 lines calling the maintained `geoglows` module; reads S3 directly, so it survives the REST shutdown. |

### The proxy (as deployed)
- **Code:** `functions_geoglows/` (repo). `main.py` = `firebase_functions.https_fn.on_request`.
  A **2nd Firebase codebase** named `geoglows` in `firebase.json`; the existing Node/TS
  notification codebase (`default`) is untouched.
- **Live URL:** `https://us-west1-ciroh-rivr-app.cloudfunctions.net/geoglows_forecast?river_id=<LINKNO>`
- **Runtime/region:** python313, **us-west1** (next to the GEOGLOWS S3 buckets in AWS us-west-2),
  1 GB, gen2, public HTTP. Project `ciroh-rivr-app` (same project as the notification functions —
  "everything in one place" per Dr. Ames).
- **JSON contract:** `{ river_id, forecast_date, units:"m3/s", source:"GEOGLOWS RFS v2",
  forecast:{datetime[],flow_median[],flow_uncertainty_lower[],flow_uncertainty_upper[]},
  ensemble:{datetime[],flow_min[],flow_25p[],flow_med[],flow_75p[],flow_max[]},
  return_periods:{"2":..,"5":..,"10":..,"25":..,"50":..,"100":..} }`. Native m³/s; the Dart app
  converts to the user's unit (`GeoglowsApiService`). NaN -> null.
- **Two non-obvious gotchas baked into the code:**
  1. Return periods MUST be requested with `distribution="gumbel"` — the module's default
     (`logpearson3`) is not in the dataset and errors.
  2. You MUST pass an explicit `date=` (today UTC, fall back to yesterday). Omitting it makes the
     module glob S3 for the latest date = ~35 s. With the date, a fetch is ~1.5-2 s.
- The 3 reads (forecast, forecast_stats, return_periods) run in parallel (ThreadPoolExecutor)
  and results are `lru_cache`d per (river, date).

### Why a proxy is acceptable despite Riley's (valid) cautions
Riley cautioned that a self-run API adds a dependency, cost, maintenance, and fragility. Weighed:
- **Not a new platform dependency** — RIVR already runs on Google Cloud/Firebase (Auth,
  Firestore, FCM, the notification Cloud Functions). This is one more small function.
- **Low maintenance** — it calls the widely-used, maintained `geoglows` module; as long as that
  module's interface is stable (it has many users), the function keeps working even if GEOGLOWS
  changes their REST/DB/Zarr internals.
- **Future-proof** — it reads S3 directly (not the deprecating REST API).

### Cost & latency
- **Latency:** cold start ~9-11 s (heavy Python imports: geoglows/xarray/zarr), warm new-river
  ~3-5 s, warm + cached ~0.13 s. Region us-west1 helps the read; the cold start dominates the
  spikes. (Parallelizing the reads helped only marginally — they are partly CPU-bound under the GIL.)
- **`min_instances`:** kept at **0** (scale to zero) for the POC — near-zero cost, cold starts
  only annoy developers. At launch, either set `min_instances=1` (~$5-15/mo for one always-warm
  instance) OR (better) front the function with a **CDN** (Firebase Hosting rewrite / Cloud CDN;
  the function already sends `Cache-Control: public, max-age=3600`), so popular rivers are cached
  across all users and the function only handles misses. CDN fixes latency AND cost together.
- **Scale:** at RIVR's scale this is a few $/month. Riley's "hundreds-to-thousands/month" is a
  massive-scale, no-caching worst case, mitigated by the CDN plan above.

### Deploy notes (for future devs)
- Deploy only this codebase: `firebase deploy --only functions:geoglows`.
- **Python version gotcha:** Firebase uses the highest *supported* local Python (currently 3.13,
  it skips 3.14). Build the function venv with **python3.13** (`python3.13 -m venv --clear
  functions_geoglows/venv`) or the emulator/deploy can't find the SDK.
- Deploy needs Editor + Firebase Admin (+ Project IAM Admin as a safety net for the first gen2
  deploy's service-account bindings). `jersondevs@gmail.com` has these on `ciroh-rivr-app`.

---

## 2. River geometry — self-hosted Mapbox vector tiles (DECISION)

**Decision:** self-host the GEOGLOWS/TDX-Hydro stream network as Mapbox vector tiles (tap-to-
forecast on the map needs fast, tappable vector features, which raster overlays can't give).
The tile attribute contract mirrors the NWM tiles: layer `channels`, properties `station_id`
(= GEOGLOWS `LINKNO`) and `streamOrder` (= `strmOrder`). Source geometry: the "map-optimized"
GeoPackage in the public `geoglows-v2` S3 bucket. See `reference_nwm_vector_tile_pipeline` memory
+ `docs/internal/action-items.md` for the tiling recipe. Dr. Ames green-lit the whole-world
tileset (~$300-400 one-time Mapbox cost).

---

## 3. Licensing — determination (2026-07-02)

Researched against the **authoritative** documents (not just GEOGLOWS's summary).

**Bottom line: the stream geometry (TDX-Hydro) is CC BY-SA 4.0. Commercial use IS allowed.
There is NO non-commercial restriction in the chain that reaches us.**

- **TDX-Hydro = CC BY-SA 4.0.** Source of truth is NGA's own license file:
  `https://earth-info.nga.mil/php/download.php?file=tdx-hydro-license` —
  *"Copyright (c) 2023 National Geospatial-Intelligence Agency (NGA). The TDX-Hydro datasets are
  licensed under Creative Commons Attribution-ShareAlike 4.0 International... Adapt — remix,
  transform, and build upon the material... even commercially... The TDX-Hydro datasets are
  available for public use."*
- **GEOGLOWS model/forecast data = CC BY 4.0** (`http://geoglows-v2.s3.us-west-2.amazonaws.com/licenses.md`).
- The GEOGLOWS Technical Director initially worried TDX-Hydro was "non-commercial," then walked it
  back. That worry was incorrect — it conflates TDX-Hydro with the RAW TanDEM-X DEM (Airbus/DLR,
  scientific-use-only). NGA cut that restriction off by re-releasing the derived hydrography under
  CC BY-SA 4.0. Downstream users rely on NGA's license, not the upstream DEM terms.

### Obligations (what we must actually do)
1. **Attribution** — add an in-app "Data & Licenses" screen with:
   - Geometry: *"Stream network: TDX-Hydro © 2023 National Geospatial-Intelligence Agency,
     licensed CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). Derived and
     re-tiled by RIVR; changes made."*
   - Hydrologic conditioning: credit GEOGLOWS v2 (CC BY 4.0).
   - Forecast values: ECMWF block *"© 2023 ECMWF, source www.ecmwf.int, CC BY 4.0, no liability."*
2. **ShareAlike** — the derived stream-geometry **tileset-as-data** must be offered under
   CC BY-SA 4.0. You may NOT relicense the geometry tiles as proprietary/closed.
   - **SA does NOT viralize the app.** It covers only the licensed material and its derivatives
     (the geometry/tiles), not independent works bundled alongside (the "mere aggregation"
     distinction). The Dart/Flutter code, UI, and forecast logic stay proprietary.
   - **Consequence for monetization:** RIVR may be a **paid** app — SA governs the *data license*,
     not the app's price. The only thing SA forbids is building a business on keeping the *geometry
     tileset itself* proprietary. That is not RIVR's plan.

### Caveats
- The TDX-Hydro paper's data-availability statement could not be retrieved (essoar DOI returned
  403); it is not load-bearing since NGA's license file is the controlling grant.
- Not legal advice. Before a commercial launch, a one-paragraph IP-attorney confirmation on the
  ShareAlike scoping (point 2) is cheap insurance.

---

## Sources
- NGA TDX-Hydro license: `https://earth-info.nga.mil/php/download.php?file=tdx-hydro-license`
- GEOGLOWS licenses: `http://geoglows-v2.s3.us-west-2.amazonaws.com/licenses.md`
- GEOGLOWS streams/catchments guide: `https://data.geoglows.org/dataset-descriptions/gis-streams-and-catchments`
- AWS Open Data (GEOGLOWS v2): `https://registry.opendata.aws/geoglows-v2/`
- Hydroviewer source (client-side Zarr pattern, web): `github.com/geoglows/rfs-v2-hydroviewer`
- geoglows Python package: `github.com/geoglows/pygeoglows`
- Dart JS interop (web-only): `https://dart.dev/interop/js-interop`
