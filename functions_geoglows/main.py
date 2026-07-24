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

import io
import json
import math
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from functools import lru_cache

import numpy as np
import pandas as pd
import requests
from firebase_functions import https_fn, options
import geoglows

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
