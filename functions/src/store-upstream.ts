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
import {ForecastProductId, ForecastSourceId} from "./store-keys.js";

/** NOAA's `series` parameter for each product this file can fetch. */
const SERIES_BY_PRODUCT: Partial<Record<ForecastProductId, string>> = {
  analysisAssimilation: "analysis_assimilation",
  shortRange: "short_range",
  mediumRange: "medium_range",
  longRange: "long_range",
};

/** The response section each product's run identity lives in. */
const SECTION_BY_PRODUCT: Partial<Record<ForecastProductId, string>> = {
  analysisAssimilation: "analysisAssimilation",
  shortRange: "shortRange",
  mediumRange: "mediumRange",
  longRange: "longRange",
};

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
    // GEOGLOWS is served by the Python functions and is on its own daily
    // schedule; wiring it here would put two fetchers behind one product.
    throw new Error(
      `store-upstream does not fetch ${source}; GEOGLOWS has its own path`
    );
  }

  const series = SERIES_BY_PRODUCT[product];
  const section = SECTION_BY_PRODUCT[product];
  if (!series || !section) {
    throw new Error(`store-upstream cannot fetch NWM product ${product}`);
  }

  const url = `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${reachId}` +
    `/streamflow?series=${series}`;
  const body = await getJson(url);

  // A 200 carrying an empty series is a real NOAA failure mode — observed live
  // on 2026-08-22 and the reason the probe counts it as a failure rather than
  // health. Storing it would overwrite good data with nothing.
  if (!(section in body)) {
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
