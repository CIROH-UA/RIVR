// functions/src/store-upstream.ts
//
// ADR 0011 Phase 4: fetching one product for one reach, in the shape the client
// already decodes.
//
// The stored payload is handed to `ForecastResponseDto.fromApiResponse` on the
// client, so it must remain a NOAA response BODY. This file therefore does not
// reshape anything — it fetches, reads the run identity out, works out the
// native unit, and hands the body on. Trimming happens later, in the write
// path, and only removes keys the decoder never reads.

import * as logger from "firebase-functions/logger";

import {
  NOAA_CONFIG,
  getReachMetadata,
  getReturnPeriods,
} from "./noaa-client.js";
import {referenceTimeOf} from "./publish-cadence-probe.js";
import {FetchedProduct} from "./store-run.js";
import {
  ForecastProductId,
  ForecastSourceId,
  SECTION_BY_PRODUCT,
} from "./store-keys.js";
import {fetchGeoglowsForStore} from "./store-geoglows.js";

/** NOAA's `series` parameter for each product this file can fetch. */
export const SERIES_BY_PRODUCT: Partial<Record<ForecastProductId, string>> = {
  // NOT "analysis_assimilation". The client derives current flow from the
  // SHORT RANGE series — nwm_data_source.dart fetches fetchCurrentFlowOnly,
  // which is fetchForecast(reachId, 'short_range'), and takes its run from the
  // shortRange section. ForecastValues.currentFlow only ever looks at
  // short/medium/long range, so an analysis_assimilation body stored under
  // this key decodes to a null flow on every surface that reads it — the
  // store present and delivering nothing. Round 2, F2.
  analysisAssimilation: "short_range",
  shortRange: "short_range",
  mediumRange: "medium_range",
  longRange: "long_range",
};

/**
 * Which (source, product) pairs this file can actually fetch.
 *
 * Planning work this cannot serve guarantees a failure per reach per run.
 * Round 2 found write-through planning six NWM products of which two always
 * threw, and one GEOGLOWS product that always threw — so every GEOGLOWS
 * favourite produced zero documents, forever, while reporting failures.
 *
 * returnPeriods and reachMetadata ARE fetchable, from a different upstream
 * (the CIROH return-period API, and the reaches endpoint). They were omitted
 * until Phase 5 review round 1, which found the omission made Phase 5 guard 1
 * — "a favourite renders with ZERO upstream calls from the device" —
 * unreachable: every surface that renders a favourite reads the river's name
 * and its flood thresholds, so with those two products missing from the store
 * each favourite still made two device-side calls. The ADR anticipated this
 * ("Declared, Phase 5's problem: ReachCacheService still stores reach info ...
 * It follows the metadata product into the repository when Phase 5 touches
 * this seam").
 *
 * Fetchable is NOT the same as hourly. Both are near-static — a 30-day
 * freshness window, and no run identity to advance — so they are excluded from
 * MANAGED_PRODUCTS and refreshed by the daily static pass instead. Putting
 * them on the hourly cycle would re-fetch an unchanging river name 24 times a
 * day per favourite.
 *
 * GEOGLOWS is fetched by store-geoglows.ts, on its own daily schedule — it
 * publishes one run per UTC day and is not on the NWM probe's cycle.
 *
 * It was briefly excluded here on the belief that the proxy returned only the
 * median. That was wrong: functions_geoglows/main.py returns
 * flow_uncertainty_lower and flow_uncertainty_upper too. The existing
 * geoglows-client.ts parses only the median because it serves the ALERT path,
 * and "my client ignores it" was misread as "the proxy does not send it".
 */
export const CAN_FETCH: Readonly<Record<ForecastSourceId, ForecastProductId[]>>
  = {
    nwm: [
      "analysisAssimilation",
      "shortRange",
      "mediumRange",
      "longRange",
      "returnPeriods",
      "reachMetadata",
    ],
    geoglows: ["geoglowsForecast"],
  };

/** Whether a (source, product) pair can be fetched at all. */
export function canFetch(
  source: ForecastSourceId,
  product: ForecastProductId
): boolean {
  return CAN_FETCH[source].includes(product);
}

/**
 * Canonicalise NOAA's unit string to the CFS/CMS token the client converts
 * from.
 *
 * Returns null rather than guessing when the response carries no unit:
 * `buildStoreDocument` refuses a document without one, which fails this reach
 * and retries it. Defaulting would store a number whose meaning nobody knows.
 *
 * @param {unknown} raw - The `units` field from the response.
 * @return {string | null} "CFS", "CMS", or null.
 */
export function canonicalUnit(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.trim() === "") return null;
  const u = raw.toLowerCase().replace(/\s/g, "");
  if (u.includes("ft") || u.includes("cfs")) return "CFS";
  if (u.includes("m³") || u.includes("m3") || u.includes("cms")) return "CMS";
  return null;
}

/** Pull `units` out of a product's section, wherever the series nests it. */
function unitOf(body: Record<string, unknown>, section: string): unknown {
  const s = body[section];
  if (typeof s !== "object" || s === null) return undefined;
  const inner = s as Record<string, unknown>;
  for (const key of ["series", "mean"]) {
    const nested = inner[key];
    if (typeof nested === "object" && nested !== null) {
      const u = (nested as Record<string, unknown>).units;
      if (u !== undefined) return u;
    }
  }
  return inner.units;
}

async function getJson(url: string): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), NOAA_CONFIG.timeout);
  try {
    const res = await fetch(url, {
      headers: NOAA_CONFIG.headers,
      signal: controller.signal,
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} for ${url}`);
    }
    return (await res.json()) as Record<string, unknown>;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetch one product for one reach.
 *
 * Deliberately does NOT retry. A transient failure is recorded per reach and
 * retried on the next cycle (guard 4); retrying inside the run would hide the
 * failure rate the Phase 0 probe exists to measure, for the same reason the
 * probe itself does not retry.
 *
 * @param {ForecastSourceId} source - Which network.
 * @param {string} reachId - The reach.
 * @param {ForecastProductId} product - Which product.
 * @return {Promise<FetchedProduct>} Payload, native unit and run identity.
 */
export async function fetchProductFromUpstream(
  source: ForecastSourceId,
  reachId: string,
  product: ForecastProductId
): Promise<FetchedProduct> {
  if (source !== "nwm") {
    // GEOGLOWS has its own fetcher and schedule; routing is fetchForStore's job.
    throw new Error(
      `store-upstream does not fetch ${source}; use store-geoglows`
    );
  }

  // The two near-static products come from different upstreams and carry no
  // run identity, so they route out before the streamflow logic below.
  if (product === "reachMetadata") return fetchReachMetadata(reachId);
  if (product === "returnPeriods") return fetchReturnPeriods(reachId);

  const series = SERIES_BY_PRODUCT[product];
  const section = SECTION_BY_PRODUCT[product];
  if (!series || !section) {
    throw new Error(`store-upstream cannot fetch NWM product ${product}`);
  }

  const url = `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${reachId}` +
    `/streamflow?series=${series}`;
  const body = await getJson(url);

  // A 200 carrying an EMPTY series is a real NOAA failure mode — observed live
  // on 2026-08-22 and the reason the probe counts it as a failure rather than
  // health. Storing it would overwrite good data with nothing.
  //
  // Testing `section in body` alone could never catch that: NOAA includes all
  // five section keys in every response, with the unrequested (and the failed)
  // ones as `{}`. Round 3, B4 — the comment described a mechanism the code did
  // not have.
  const sectionBody = body[section];
  const sectionIsEmpty = sectionBody === undefined || sectionBody === null ||
    (typeof sectionBody === "object" && !Array.isArray(sectionBody) &&
      Object.keys(sectionBody as Record<string, unknown>).length === 0);
  if (sectionIsEmpty) {
    throw new Error(
      `${reachId}/${product}: 200 with no ${section} section — treating as a ` +
      "failed fetch rather than storing an empty forecast"
    );
  }

  const unit = canonicalUnit(unitOf(body, section));
  if (!unit) {
    throw new Error(
      `${reachId}/${product}: response carried no recognisable unit; ` +
      "refusing to store a number whose meaning is unknown"
    );
  }

  // Same extractor the probe uses, keyed by SECTION rather than first-found:
  // a first-found version once stamped mediumRange with shortRange's run,
  // which advances hourly while medium moves 4x/day.
  const referenceTime = referenceTimeOf(body[section]);
  if (!referenceTime) {
    logger.warn("⚠️ store-upstream: no referenceTime in response", {
      reachId, product,
    });
  }

  return {payload: body, unit, referenceTime};
}

/**
 * The reach's identity, in the exact payload shape the client decodes.
 *
 * Field names mirror Dart `ReachMetadataPayload.encode`. They are not
 * negotiable: `ReachMetadataPayload.decode` reads `riverName`,
 * `formattedLocation`, `latitude` and `longitude` by name and casts, so a
 * renamed field decodes as null and the reach renders untitled with nothing
 * wrong server-side.
 *
 * `formattedLocation` is written as null on purpose — see ReachMetadataRecord.
 * The live path does not geocode here either, so storing a geocoded string
 * would make the stored value differ from the live one (guard 7).
 *
 * The unit is "CMS" only to satisfy the envelope: nothing in this payload is a
 * flow value, and `ReachMetadataPayload.decode` never looks at `entry.unit`.
 *
 * @param {string} reachId - The reach.
 * @return {Promise<FetchedProduct>} The metadata payload.
 */
async function fetchReachMetadata(reachId: string): Promise<FetchedProduct> {
  const m = await getReachMetadata(reachId);
  return {
    payload: {
      riverName: m.riverName,
      formattedLocation: null,
      latitude: m.latitude,
      longitude: m.longitude,
    },
    unit: "CMS",
    // A river's name has no model run. Inventing one would make every refresh
    // look like new data and defeat supersession.
    referenceTime: null,
  };
}

/**
 * Return-period thresholds, in the raw array shape the client decodes.
 *
 * The payload is `{returnPeriods: [...]}` wrapping the API's own array,
 * because `ReturnPeriodPayload.decode` hands `payload['returnPeriods']`
 * straight to `ReachDataDto.fromReturnPeriodApi`, which expects the upstream
 * array of `{feature_id, return_period_2, ...}` objects. Reshaping it here
 * would decode to no thresholds, and no thresholds costs the flood category
 * silently — the number still renders, just never coloured.
 *
 * The unit is "CMS" because that is what this API actually serves, regardless
 * of any user preference, and the client converts FROM CMS unconditionally.
 * Decision 12: store the native upstream unit, never a preference.
 *
 * An empty result THROWS. `getReturnPeriods` returns `[]` both when upstream
 * has no thresholds for a reach and when the fetch failed and no cache was
 * available; storing that would replace real thresholds with none for the
 * 30-day window. Failing leaves the previous document untouched (guard 4).
 *
 * @param {string} reachId - The reach.
 * @return {Promise<FetchedProduct>} The thresholds payload.
 */
async function fetchReturnPeriods(reachId: string): Promise<FetchedProduct> {
  const rows = await getReturnPeriods(reachId);
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error(
      `${reachId}: return-period API returned nothing — refusing to store ` +
      "empty thresholds over real ones"
    );
  }
  return {
    payload: {returnPeriods: rows as unknown as Record<string, unknown>[]},
    unit: "CMS",
    referenceTime: null,
  };
}

/**
 * The store's single fetch entry point, routing by source.
 *
 * Callers should use this rather than picking a fetcher, so a new source is
 * added in one place and nothing downstream has to know which module serves
 * which network.
 *
 * @param {ForecastSourceId} source - Which network.
 * @param {string} reachId - The reach.
 * @param {ForecastProductId} product - Which product.
 * @return {Promise<FetchedProduct>} Payload, native unit and run identity.
 */
export async function fetchForStore(
  source: ForecastSourceId,
  reachId: string,
  product: ForecastProductId
): Promise<FetchedProduct> {
  if (source === "geoglows") {
    return fetchGeoglowsForStore(source, reachId, product);
  }
  return fetchProductFromUpstream(source, reachId, product);
}
