// functions/src/publish-cadence-probe.ts
//
// ADR 0011 Phase 0 — instrumentation, not a feature.
//
// Every latency figure in ADR 0011 came from one sitting on 2026-08-21/22
// during which NOAA was returning 504s. The probe interval, the monitoring
// thresholds and the cache policy all depend on knowing typical behaviour, and
// none of them should be chosen from a single sample.
//
// ── Why five endpoints and not one ───────────────────────────────────────────
//
// v1 sampled only the unfiltered `/streamflow` response — the single heaviest
// thing the API returns. A 50-sample comparison then showed that is the wrong
// sensor:
//
//   ?series=analysis_assimilation   10/10 ok,  2.1 s avg
//   ?series=short_range             10/10 ok,  2.2 s avg
//   ?series=medium_range             9/10 ok, 10.9 s avg
//   ?series=long_range              10/10 ok, 15.7 s avg
//   unfiltered                       8/10 ok, 10.5 s avg
//
// The two products the app depends on for current flow never failed, straight
// through a window where heavier calls were timing out. So v1's "5 of 7 samples
// failed" described the worst case, not whether a user's request would have
// worked.
//
// It also could not settle *why* things failed: all three failures fell in the
// same two rounds, so endpoint weight and a bad window were confounded. Firing
// all five **simultaneously** every hour separates them over days — if weight is
// the cause, failures concentrate on the heavy endpoints across many different
// hours; if it is load, they cluster by hour across all five.
//
// ── Why hourly for the 6-hourly series too ───────────────────────────────────
//
// NOAA publishes analysis and short range hourly, and medium/blend/long four
// times a day. Sampling the slow ones every 6 h would still be wrong here,
// because we are not sampling to learn the values — we are sampling to learn
// *when NOAA actually publishes*. The 00Z medium-range run was observed landing
// ~07:20Z, later than its own 6-hour cycle. A 6-hourly probe would place that
// inside a 6-hour window; hourly places it within one. Availability is also a
// property of the moment rather than of the data, so 24 readings a day beats 4.
//
// ── Deliberate: no retries ───────────────────────────────────────────────────
//
// The app retries; this must not. A retry would hide exactly the failure rate
// being measured, and a call that succeeds on attempt three is still a call the
// user waited through.

import * as functions from "firebase-functions/v1";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";
import {NOAA_CONFIG} from "./noaa-client.js";

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * Bumped when the document shape changes so analysis never silently mixes two
 * schemas. v1 documents hold a single unfiltered sample; v2 holds all five.
 * (ADR 0011 decision 16, applied to our own instrumentation.)
 */
export const PROBE_SCHEMA_VERSION = 2;

/** Probe reach. "Dead River" — a real favourite; advertises every series. */
export const PROBE_REACH_ID = "9962444";

/** Generous: we are measuring how slow it gets, not enforcing a budget. */
const PROBE_TIMEOUT_MS = 120_000;

/**
 * The five requests, sampled together each hour.
 *
 * `series` is the `?series=` value; null means the unfiltered response. `key` is
 * where that series' `referenceTime` lives in the JSON — for the unfiltered
 * response every key is read from the one body.
 */
export const ENDPOINTS = [
  // `key` is NOAA'S OWN section name, not one of ours. NOAA returns
  // `analysisAssimilation` as a top-level key in every streamflow response,
  // and this probe measures that REAL series — which is a different thing
  // from the store product formerly sharing the name (renamed `currentFlow`
  // in Phase 9 because it fetches short range instead). Phase 9's blanket
  // rename changed this line too, which would have made the probe look for a
  // section NOAA never sends and silently record nothing for it.
  {name: "analysis_assimilation",
    series: "analysis_assimilation",
    key: "analysisAssimilation"},
  {name: "short_range", series: "short_range", key: "shortRange"},
  {name: "medium_range", series: "medium_range", key: "mediumRange"},
  {name: "long_range", series: "long_range", key: "longRange"},
  {name: "unfiltered", series: null, key: null},
] as const;

/**
 * Series read out of the unfiltered response, for the cross-check.
 *
 * NOAA's section names, verified against a live response on 2026-08-30:
 * `reach`, `analysisAssimilation`, `shortRange`, `mediumRange`, `longRange`,
 * `mediumRangeBlend`. Not our product ids — `analysisAssimilation` here is
 * NOAA's genuine analysis-assimilation series.
 */
export const SERIES = [
  "analysisAssimilation",
  "shortRange",
  "mediumRange",
  "longRange",
  "mediumRangeBlend",
] as const;

export interface EndpointResult {
  ok: boolean;
  httpStatus: number | null;
  elapsedMs: number;
  bytes: number | null;
  /** The series' referenceTime; for `unfiltered`, all series joined by name. */
  referenceTime: string | null;
  error: string | null;
}

export interface CadenceSample {
  schemaVersion: number;
  sampledAt: FirebaseFirestore.Timestamp;
  /**
   * When Firestore's TTL should delete this sample.
   *
   * A TTL policy deletes a document once the field it names is in the PAST, so
   * it cannot be pointed at `sampledAt` — that is already past the moment it is
   * written, and the whole dataset would evaporate. Hence a separate field
   * holding sampledAt + {@link PROBE_RETENTION_MS}.
   *
   * The probe log is the only collection in this project that grows without
   * bound: one document an hour, ~2 KB each, never overwritten and never
   * garbage-collected, where `river_data` is overwritten in place and swept by
   * storeGcDaily. 90 days caps it at ~2,200 documents — far more than the seven
   * consecutive days Phase 0 guard 1 needs, and enough history to see NOAA's
   * timing drift across a season.
   */
  expiresAt: FirebaseFirestore.Timestamp;
  /** endpoint name -> its result. */
  endpoints: Record<string, EndpointResult>;
  /** Authoritative per-series referenceTime, taken from the filtered calls. */
  referenceTimes: Record<string, string | null>;
  /** How many of the five answered. */
  okCount: number;
  /**
   * Whether the unfiltered response agreed with the filtered calls on every
   * series both reported. Null when unfiltered failed, so there was nothing to
   * compare. A false here would mean the API is internally inconsistent — worth
   * seeing rather than averaging away.
   */
  unfilteredAgrees: boolean | null;
}

/**
 * Pull every distinct `referenceTime` under a node. The API nests these
 * differently per series (`mediumRange.mean.referenceTime`,
 * `shortRange.series.referenceTime`), so walk rather than assume a shape.
 * @param {unknown} node Parsed JSON subtree.
 * @return {string|null} The referenceTime, or null when absent. Multiple
 *   distinct values join with "|" so an inconsistent series stays visible.
 */
export function referenceTimeOf(node: unknown): string | null {
  const found = new Set<string>();
  const walk = (v: unknown): void => {
    if (v === null || typeof v !== "object") return;
    if (Array.isArray(v)) {
      v.forEach(walk);
      return;
    }
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      if (k === "referenceTime" && typeof val === "string") found.add(val);
      else walk(val);
    }
  };
  walk(node);
  if (found.size === 0) return null;
  return Array.from(found).sort().join("|");
}

/**
 * Turn one raw response into a result. Split from the fetch so it is testable
 * without network access.
 * @param {object} args Raw response parts.
 * @param {string|null} args.seriesKey JSON key to read, null for unfiltered.
 * @param {number|null} args.httpStatus HTTP status, null if the request threw.
 * @param {string|null} args.body Response body, null if the request threw.
 * @param {number} args.elapsedMs Wall-clock duration.
 * @param {string|null} args.error Transport-level error, if any.
 * @return {EndpointResult} Never throws — a failure is a data point.
 */
export function buildEndpointResult(args: {
  seriesKey: string | null;
  httpStatus: number | null;
  body: string | null;
  elapsedMs: number;
  error: string | null;
}): EndpointResult {
  const {seriesKey, httpStatus, body, elapsedMs} = args;
  const result: EndpointResult = {
    ok: false,
    httpStatus,
    elapsedMs,
    bytes: body === null ? null : Buffer.byteLength(body, "utf8"),
    referenceTime: null,
    error: args.error,
  };

  if (args.error !== null) return result;
  if (httpStatus === null || httpStatus < 200 || httpStatus >= 300) {
    result.error = `HTTP ${httpStatus}`;
    return result;
  }
  if (body === null) {
    result.error = "empty body";
    return result;
  }

  let json: Record<string, unknown>;
  try {
    json = JSON.parse(body) as Record<string, unknown>;
  } catch (e) {
    result.error = e instanceof Error ? e.message : String(e);
    return result;
  }

  if (seriesKey === null) {
    // Unfiltered: record every series it carried, named, for the cross-check.
    const parts = SERIES.map((s) => `${s}=${referenceTimeOf(json[s]) ?? "-"}`);
    result.referenceTime = parts.join(" ");
  } else {
    result.referenceTime = referenceTimeOf(json[seriesKey]);
    if (result.referenceTime === null) {
      // HTTP 200 with an empty series — observed live on 2026-08-22. Parsing
      // succeeded but there is no data, and that must not read as healthy.
      result.error = "200 but series empty";
      return result;
    }
  }

  result.ok = true;
  return result;
}

/**
 * Fetch one endpoint. Never throws.
 * @param {string|null} series The `?series=` value, or null for unfiltered.
 * @param {string|null} seriesKey JSON key to read, null for unfiltered.
 * @return {Promise<EndpointResult>} The result.
 */
export async function probeEndpoint(
  series: string | null,
  seriesKey: string | null
): Promise<EndpointResult> {
  const base =
    `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${PROBE_REACH_ID}/streamflow`;
  const url = series === null ? base : `${base}?series=${series}`;

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);

  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: {"User-Agent": "RIVR-cadence-probe/2.0"},
    });
    const body = await res.text();
    return buildEndpointResult({
      seriesKey,
      httpStatus: res.status,
      body,
      elapsedMs: Date.now() - started,
      error: null,
    });
  } catch (e) {
    return buildEndpointResult({
      seriesKey,
      httpStatus: null,
      body: null,
      elapsedMs: Date.now() - started,
      error: e instanceof Error ? e.message : String(e),
    });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * How long a probe sample is kept, enforced by a Firestore TTL policy on
 * `expiresAt` rather than by any code here.
 *
 * Nothing in this project deleted probe samples before 2026-08-29; the
 * collection was the one unbounded thing in the database.
 */
export const PROBE_RETENTION_MS = 90 * 24 * 3600_000;

/**
 * Assemble one hour's sample from the five results.
 * @param {Record<string, EndpointResult>} endpoints Per-endpoint results.
 * @return {CadenceSample} The sample.
 */
export function buildSample(
  endpoints: Record<string, EndpointResult>
): CadenceSample {
  // Authoritative freshness comes from the filtered calls: v1 could only read
  // referenceTime when the unfiltered request succeeded, which is the one with
  // the worst observed success rate (8/10 vs 10/10).
  const referenceTimes: Record<string, string | null> = {};
  for (const e of ENDPOINTS) {
    if (e.key === null) continue;
    referenceTimes[e.key] = endpoints[e.name]?.referenceTime ?? null;
  }

  // Cross-check: does the unfiltered body agree with the filtered calls?
  let unfilteredAgrees: boolean | null = null;
  const unfiltered = endpoints["unfiltered"];
  if (unfiltered?.ok && unfiltered.referenceTime) {
    const parsed = new Map(
      unfiltered.referenceTime
        .split(" ")
        .map((p) => p.split("=") as [string, string])
    );
    unfilteredAgrees = Object.entries(referenceTimes).every(([k, v]) => {
      const other = parsed.get(k);
      if (v === null || other === undefined || other === "-") return true;
      return v === other;
    });
  }

  const now = admin.firestore.Timestamp.now();
  return {
    schemaVersion: PROBE_SCHEMA_VERSION,
    sampledAt: now,
    expiresAt: admin.firestore.Timestamp.fromMillis(
      now.toMillis() + PROBE_RETENTION_MS),
    endpoints,
    referenceTimes,
    okCount: Object.values(endpoints).filter((r) => r.ok).length,
    unfilteredAgrees,
  };
}

/**
 * Hourly probe. One document per hour into `publish_cadence_log`, holding all
 * five endpoint results.
 *
 * Storage is append-only and flat: a week is 168 documents, and the analysis
 * (when a run lands, how late, how often each endpoint fails) reads far more
 * easily over rows than over an aggregate that has thrown the shape away.
 *
 * The log line is emitted BEFORE the write and the write is guarded, so a
 * Firestore failure loses the document but never the observation — review found
 * v1 could drop a sample leaving neither, which is this repo's documented
 * silent-failure mode reproduced in new code.
 */
export const probePublishCadence = functions
  .runWith({memory: "256MB", timeoutSeconds: 300})
  .pubsub.schedule("0 * * * *")
  .timeZone("UTC")
  .onRun(async () => {
    // Simultaneous, so endpoint weight and a bad minute stay separable.
    const results = await Promise.all(
      ENDPOINTS.map(async (e) => [
        e.name,
        await probeEndpoint(e.series, e.key),
      ] as const)
    );
    const sample = buildSample(Object.fromEntries(results));

    const line = ENDPOINTS.map((e) => {
      const r = sample.endpoints[e.name];
      return `${e.name}=${r.ok ? `${r.elapsedMs}ms` : `FAIL(${r.error})`}`;
    }).join(" ");

    if (sample.okCount === ENDPOINTS.length) {
      logger.info(`📈 cadence ${sample.okCount}/${ENDPOINTS.length} ${line}`);
    } else {
      logger.warn(`📈 cadence ${sample.okCount}/${ENDPOINTS.length} ${line}`);
    }
    if (sample.unfilteredAgrees === false) {
      logger.warn(
        "📈 cadence DISAGREEMENT — unfiltered and filtered report different " +
        `referenceTimes: ${JSON.stringify(sample.referenceTimes)} vs ` +
        `${sample.endpoints["unfiltered"].referenceTime}`
      );
    }

    try {
      await db.collection("publish_cadence_log").add(sample);
    } catch (e) {
      logger.error(
        "📈 cadence WRITE FAILED — sample lost, dataset now has a gap",
        {error: e instanceof Error ? e.message : String(e)}
      );
    }
  });
