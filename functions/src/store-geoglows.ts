// functions/src/store-geoglows.ts
//
// ADR 0011 Phase 4 Build: "GEOGLOWS on its own daily schedule, keyed on
// forecast_date."
//
// GEOGLOWS is NOT on the NWM probe's cycle — it publishes one run per UTC day —
// so it gets its own fetcher and its own schedule rather than being squeezed
// onto the hourly path.
//
// **The uncertainty band is not optional.** An earlier version of this phase
// excluded GEOGLOWS on the belief that the proxy returned only the median.
// That was wrong: functions_geoglows/main.py returns
// `flow_uncertainty_lower` and `flow_uncertainty_upper` alongside
// `flow_median`. The existing TypeScript geoglows-client.ts parses only the
// median because it serves the ALERT path, which needs a peak — reading "my
// client ignores it" as "the proxy does not send it" is how the band nearly
// got dropped from every stored GEOGLOWS chart.
//
// The client decodes with GeoglowsForecastPayload.decode
// (lib/services/4_infrastructure/river_data/geoglows_forecast_payload.dart),
// which does `conv(p['median'] as num)` on all three of median/lower/upper. A
// null in any of them THROWS and takes the whole decode down, so a step
// missing any band value is skipped rather than emitted with nulls.

import * as logger from "firebase-functions/logger";

import {FetchedProduct} from "./store-run.js";
import {ForecastProductId, ForecastSourceId} from "./store-keys.js";

/** The Python proxy. Same endpoint geoglows-client.ts uses for alerts. */
export const GEOGLOWS_PROXY_URL =
  "https://us-west1-ciroh-rivr-app.cloudfunctions.net/geoglows_forecast";

/** GEOGLOWS publishes in cubic metres per second (`UNITS = "m3/s"`). */
export const GEOGLOWS_NATIVE_UNIT = "CMS";

const TIMEOUT_MS = 30_000;

/** The proxy's response, as functions_geoglows/main.py builds it. */
export interface GeoglowsProxyBody {
  river_id?: unknown;
  forecast_date?: unknown;
  units?: unknown;
  forecast?: {
    datetime?: unknown;
    flow_median?: unknown;
    flow_uncertainty_lower?: unknown;
    flow_uncertainty_upper?: unknown;
  };
  return_periods?: Record<string, unknown>;
}

/** One step, in the shape GeoglowsForecastPayload.encode writes. */
export interface StoredGeoglowsPoint {
  t: string;
  median: number;
  lower: number;
  upper: number;
}

export interface StoredGeoglowsPayload {
  riverId: string;
  generatedAt: string;
  points: StoredGeoglowsPoint[];
  returnPeriods: Record<string, number> | null;
}

function numAt(col: unknown, i: number): number | null {
  if (!Array.isArray(col)) return null;
  const v = col[i];
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

/**
 * Convert the proxy's column-oriented response into the row-oriented payload
 * the client decodes.
 *
 * @param {GeoglowsProxyBody} body - The proxy response.
 * @param {string} reachId - The reach requested, for the riverId fallback.
 * @return {StoredGeoglowsPayload} The payload to store.
 * @throws {Error} When the response carries no usable forecast at all.
 */
export function buildGeoglowsPayload(
  body: GeoglowsProxyBody,
  reachId: string
): StoredGeoglowsPayload {
  const fc = body.forecast ?? {};
  const times = Array.isArray(fc.datetime) ? fc.datetime : [];

  const points: StoredGeoglowsPoint[] = [];
  let droppedIncomplete = 0;

  for (let i = 0; i < times.length; i++) {
    const t = times[i];
    if (typeof t !== "string" || t === "") {
      droppedIncomplete++;
      continue;
    }
    const median = numAt(fc.flow_median, i);
    const lower = numAt(fc.flow_uncertainty_lower, i);
    const upper = numAt(fc.flow_uncertainty_upper, i);

    // All three or none. The client casts each `as num`; a null throws inside
    // GeoglowsForecastPayload.decode and loses the entire forecast, not just
    // the step. Skipping keeps the rest of the series readable.
    if (median === null || lower === null || upper === null) {
      droppedIncomplete++;
      continue;
    }
    points.push({t, median, lower, upper});
  }

  if (points.length === 0) {
    // A 200 carrying no usable series is a real failure, not an empty
    // forecast to store over good data.
    throw new Error(
      `${reachId}: GEOGLOWS response had no complete forecast steps ` +
      `(${times.length} timestamps, ${droppedIncomplete} incomplete)`
    );
  }
  if (droppedIncomplete > 0) {
    logger.warn("⚠️ GEOGLOWS: dropped steps missing a band value", {
      reachId, droppedIncomplete, kept: points.length,
    });
  }

  // Recurrence year -> flow, keys as strings, exactly as encode() writes them.
  let returnPeriods: Record<string, number> | null = null;
  if (body.return_periods && typeof body.return_periods === "object") {
    const out: Record<string, number> = {};
    for (const [k, v] of Object.entries(body.return_periods)) {
      if (typeof v === "number" && Number.isFinite(v)) out[k] = v;
    }
    if (Object.keys(out).length > 0) returnPeriods = out;
  }

  const riverId = body.river_id === undefined || body.river_id === null ?
    reachId :
    String(body.river_id);

  return {
    riverId,
    generatedAt: normaliseForecastDate(body.forecast_date),
    points,
    returnPeriods,
  };
}

/**
 * The run identity, from `forecast_date`.
 *
 * GEOGLOWS publishes once per UTC day and the ADR keys the daily schedule on
 * this field. A date-only value is widened to that day's 00Z instant so it
 * compares as a timestamp like every other run identity.
 *
 * @param {unknown} raw - The proxy's forecast_date.
 * @return {string} An ISO-8601 instant.
 * @throws {Error} When absent or unparseable — never fabricated.
 */
export function normaliseForecastDate(raw: unknown): string {
  if (typeof raw !== "string" || raw.trim() === "") {
    // Wall-clock-at-fetch would make every refetch look like a new run, which
    // is exactly what GeoglowsDataSource refuses to do with its
    // generatedAtIsFallback flag. Fail the reach instead.
    throw new Error(
      "GEOGLOWS response carried no forecast_date; refusing to mint a run " +
      "identity from wall-clock time"
    );
  }
  const s = raw.trim();

  // The proxy emits YYYYMMDD, not YYYY-MM-DD: functions_geoglows/main.py:99
  // builds it with strftime("%Y%m%d"). `new Date("20260824")` is Invalid Date
  // in Node, so accepting only the hyphenated form rejected EVERY real
  // response — every GEOGLOWS reach failing, forever, while reporting a
  // failure. The Dart client handles the same shape explicitly
  // (geoglows_api_service.dart: `fd.length == 8`). Round 3, B1.
  let normalised = s;
  const compact = /^(\d{4})(\d{2})(\d{2})$/.exec(s);
  if (compact) {
    normalised = `${compact[1]}-${compact[2]}-${compact[3]}T00:00:00Z`;
  } else if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    normalised = `${s}T00:00:00Z`;
  }

  const parsed = new Date(normalised);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error(`GEOGLOWS forecast_date is unparseable: "${s}"`);
  }
  return parsed.toISOString();
}

async function getJson(url: string): Promise<GeoglowsProxyBody> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, {signal: controller.signal});
    if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
    return (await res.json()) as GeoglowsProxyBody;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetch one GEOGLOWS reach for the store.
 *
 * Like the NWM fetcher, this does NOT retry: a transient failure is recorded
 * per reach and retried next cycle, so the failure rate stays visible.
 *
 * @param {ForecastSourceId} source - Must be "geoglows".
 * @param {string} reachId - The GEOGLOWS river id.
 * @param {ForecastProductId} product - Must be "geoglowsForecast".
 * @return {Promise<FetchedProduct>} Payload, native unit and run identity.
 */
export async function fetchGeoglowsForStore(
  source: ForecastSourceId,
  reachId: string,
  product: ForecastProductId
): Promise<FetchedProduct> {
  if (source !== "geoglows" || product !== "geoglowsForecast") {
    throw new Error(
      `store-geoglows does not fetch ${source}/${product}`
    );
  }

  const url = `${GEOGLOWS_PROXY_URL}?river_id=${encodeURIComponent(reachId)}`;
  const body = await getJson(url);
  const payload = buildGeoglowsPayload(body, reachId);

  return {
    // The stored payload is exactly what GeoglowsForecastPayload.encode
    // produces, so Phase 5 can hand it to decode() unchanged.
    payload: payload as unknown as Record<string, unknown>,
    // Native, never a user preference (decision 12). GEOGLOWS publishes m3/s.
    unit: GEOGLOWS_NATIVE_UNIT,
    referenceTime: payload.generatedAt,
  };
}
