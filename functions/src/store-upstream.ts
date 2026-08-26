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

import {NOAA_CONFIG} from "./noaa-client.js";
import {referenceTimeOf} from "./publish-cadence-probe.js";
import {FetchedProduct} from "./store-run.js";
import {
  ForecastProductId,
  ForecastSourceId,
  SECTION_BY_PRODUCT,
} from "./store-keys.js";
import {fetchGeoglowsForStore} from "./store-geoglows.js";

/**
 * The unit the store records for products whose values are NOT flow, and for
 * return-period thresholds.
 *
 * "CMS" because the return-period API serves native cubic metres per second
 * regardless of any user preference, and `ReturnPeriodPayload.decode` converts
 * FROM the literal 'CMS', ignoring `entry.unit`. Storing anything else
 * silently misclassifies every flood category — the number still renders, just
 * in the wrong colour. Decision 12: store the native upstream unit, never a
 * preference.
 *
 * Named rather than inlined so a test can assert on it: round 2 changed it to
 * "CFS" as a mutation and all 207 tests passed.
 */
export const STORE_NATIVE_UNIT = "CMS";

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

/**
 * Non-retrying JSON fetch that tolerates any top-level shape.
 *
 * The return-period API answers with an ARRAY, so it cannot go through
 * {@link getJson}, whose signature promises an object.
 *
 * @param {string} url - The URL to fetch.
 * @return {Promise<unknown>} The decoded body.
 */
async function getJsonAny(url: string): Promise<unknown> {
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
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
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
export async function fetchReachMetadata(reachId: string): Promise<FetchedProduct> {
  // Fetched HERE rather than through noaa-client's getRiverName, and
  // deliberately not through its fetchWithRetry. Two reasons, both rules this
  // file already states:
  //
  //   - No retries in the store's fetchers. CLAUDE.md puts it absolutely
  //     ("Never add retries to the store's fetchers"), and the comment on
  //     fetchProductFromUpstream gives the reason: a transient failure is
  //     recorded per reach and retried next cycle, and retrying inside the run
  //     hides the failure rate the Phase 0 probe exists to measure. Round 2,
  //     B3 — the first version of this function called fetchWithRetry, which
  //     retries 3x with backoff, directly contradicting both.
  //   - No fallback value. getRiverName returns `Reach <id>` when the fetch
  //     fails, which is right for a notification that must go out with
  //     something and wrong for the store: a placeholder would be stamped
  //     fresh for 30 days and every device would render it.
  const body = await getJson(
    `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${reachId}`);

  // Accept whatever NOAA gives, INCLUDING an empty string, because that is
  // exactly what the live path accepts: `ReachDataDto.fromNoaaApi` does
  // `riverName: json['name'] as String`, which is happy with "" and throws
  // only when the field is absent or not a string. Matching it is guard 7.
  //
  // Rejecting "" was a real defect, found by checking the first deployed run's
  // COUNTS rather than its exit status: 3 of 29 reaches failed with "carried
  // no name". Those reaches exist and have valid coordinates — NOAA simply
  // has no name for them — so they would have failed every single day
  // forever, sat permanently in reachesToRetry, and inflated the failure rate
  // the Phase 0 probe exists to measure. Same distinction as returnPeriods:
  // "upstream has none" is an answer, not a failure.
  const rawName = body.name;
  if (typeof rawName !== "string") {
    throw new Error(
      `${reachId}: reach info carried no name field — refusing to store ` +
      "identity from a shape we cannot read"
    );
  }
  const riverName = rawName;

  return {
    payload: {
      riverName,
      // Null on purpose: the live path does not geocode here either
      // (NwmDataSource injects a geocoder and pointedly leaves it unused), so
      // geocoding server-side would make the stored value differ from the live
      // one — guard 7.
      formattedLocation: null,
      latitude: typeof body.latitude === "number" ? body.latitude : null,
      longitude: typeof body.longitude === "number" ? body.longitude : null,
    },
    unit: STORE_NATIVE_UNIT,
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
export async function fetchReturnPeriods(reachId: string): Promise<FetchedProduct> {
  // Fetched HERE rather than through noaa-client's getReturnPeriods, for the
  // no-retry rule above and for one more reason specific to this product:
  // getReturnPeriods falls back to the `return_period_cache` collection of ANY
  // age when the API fails. Writing that into the store would stamp an
  // arbitrarily old value with a fresh fetchedAt and a 30-day validUntil —
  // the store asserting currency it does not have, which is the one thing
  // Phase 7's trust model cannot survive. Round 2, non-blocking 4.
  const body = await getJsonAny(
    `${NOAA_CONFIG.nwmReturnPeriodUrl}?comids=${reachId}` +
    `&key=${NOAA_CONFIG.nwmApiKey}`);

  const rows = Array.isArray(body) ? body : [body];
  const valid = rows.filter(
    (r): r is Record<string, unknown> =>
      typeof r === "object" && r !== null && !Array.isArray(r) &&
      Object.keys(r).some((k) => k.startsWith("return_period_")));

  if (valid.length === 0) {
    // "Upstream answered, and this reach genuinely has no thresholds" is not
    // the same as "the fetch failed", and they need different outcomes.
    // Round 4, non-blocking 1: throwing here meant such a reach failed EVERY
    // day forever, sat permanently in reachesToRetry, and inflated the very
    // failure rate the no-retry rule exists to keep honest.
    //
    // A 200 with a well-formed but threshold-free body is a real answer.
    // Storing it — an empty array — is what the client already treats as "no
    // thresholds", costing that reach its flood category and nothing else.
    // A malformed body still throws, below.
    if (Array.isArray(body)) {
      logger.info(
        `${reachId}: upstream has no return periods; storing an empty set ` +
        "rather than failing this reach every day"
      );
      return {
        payload: {returnPeriods: []},
        unit: STORE_NATIVE_UNIT,
        referenceTime: null,
      };
    }
    throw new Error(
      `${reachId}: return-period response was not an array — refusing to ` +
      "store thresholds from a shape we cannot read"
    );
  }
  const usable = valid;
  return {
    payload: {returnPeriods: usable},
    unit: STORE_NATIVE_UNIT,
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
