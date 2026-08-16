"""GEOGLOWS forecast proxy — Firebase Cloud Function (2nd gen, Python).

Reads GEOGLOWS RFS v2 data straight from S3 via the maintained `geoglows`
Python package and returns slim per-river JSON, so the RIVR Dart app never
touches the (deprecating) REST API or downloads 15 MB Zarr chunks on-device.

Deployed as its own Firebase codebase ("geoglows") alongside the existing
Node/TS notification functions — see firebase.json. Deploy just this one with:
    firebase deploy --only functions:geoglows

Endpoint:  GET ?river_id=<LINKNO>
Returns:   { river_id, forecast_date, units, source,
             forecast: {datetime[], flow_median[], flow_uncertainty_lower[], flow_uncertainty_upper[]},
             ensemble: {datetime[], flow_min[], flow_25p[], flow_med[], flow_75p[], flow_max[]},
             return_periods: {"2":..,"5":..,"10":..,"25":..,"50":..,"100":..} }
"""

import base64
import io
import json
import math
import os
import threading
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from functools import lru_cache

import numpy as np
import pandas as pd
import requests
import s3fs
import xarray as xr
import zarr
from firebase_functions import https_fn, options, pubsub_fn, scheduler_fn

# NOTE: `geoglows` is NOT imported here. It takes ~12s to import (measured),
# which alone exceeds the 10s budget the Firebase CLI allows for loading this
# module to discover function signatures — deploys fail outright. It is also
# dead weight for every endpoint except the forecast one, so importing it
# lazily keeps cold starts off the conditions and coords paths too.

# NWM (US National Water Model) — the same "flood category" coloring as GEOGLOWS,
# but for US streams. Forecast peak comes from the short-range channel_rt files
# on the NOAA NWM Open Data bucket; return periods come from the CIROH API
# (batched). Key held in Secret Manager, not committed.
_NWM_SHORT_RANGE = "noaa-nwm-pds/nwm.{day}/short_range"
_NWM_CHANNEL_RT = "nwm.{cycle}.short_range.channel_rt.f{hour:03d}.conus.nc"
_CIROH_RP_URL = "https://nwm-api.ciroh.org/return-period"
# The CIROH key already ships inside the client app, so it lives in the codebase
# .env (gitignored, deployed as an env var) rather than Secret Manager.
# Don't flag near-dry headwaters: a trickle can "exceed" a tiny return period.
_NWM_MIN_FLOW_CMS = 0.5
# Cap per request so the CIROH URL + our own query stay well under length limits.
_NWM_MAX_IDS = 800

# GEOGLOWS open-data on S3 (anonymous). Daily global forecast (raw ensemble) and
# the retrospective-derived Gumbel return periods share the same river ordering.
_FORECAST_ZARR = "geoglows-v2-forecasts/{date}00.zarr"
_RETURN_PERIODS_ZARR = "geoglows-v2/retrospective/return-periods.zarr"


# Bundled VPU -> [i0, i1) slice into the (contiguous) river ordering, so we can
# read one region's forecast + return periods without loading the 240 MB model
# table at runtime. Generated offline from the model table; see git history.
with open(os.path.join(os.path.dirname(__file__), "vpu_slices.json")) as _f:
    _VPU_SLICES = json.load(_f)["slices"]

# Return-period recurrence-year -> flood category index, matching the app's
# FlowClassification (Action/Moderate/Major/Extreme at 2/5/10/25-yr). Higher
# exceeded threshold wins. Reaches below the 2-yr stay "normal" (0, omitted).
_RP_CATEGORY = [(25, 4), (10, 3), (5, 2), (2, 1)]

UNITS = "m3/s"
SOURCE = "GEOGLOWS RFS v2"

# Static per-river metadata (LINKNO, VPUCode, lat, lon) for all ~6.8M GEOGLOWS
# reaches. The geoglows model uses these to place streams; RIVR uses lat/lon to
# reverse-geocode a reach to a city/country. ~138 MB parquet, 7 unsorted row
# groups — so a filtered S3 read can't prune and scans everything (~25-30s).
# Instead we load it once per warm instance into a sorted in-memory index and
# binary-search it (sub-ms). See geoglows_reach_coords.
_METADATA_URL = (
    "http://geoglows-v2.s3-website-us-west-2.amazonaws.com/"
    "tables/package-metadata-table.parquet"
)

_JSON_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "public, max-age=3600",
}


def _candidate_dates():
    # Forecasts publish daily at 00Z (UTC); today's may not be up early, so
    # fall back to yesterday. NEVER omit the date (that triggers a ~35s S3 glob).
    today = datetime.now(timezone.utc).date()
    return [today.strftime("%Y%m%d"), (today - timedelta(days=1)).strftime("%Y%m%d")]


def _iso(index):
    return [t.isoformat() for t in index]


def _col(df, name):
    out = []
    for v in df[name].tolist():
        out.append(None if (v is None or (isinstance(v, float) and math.isnan(v))) else round(float(v), 3))
    return out


@lru_cache(maxsize=1024)
def _build_payload(river_id: int, forecast_date: str) -> str:
    """Fetch + shape one river for a specific date. Cached per (river, date) so
    repeat taps of the same river are instant. Raises if the date isn't published.

    The three S3 reads (forecast, stats, return periods) are independent, so run
    them in parallel — they are I/O-bound (network), so threads release the GIL
    and overlap. This cuts a ~3x-sequential wait down to ~1x the slowest read."""
    with ThreadPoolExecutor(max_workers=3) as pool:
        import geoglows  # deferred: ~12s import, see note at top of file

        fc_future = pool.submit(geoglows.data.forecast, river_id=river_id, date=forecast_date)
        fs_future = pool.submit(geoglows.data.forecast_stats, river_id=river_id, date=forecast_date)
        rp_future = pool.submit(geoglows.data.return_periods, river_id=river_id, distribution="gumbel")
        fc = fc_future.result()
        fs = fs_future.result()
        rp = rp_future.result()

    rp_series = rp[river_id] if river_id in rp.columns else rp.iloc[:, 0]
    return_periods = {str(int(k)): round(float(v), 3) for k, v in rp_series.items()}

    payload = {
        "river_id": river_id,
        "forecast_date": forecast_date,
        "units": UNITS,
        "source": SOURCE,
        "forecast": {
            "datetime": _iso(fc.index),
            "flow_median": _col(fc, "flow_median"),
            "flow_uncertainty_lower": _col(fc, "flow_uncertainty_lower"),
            "flow_uncertainty_upper": _col(fc, "flow_uncertainty_upper"),
        },
        "ensemble": {
            "datetime": _iso(fs.index),
            "flow_min": _col(fs, "flow_min"),
            "flow_25p": _col(fs, "flow_25p"),
            "flow_med": _col(fs, "flow_med"),
            "flow_75p": _col(fs, "flow_75p"),
            "flow_max": _col(fs, "flow_max"),
        },
        "return_periods": return_periods,
    }
    return json.dumps(payload)


def _resolve(river_id: int) -> str:
    errors = []
    for d in _candidate_dates():
        try:
            return _build_payload(river_id, d)
        except Exception as e:  # date not published yet, or river not found
            errors.append(f"{d}: {type(e).__name__}")
    raise RuntimeError(f"no forecast for river_id {river_id} ({'; '.join(errors)})")


# --- reach coordinates (river_id -> lat/lon) ---------------------------------

_coords_lock = threading.Lock()
# (ids_sorted[int64], lat[float64], lon[float64]) or None until first load.
_coords_index = None


def _load_coords_index():
    """Download the GEOGLOWS metadata table once per instance and cache a
    LINKNO-sorted (ids, lat, lon) index for binary-search lookups. Thread-safe
    (double-checked lock) so concurrent first requests load it only once."""
    global _coords_index
    if _coords_index is not None:
        return _coords_index
    with _coords_lock:
        if _coords_index is not None:
            return _coords_index
        raw = requests.get(_METADATA_URL, timeout=90).content
        df = pd.read_parquet(io.BytesIO(raw), columns=["LINKNO", "lat", "lon"])
        ids = df["LINKNO"].to_numpy()
        lat = df["lat"].to_numpy()
        lon = df["lon"].to_numpy()
        del df, raw
        order = np.argsort(ids, kind="stable")
        _coords_index = (ids[order], lat[order], lon[order])
        return _coords_index


def _lookup_coords(river_id: int):
    ids, lat, lon = _load_coords_index()
    i = int(np.searchsorted(ids, river_id))
    if 0 <= i < len(ids) and int(ids[i]) == river_id:
        return round(float(lat[i]), 6), round(float(lon[i]), 6)
    return None


@https_fn.on_request(
    region="us-west1",  # next to the GEOGLOWS S3 buckets (us-west-2) to cut read latency
    memory=options.MemoryOption.GB_2,  # ~1.1 GB transient parse peak; ~164 MB resident index
    timeout_sec=90,
    # Scale to zero. First call per instance downloads + parses the ~138 MB
    # metadata parquet (~5s) then caches a sorted in-memory index; later calls
    # are sub-millisecond. Kept a SEPARATE function from geoglows_forecast so its
    # index never shares memory with the forecast path's xarray/zarr machinery.
    # The app resolves each reach's coords once and persists them, so calls here
    # are rare.
)
def geoglows_reach_coords(req: https_fn.Request) -> https_fn.Response:
    rid = req.args.get("river_id")
    if not rid:
        return https_fn.Response(json.dumps({"error": "missing river_id"}), status=400, headers=_JSON_HEADERS)
    try:
        river_id = int(rid)
    except ValueError:
        return https_fn.Response(json.dumps({"error": "river_id must be an integer"}), status=400, headers=_JSON_HEADERS)
    try:
        coords = _lookup_coords(river_id)
    except Exception as e:
        return https_fn.Response(json.dumps({"error": f"{type(e).__name__}: {e}"}), status=502, headers=_JSON_HEADERS)
    if coords is None:
        return https_fn.Response(json.dumps({"error": f"river_id {river_id} not found"}), status=404, headers=_JSON_HEADERS)
    lat, lon = coords
    return https_fn.Response(
        json.dumps({"river_id": river_id, "lat": lat, "lon": lon}),
        status=200,
        # Coordinates are static, so let clients/CDNs cache them for a long time.
        headers={**_JSON_HEADERS, "Cache-Control": "public, max-age=31536000, immutable"},
    )


# --- stream conditions (per-VPU flood category for map coloring) -------------

_s3_lock = threading.Lock()
_s3fs = None

# LINKNO-sorted (station id -> VPU code) index, so the map can resolve which VPU
# a visible reach belongs to from a single station id (exact — no spatial
# guesswork). Lazily loaded from the metadata table, cached per instance.
_linkno_vpu_lock = threading.Lock()
_linkno_vpu = None  # (ids_sorted[int64], vpu[int64]) or None


def _load_linkno_vpu():
    global _linkno_vpu
    if _linkno_vpu is not None:
        return _linkno_vpu
    with _linkno_vpu_lock:
        if _linkno_vpu is not None:
            return _linkno_vpu
        raw = requests.get(_METADATA_URL, timeout=90).content
        df = pd.read_parquet(io.BytesIO(raw), columns=["LINKNO", "VPUCode"])
        ids = df["LINKNO"].to_numpy()
        vpu = df["VPUCode"].to_numpy()
        del df, raw
        order = np.argsort(ids, kind="stable")
        _linkno_vpu = (ids[order], vpu[order])
        return _linkno_vpu


def _vpu_for_station(station_id: int):
    ids, vpu = _load_linkno_vpu()
    i = int(np.searchsorted(ids, station_id))
    if 0 <= i < len(ids) and int(ids[i]) == station_id:
        return int(vpu[i])
    return None


def _s3():
    global _s3fs
    if _s3fs is None:
        with _s3_lock:
            if _s3fs is None:
                _s3fs = s3fs.S3FileSystem(anon=True)
    return _s3fs


def _forecast_date():
    """Newest published daily forecast date (today, else yesterday)."""
    fs = _s3()
    today = datetime.now(timezone.utc).date()
    for d in (today, today - timedelta(days=1)):
        ds = d.strftime("%Y%m%d")
        if fs.exists(_FORECAST_ZARR.format(date=ds) + "/.zmetadata"):
            return ds
    raise RuntimeError("no recent GEOGLOWS forecast published")


@lru_cache(maxsize=256)
def _conditions_for_vpu(vpu: str, date: str) -> str:
    """Compute the above-normal reaches for one VPU on one forecast date.

    Reads the region's forecast slice (raw ensemble) and its Gumbel return
    periods, derives each reach's forecast peak (median over ensembles, max over
    the horizon), classifies it against the return periods, and returns JSON of
    only the elevated reaches: {station_id: categoryIndex}. Cached per (vpu,
    date) — the heavy read runs once per day per region."""
    slc = _VPU_SLICES.get(str(vpu))
    if slc is None:
        raise ValueError(f"unknown vpu {vpu}")
    i0, i1 = slc
    fs = _s3()

    fz = zarr.open(s3fs.S3Map(_FORECAST_ZARR.format(date=date), s3=fs), mode="r")
    rp = zarr.open(s3fs.S3Map(_RETURN_PERIODS_ZARR, s3=fs), mode="r")

    rivids = fz["rivid"][i0:i1]
    n = i1 - i0

    # Forecast peak per reach, streamed in blocks to bound memory.
    #
    # Over the FULL published horizon — ~15 days (280 steps: hourly for the
    # first 240 h, then 3-hourly, decoded from the time axis 2026-08-11).
    #
    # This was briefly truncated to 5 days so it would match NOAA's US product
    # and satisfy ADR 0002's "a colour means one thing everywhere". Reverted on
    # Jerson's call 2026-08-11: truncating discards real forecast signal — a
    # river flooding in week two simply vanished from the map — and the horizon
    # mismatch is a labelling problem, not a reason to throw the data away.
    # The map therefore shows 15 days outside the US, 5 days across CONUS and
    # Alaska, and 48 hours in Hawaii and Puerto Rico. Communicating that is
    # still open.
    peak = np.empty(n, dtype="f4")
    block = 4000
    for s in range(0, n, block):
        e = min(s + block, n)
        q = fz["Qout"][:, :, i0 + s : i0 + e]  # [ensemble, time, block]
        peak[s:e] = np.nanmax(np.median(q, axis=0), axis=0)

    years = rp["return_period"][:].tolist()
    row = {int(y): k for k, y in enumerate(years)}
    gum = rp["gumbel"][:, i0:i1]  # [return_period, n]

    conditions = {}
    for i in range(n):
        p = peak[i]
        for year, cat in _RP_CATEGORY:  # highest exceeded wins
            if p >= gum[row[year], i]:
                conditions[str(int(rivids[i]))] = cat
                break

    return json.dumps(
        {"vpu": int(vpu), "date": date, "count": len(conditions), "conditions": conditions}
    )


@https_fn.on_request(
    region="us-west1",  # next to the GEOGLOWS S3 buckets (us-west-2)
    memory=options.MemoryOption.GB_4,  # blockwise read keeps well under this
    timeout_sec=180,
    # Scale to zero. First call per (vpu, date) reads ~1-3 GB of forecast from S3
    # (~15-30s) then caches the tiny elevated-reach blob; later calls are
    # instant. The app fetches conditions asynchronously and colors streams when
    # they arrive, so this latency never blocks the map.
)
def geoglows_stream_conditions(req: https_fn.Request) -> https_fn.Response:
    # Resolve the target VPU either directly (?vpu=) or from a reach the client
    # can see (?station_id=) — the latter lets the map color whatever region is
    # on screen without knowing VPU boundaries.
    vpu = req.args.get("vpu")
    station_id = req.args.get("station_id")
    if not vpu and station_id:
        try:
            vpu = _vpu_for_station(int(station_id))
        except ValueError:
            return https_fn.Response(
                json.dumps({"error": "station_id must be an integer"}),
                status=400, headers=_JSON_HEADERS,
            )
        if vpu is None:
            return https_fn.Response(
                json.dumps({"error": f"unknown station_id {station_id}"}),
                status=404, headers=_JSON_HEADERS,
            )
    if not vpu:
        return https_fn.Response(
            json.dumps({"error": "missing vpu or station_id"}),
            status=400, headers=_JSON_HEADERS,
        )
    if str(vpu) not in _VPU_SLICES:
        return https_fn.Response(
            json.dumps({"error": f"unknown vpu {vpu}"}), status=404, headers=_JSON_HEADERS
        )
    try:
        date = _forecast_date()
        payload = _conditions_for_vpu(str(vpu), date)
    except Exception as e:
        return https_fn.Response(
            json.dumps({"error": f"{type(e).__name__}: {e}"}), status=502, headers=_JSON_HEADERS
        )
    # Conditions change once daily; let clients cache for a few hours.
    return https_fn.Response(
        payload,
        status=200,
        headers={**_JSON_HEADERS, "Cache-Control": "public, max-age=10800"},
    )


# --- NWM (US) stream conditions ----------------------------------------------

_nwm_lock = threading.Lock()
_nwm_peak = None  # (cycle_key, ids_sorted[int], peak[f4]) — cached per cycle
_rp_cache = {}    # feature_id -> return-period dict, or None if unavailable


def _latest_nwm_cycle():
    """Newest short-range cycle that has a full f001..f018 run published."""
    fs = _s3()
    now = datetime.now(timezone.utc)
    for dt in (now, now - timedelta(days=1)):
        day = dt.strftime("%Y%m%d")
        d = _NWM_SHORT_RANGE.format(day=day)
        if not fs.exists(d):
            continue
        for hour in range(23, -1, -1):
            cyc = f"t{hour:02d}z"
            last = f"{d}/{_NWM_CHANNEL_RT.format(cycle=cyc, hour=18)}"
            if fs.exists(last):
                return day, cyc
    raise RuntimeError("no NWM short-range cycle published")


def _load_nwm_peak():
    """Peak streamflow per reach over the short-range horizon (max over the
    forecast hours), for the newest cycle. Cached per cycle in memory — the
    read runs once, later requests reuse it. feature_id is sorted, so callers
    binary-search it."""
    global _nwm_peak
    day, cyc = _latest_nwm_cycle()
    key = f"{day}.{cyc}"
    if _nwm_peak is not None and _nwm_peak[0] == key:
        return _nwm_peak[1], _nwm_peak[2]
    with _nwm_lock:
        if _nwm_peak is not None and _nwm_peak[0] == key:
            return _nwm_peak[1], _nwm_peak[2]
        fs = _s3()
        base = _NWM_SHORT_RANGE.format(day=day)
        peak = None
        ids = None
        # Every 2nd hour is enough to catch the peak of a smooth short-range
        # hydrograph while halving the read.
        for hour in range(1, 19, 2):
            path = f"{base}/{_NWM_CHANNEL_RT.format(cycle=cyc, hour=hour)}"
            with fs.open(path) as fh:
                ds = xr.open_dataset(fh, engine="h5netcdf")
                sf = ds["streamflow"].values
                if peak is None:
                    peak = sf.astype("f4")
                    ids = ds["feature_id"].values
                else:
                    np.maximum(peak, sf, out=peak)
        _nwm_peak = (key, ids, peak)
        return ids, peak


def _return_periods_for(feature_ids):
    """Return-period thresholds per reach from the CIROH API, batched and cached
    (return periods are static). Missing reaches map to None."""
    need = [f for f in feature_ids if f not in _rp_cache]
    key = os.environ.get("NWM_API_KEY", "")
    for s in range(0, len(need), 500):
        batch = need[s : s + 500]
        url = f"{_CIROH_RP_URL}?comids=" + ",".join(map(str, batch)) + f"&key={key}"
        try:
            data = requests.get(url, timeout=60).json()
            seen = set()
            for r in data:
                fid = r.get("feature_id")
                if fid is not None:
                    _rp_cache[int(fid)] = r
                    seen.add(int(fid))
            for f in batch:
                if f not in seen:
                    _rp_cache[f] = None
        except Exception:
            for f in batch:
                _rp_cache.setdefault(f, None)
    return {f: _rp_cache.get(f) for f in feature_ids}


def _classify_nwm(feature_ids):
    """Flood category (1..4) for each above-normal reach in [feature_ids]."""
    ids, peak = _load_nwm_peak()
    rp = _return_periods_for(feature_ids)
    out = {}
    for f in feature_ids:
        i = int(np.searchsorted(ids, f))
        if not (0 <= i < len(ids) and int(ids[i]) == f):
            continue
        p = float(peak[i])
        if p < _NWM_MIN_FLOW_CMS:
            continue
        r = rp.get(f)
        if not r or r.get("return_period_2") is None:
            continue
        cat = 0
        for year, c in ((2, 1), (5, 2), (10, 3), (25, 4)):
            thr = r.get(f"return_period_{year}")
            if thr is not None and p >= thr:
                cat = c
        if cat > 0:
            out[str(f)] = cat
    return out


@https_fn.on_request(
    region="us-east1",  # next to the NOAA NWM Open Data bucket (us-east-1)
    memory=options.MemoryOption.GB_4,  # holds the 2.78M-reach peak array
    timeout_sec=300,
)
def nwm_stream_conditions(req: https_fn.Request) -> https_fn.Response:
    raw = req.args.get("station_ids")
    if not raw:
        return https_fn.Response(
            json.dumps({"error": "missing station_ids"}),
            status=400, headers=_JSON_HEADERS,
        )
    try:
        ids = [int(x) for x in raw.split(",") if x][:_NWM_MAX_IDS]
    except ValueError:
        return https_fn.Response(
            json.dumps({"error": "station_ids must be comma-separated integers"}),
            status=400, headers=_JSON_HEADERS,
        )
    try:
        day, cyc = _latest_nwm_cycle()
        conditions = _classify_nwm(ids)
    except Exception as e:
        return https_fn.Response(
            json.dumps({"error": f"{type(e).__name__}: {e}"}),
            status=502, headers=_JSON_HEADERS,
        )
    return https_fn.Response(
        json.dumps({"date": day, "cycle": cyc, "count": len(conditions),
                    "conditions": conditions}),
        status=200,
        headers={**_JSON_HEADERS, "Cache-Control": "public, max-age=3600"},
    )


@https_fn.on_request(
    region="us-west1",  # next to the GEOGLOWS S3 buckets (us-west-2) to cut read latency
    memory=options.MemoryOption.GB_1,
    timeout_sec=120,
    # min_instances=0 (scale to zero) — no idle cost. First tap after the
    # function sleeps eats a ~10-30s cold start (heavy geoglows/xarray/zarr
    # imports); the app-side timeout is set generously to absorb it.
)
def geoglows_forecast(req: https_fn.Request) -> https_fn.Response:
    rid = req.args.get("river_id")
    if not rid:
        return https_fn.Response(json.dumps({"error": "missing river_id"}), status=400, headers=_JSON_HEADERS)
    try:
        river_id = int(rid)
    except ValueError:
        return https_fn.Response(json.dumps({"error": "river_id must be an integer"}), status=400, headers=_JSON_HEADERS)
    try:
        return https_fn.Response(_resolve(river_id), status=200, headers=_JSON_HEADERS)
    except Exception as e:
        return https_fn.Response(json.dumps({"error": f"{type(e).__name__}: {e}"}), status=502, headers=_JSON_HEADERS)


# ---------------------------------------------------------------------------
# Daily precompute — turn the on-demand read into a static file
#
# Computing conditions when a user pans is the wrong shape: the data changes
# once a day, but every new region costs a fresh 15-300s read (ADR 0005). Worse,
# the largest VPUs cannot finish inside the request timeout at all, so ~a third
# of the world's rivers never colour no matter how long anyone waits.
#
# So compute all 125 regions once, after the daily forecast lands, and write
# each as a small JSON blob. The app then does a CDN read instead of triggering
# a computation.
#
# Shape is forced by two measured limits. The whole world takes ~120 min
# serially, which blows past the 30-min ceiling on scheduled functions — so one
# job cannot do it. But the largest single VPU is ~302s, which fits inside the
# 540s ceiling on Pub/Sub-triggered functions. Hence scheduler -> 125 messages
# -> one worker per region.
# ---------------------------------------------------------------------------

_CONDITIONS_BUCKET = os.environ.get("CONDITIONS_BUCKET", "ciroh-rivr-app-conditions")
_CONDITIONS_TOPIC = "geoglows-conditions-vpu"


def _storage_client():
    from google.cloud import storage  # imported lazily; unused by the HTTP paths
    return storage.Client()


def _blob_path(date: str, vpu) -> str:
    return f"conditions/geoglows/{date}/vpu-{vpu}.json"


def _write_blob(path: str, payload: str) -> None:
    """Publish one conditions file, public and briefly cacheable.

    Cache-Control is short relative to the daily refresh so a client that asks
    mid-publish is never stuck with a stale file for long; the path is
    date-stamped anyway, so a new day is always a new URL.
    """
    blob = _storage_client().bucket(_CONDITIONS_BUCKET).blob(path)
    blob.cache_control = "public, max-age=900"
    blob.upload_from_string(payload, content_type="application/json")


@scheduler_fn.on_schedule(
    # GEOGLOWS publishes the daily run around 10:15-10:30 UTC (measured from S3
    # Last-Modified on two consecutive days). 11:00 leaves margin without
    # letting the data go stale into the user's morning.
    schedule="0 11 * * *",
    timezone=scheduler_fn.Timezone("UTC"),
    region="us-west1",
    memory=options.MemoryOption.MB_512,
    timeout_sec=540,
)
def geoglows_conditions_refresh(event: scheduler_fn.ScheduledEvent) -> None:
    """Fan out one message per VPU. Does no reading itself — it just decides
    which date to build and hands the work to the workers."""
    from google.cloud import pubsub_v1

    date = _forecast_date()
    publisher = pubsub_v1.PublisherClient()
    topic = publisher.topic_path(os.environ["GCLOUD_PROJECT"], _CONDITIONS_TOPIC)

    # publish() is asynchronous — it hands back a future and returns
    # immediately. Returning from this function without resolving them drops
    # the messages on the floor, silently: the loop completes, the count looks
    # right, and no worker ever runs. Block on every future so the log reflects
    # what was actually accepted by Pub/Sub.
    futures = [
        publisher.publish(topic, json.dumps({"vpu": vpu, "date": date}).encode())
        for vpu in _VPU_SLICES
    ]

    published, failed = 0, []
    for vpu, future in zip(_VPU_SLICES, futures):
        try:
            future.result(timeout=60)
            published += 1
        except Exception as e:
            failed.append(f"{vpu}:{type(e).__name__}")

    print(
        f"geoglows_conditions_refresh: published {published}/{len(futures)} "
        f"VPUs for {date}" + (f"; failed {failed}" if failed else "")
    )
    if failed:
        raise RuntimeError(f"{len(failed)} VPU messages failed to publish")


@pubsub_fn.on_message_published(
    topic=_CONDITIONS_TOPIC,
    region="us-west1",
    memory=options.MemoryOption.GB_4,
    # One region per instance. Cloud Run packs concurrent requests onto a single
    # instance by default, and each region holds a ~233 MB forecast block while
    # it works; two or three at once exceeded 4 GiB and the instances were
    # killed mid-computation. The work is memory-bound, not IO-bound, so there
    # is nothing to gain from sharing an instance anyway.
    concurrency=1,
    # Bound the fan-out. 125 regions at once would also hammer the same S3
    # bucket — measured throughput already fell from ~950 to 300-670 rivers/s at
    # a concurrency of only 3, so more parallelism buys less than it looks.
    max_instances=20,
    # The largest VPU (286,905 rivers at ~950 rivers/s) needs ~302s. 540s is the
    # ceiling for this trigger type and leaves room for a cold start on top.
    timeout_sec=540,
    # Deliberately no retry. Retried executions persist for up to 7 days and
    # are billed each attempt, so a region that simply cannot finish inside the
    # timeout would burn money failing repeatedly. A missed region is cheap by
    # comparison: the merge step tolerates and logs it, the per-VPU blob from
    # the previous day remains, and tomorrow's run fixes it.
)
def geoglows_conditions_worker(event: pubsub_fn.CloudEvent) -> None:
    """Compute one region and write its blob. Reuses the same
    `_conditions_for_vpu` the live endpoint uses, so precomputed and on-demand
    results cannot drift apart."""
    msg = json.loads(base64.b64decode(event.data.message.data).decode())
    vpu, date = msg["vpu"], msg["date"]

    payload = _conditions_for_vpu(str(vpu), date)
    _write_blob(_blob_path(date, vpu), payload)

    count = json.loads(payload).get("count")
    print(f"geoglows_conditions_worker: vpu={vpu} date={date} elevated={count}")


@scheduler_fn.on_schedule(
    # Half an hour after the fan-out. The whole world takes ~120 min of compute
    # but the workers run concurrently, so the tail is the largest single VPU
    # (~302s) plus queue time. Merging whatever exists is deliberate: a late or
    # failed region simply isn't in today's global file, and the per-VPU blobs
    # remain the authoritative fallback.
    schedule="30 11 * * *",
    timezone=scheduler_fn.Timezone("UTC"),
    region="us-west1",
    memory=options.MemoryOption.GB_1,
    timeout_sec=540,
)
def geoglows_conditions_publish_global(event: scheduler_fn.ScheduledEvent) -> None:
    """Merge the per-VPU blobs into one world file, grouped by region.

    One download still carries every elevated reach on earth, so the app never
    fetches per region. But the reaches are grouped by VPU rather than poured
    into one flat map, because *applying* them is what costs time on device:
    measured at 85,324 entries the map takes 8-12s to paint, at ~3,900 it takes
    3.4s, and at 100 it takes 2.6s. Grouping lets the client paint the region
    under the viewport immediately and backfill the rest afterwards.

    `conditions` is kept alongside `by_vpu` so an older client still works.
    """
    date = _forecast_date()
    bucket = _storage_client().bucket(_CONDITIONS_BUCKET)

    by_vpu, merged, present, missing = {}, {}, [], []
    for vpu in _VPU_SLICES:
        blob = bucket.blob(_blob_path(date, vpu))
        if not blob.exists():
            missing.append(vpu)
            continue
        conds = json.loads(blob.download_as_text()).get("conditions", {})
        if conds:
            by_vpu[str(vpu)] = conds
        merged.update(conds)
        present.append(vpu)

    payload = json.dumps({
        "date": date,
        "count": len(merged),
        "vpus": len(present),
        "vpus_missing": missing,
        "by_vpu": by_vpu,
        "conditions": merged,
    })
    _write_blob(f"conditions/geoglows/{date}/global.json", payload)
    _write_blob("conditions/geoglows/latest.json", payload)

    print(
        f"geoglows_conditions_publish_global: {len(merged)} elevated reaches "
        f"from {len(present)}/{len(_VPU_SLICES)} VPUs for {date}"
        + (f"; missing {missing}" if missing else "")
    )


@https_fn.on_request(
    region="us-west1",  # same region as the bucket, so the read is a local hop
    memory=options.MemoryOption.MB_512,
    timeout_sec=60,
    # Scale to zero — no idle cost. A warm instance removes a ~7.5s cold start
    # (measured) and is worth ~$3/month when the app is in use, but it bills
    # continuously whether anyone opens the map or not. Turned off 2026-08-16 at
    # Jerson's request to stop spend; set back to 1 before any real usage.
)
def geoglows_conditions_latest(req: https_fn.Request) -> https_fn.Response:
    """Serve the precomputed world file.

    Ideally the app would read the blob straight from Cloud Storage over the
    CDN, but an org policy on this project forbids public buckets, so the file
    is served through here instead. That costs one function hop rather than a
    CDN read — still a download of an already-computed answer rather than a
    15-300s computation, which is the point.

    The response is cached client-side; the underlying file changes once a day.
    """
    try:
        blob = _storage_client().bucket(_CONDITIONS_BUCKET).blob(
            "conditions/geoglows/latest.json"
        )
        if not blob.exists():
            return https_fn.Response(
                json.dumps({"error": "not published yet", "conditions": {}}),
                status=404, headers=_JSON_HEADERS,
            )
        return https_fn.Response(
            blob.download_as_text(),
            status=200,
            headers={**_JSON_HEADERS, "Cache-Control": "public, max-age=900"},
        )
    except Exception as e:
        return https_fn.Response(
            json.dumps({"error": f"{type(e).__name__}: {e}"}),
            status=502, headers=_JSON_HEADERS,
        )


# ---------------------------------------------------------------------------
# NWM (US) daily conditions — from NOAA's published 5-day service
#
# NOAA already computes, hourly-to-6-hourly, which CONUS reaches are running
# high, and publishes it with the raw numbers attached. That replaces what this
# codebase used to do for NWM: read 9 short-range NetCDF files (27.5s for the
# whole country) and then call the CIROH return-period API per reach in batches
# of 500. We keep our own classification and apply it to their numbers.
#
# Why the 5-day service rather than the hourly "analysis" one:
#   - It is the *peak over the next 5 days*, which is the question a person
#     actually has, and it matches how GEOGLOWS is already classified (peak over
#     its forecast) so the two halves of the map agree.
#   - It refreshes every 6 hours rather than hourly, so four sweeps a day keeps
#     it current instead of twenty-four.
#   - It covers more reaches: 82,882 vs 63,826 (measured 2026-08-11).
# ---------------------------------------------------------------------------

_NWM_BASE = "https://maps.water.noaa.gov/server/rest/services/nwm"

# The US is not one service. NOAA publishes the 5-day peak for CONUS and Alaska,
# but Hawaii and Puerto Rico/Virgin Islands only exist on the 48-hour product —
# there is no 5-day variant for them (checked 2026-08-11). Field names differ
# too: CONUS calls the peak `maxflow_5day_cfs`, everywhere else `max_flow`.
#
# (service, flow field, horizon label)
_NWM_SERVICES = [
    ("mrf_nbm_5day_max_high_flow_magnitude", "maxflow_5day_cfs", "5 day"),
    ("mrf_nbm_5day_max_high_flow_magnitude_ak", "max_flow", "5 day"),
    ("srf_48hr_max_high_flow_magnitude_hi", "max_flow", "48 hour"),
    ("srf_48hr_max_high_flow_magnitude_prvi", "max_flow", "48 hour"),
]

# Their stated maxRecordCount is 2000, but a 2000-row page timed out at 120s
# while 1000 returned in ~0.8s (measured). Stay under the cliff.
_NWM_PAGE = 1000

# RIVR's minimum flow, in the units NOAA publishes. The floor exists so dry
# headwaters whose return-period curve is degenerate (flow_2yr == flow_25yr, a
# fraction of a cfs) are not reported as flooding. 0.5 m3/s -> cfs.
_CFS_PER_CMS = 35.3146667
_NWM_MIN_FLOW_CFS = _NWM_MIN_FLOW_CMS * _CFS_PER_CMS

# Reaches with no basin code go in their own bucket rather than being dropped —
# 2,683 of 82,882 have none (measured).
_HUC_UNKNOWN = "unknown"


def _classify_nwm_row(row, flow_field):
    """RIVR's flood category (1..4) for one published row, or None.

    Deliberately ignores NOAA's own `recur_cat_5day`. Theirs includes anything
    above a regional high-water threshold, which is below a 2-year event; ours
    starts at the 2-year mark and applies a minimum flow. Using their numbers
    with our ladder keeps the map consistent with the forecast gauge (ADR 0002).
    """
    flow = row.get(flow_field)
    if flow is None or flow < _NWM_MIN_FLOW_CFS:
        return None
    two = row.get("flow_2yr")
    if not two:
        return None
    cat = 0
    for year, c in ((2, 1), (5, 2), (10, 3), (25, 4)):
        thr = row.get(f"flow_{year}yr")
        if thr and flow >= thr:
            cat = c
    return cat or None


def _fetch_nwm_service(service, flow_field):
    """Page one NOAA service. Returns (by_huc, flat, reference_time)."""
    fields = (
        f"feature_id,{flow_field},flow_2yr,flow_5yr,flow_10yr,flow_25yr,"
        "huc6,reference_time"
    )
    by_huc, flat = {}, {}
    reference = None
    offset = 0
    pages = 0
    while True:
        params = {
            "where": "1=1",
            "outFields": fields,
            "returnGeometry": "false",
            "resultOffset": offset,
            "resultRecordCount": _NWM_PAGE,
            "f": "json",
        }
        url = f"{_NWM_BASE}/{service}/MapServer/0/query?" + urllib.parse.urlencode(params)
        resp = requests.get(url, timeout=120)
        resp.raise_for_status()
        feats = resp.json().get("features", [])
        pages += 1
        for f in feats:
            a = f.get("attributes", {})
            if reference is None:
                reference = a.get("reference_time")
            fid = a.get("feature_id")
            cat = _classify_nwm_row(a, flow_field)
            if cat is None or fid is None:
                continue
            huc = (a.get("huc6") or "").strip() or _HUC_UNKNOWN
            by_huc.setdefault(huc, {})[str(fid)] = cat
            flat[str(fid)] = cat
        if len(feats) < _NWM_PAGE:
            break
        offset += len(feats)
        if pages > 200:
            print(f"nwm_conditions: {service} page cap hit")
            break
    print(f"nwm_conditions: {service} — {pages} pages, {len(flat)} elevated")
    return by_huc, flat, reference


def _fetch_nwm_all():
    """Every US territory NOAA publishes, merged."""
    by_huc, flat, refs, horizons = {}, {}, {}, {}
    for service, flow_field, horizon in _NWM_SERVICES:
        try:
            h, f, ref = _fetch_nwm_service(service, flow_field)
        except Exception as e:
            # One territory failing must not lose the others.
            print(f"nwm_conditions: {service} FAILED {type(e).__name__}: {e}")
            continue
        for huc, reaches in h.items():
            by_huc.setdefault(huc, {}).update(reaches)
        flat.update(f)
        refs[service] = ref
        horizons[service] = horizon
    return by_huc, flat, refs, horizons


@scheduler_fn.on_schedule(
    # NOAA's 5-day product refreshes every 6 hours and lands roughly 6.4h behind
    # its reference time (reference 06:00 UTC seen published at 12:25 UTC), so
    # cycles surface near 00:25 / 06:25 / 12:25 / 18:25. Run 20 minutes later.
    schedule="45 0,6,12,18 * * *",
    timezone=scheduler_fn.Timezone("UTC"),
    region="us-west1",
    memory=options.MemoryOption.GB_1,
    # ~83 pages at ~0.8s each is well under two minutes; no fan-out needed,
    # unlike GEOGLOWS where one region alone can take five.
    timeout_sec=540,
)
def nwm_conditions_refresh(event: scheduler_fn.ScheduledEvent) -> None:
    by_huc, flat, refs, horizons = _fetch_nwm_all()
    if not flat:
        print("nwm_conditions: nothing elevated; leaving the previous file in place")
        return

    date = datetime.now(timezone.utc).strftime("%Y%m%d")
    payload = json.dumps({
        "date": date,
        "reference_times": refs,
        "source": "NOAA NWPS high-flow-magnitude services",
        "horizon": "peak over next 5 days (CONUS, Alaska); 48 hours (Hawaii, PR/VI)",
        "horizons": horizons,
        "count": len(flat),
        "regions": len(by_huc),
        "by_huc6": by_huc,
        "conditions": flat,
    })
    _write_blob(f"conditions/nwm/{date}/latest.json", payload)
    _write_blob("conditions/nwm/latest.json", payload)
    print(
        f"nwm_conditions_refresh: {len(flat)} elevated across {len(by_huc)} "
        f"basins from {len(refs)}/{len(_NWM_SERVICES)} services"
    )


@https_fn.on_request(
    region="us-west1",
    memory=options.MemoryOption.MB_512,
    timeout_sec=60,
    # Scale to zero — see geoglows_conditions_latest. Off 2026-08-16 to stop spend.
)
def nwm_conditions_latest(req: https_fn.Request) -> https_fn.Response:
    """Serve the precomputed NWM file (private bucket, see ADR 0005)."""
    try:
        blob = _storage_client().bucket(_CONDITIONS_BUCKET).blob(
            "conditions/nwm/latest.json"
        )
        if not blob.exists():
            return https_fn.Response(
                json.dumps({"error": "not published yet", "conditions": {}}),
                status=404, headers=_JSON_HEADERS,
            )
        return https_fn.Response(
            blob.download_as_text(),
            status=200,
            headers={**_JSON_HEADERS, "Cache-Control": "public, max-age=900"},
        )
    except Exception as e:
        return https_fn.Response(
            json.dumps({"error": f"{type(e).__name__}: {e}"}),
            status=502, headers=_JSON_HEADERS,
        )
