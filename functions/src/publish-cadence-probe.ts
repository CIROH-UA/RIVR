// functions/src/publish-cadence-probe.ts
//
// ADR 0011 Phase 0 — instrumentation, not a feature.
//
// Every measurement in ADR 0011 came from one sitting on 2026-08-21/22 during
// which NOAA was returning 504s. That window produced a 30.8s median and an 11%
// failure rate for medium_range, and showed the 00Z run publishing ~7 hours
// after its nominal cycle time. Those numbers set the probe interval, the
// monitoring thresholds and the cache policy — and none of them should be chosen
// from a single sample.
//
// This probe records what actually happens, hourly, so those numbers are
// confirmed or corrected before code depends on them.
//
// Two deliberate design choices:
//
//   1. NO RETRIES. The app retries; this must not. A retry would hide exactly
//      the failure rate we are trying to measure, and a timeout that succeeds on
//      attempt three is still a timeout the user waited through.
//
//   2. ONE REACH. `referenceTime` names a model run, and it was identical across
//      8 sampled reaches. Probing one reach is therefore enough to detect a new
//      run — but note this probe is measuring *cadence*, not deciding what to
//      store. ADR 0011 Phase 3 guard 3 requires each reach to record the
//      referenceTime it actually returned, precisely so this assumption never
//      becomes load-bearing.
//
// A NOTE ON `ok` VS `complete`, which review caught (2026-08-22):
//
//   NOAA returns HTTP 200 with `mediumRange: {}` during partial outages — that
//   was live while this was being reviewed. An earlier version set `ok = true`
//   whenever the body parsed, so a run where the most important series was
//   missing entirely would have been logged as healthy and silently undercounted
//   the failure rate. `ok` now means "fetched and parsed"; `complete` means
//   "every expected series carried a referenceTime". Analysis must key on
//   `complete`, and the log line says DEGRADED when they disagree.

import * as functions from "firebase-functions/v1";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";
import {NOAA_CONFIG} from "./noaa-client.js";

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/** Probe reach. "Dead River" — a real favourite, advertises every series. */
export const PROBE_REACH_ID = "9962444";

/** Unfiltered streamflow returns every series' referenceTime in one response. */
export const PROBE_URL =
  `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${PROBE_REACH_ID}/streamflow`;

/** Generous: we are measuring how slow it gets, not enforcing a budget. */
const PROBE_TIMEOUT_MS = 120_000;

/**
 * Every series the API advertises, including `mediumRangeBlend` — review noted
 * the first version sampled four of five.
 */
export const SERIES = [
  "analysisAssimilation",
  "shortRange",
  "mediumRange",
  "longRange",
  "mediumRangeBlend",
] as const;

export interface ProbeSample {
  sampledAt: FirebaseFirestore.Timestamp;
  /** Fetched and parsed. Says nothing about whether any data was present. */
  ok: boolean;
  /** `ok` AND every series carried a referenceTime. Key analysis on this. */
  complete: boolean;
  /** How many of SERIES had a referenceTime. */
  seriesPresent: number;
  httpStatus: number | null;
  elapsedMs: number;
  bytes: number | null;
  /** series name -> ISO referenceTime, or null when absent from the response. */
  referenceTimes: Record<string, string | null>;
  error: string | null;
}

/**
 * Pull every distinct `referenceTime` under a series node. The API nests these
 * differently per series (`mediumRange.mean.referenceTime`,
 * `shortRange.series.referenceTime`), so walk rather than assume a shape.
 * @param {unknown} node Parsed JSON subtree for one series.
 * @return {string|null} The referenceTime found, or null when the series is
 *   absent or empty. Multiple distinct values are joined with "|" so an
 *   internally inconsistent series is visible in the data instead of hidden.
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
 * Build a sample from a raw response. Split out from the fetch so it is
 * testable without network access.
 * @param {object} args Raw response parts.
 * @param {number|null} args.httpStatus HTTP status, null if the request threw.
 * @param {string|null} args.body Response body, null if the request threw.
 * @param {number} args.elapsedMs Wall-clock duration.
 * @param {string|null} args.error Transport-level error, if any.
 * @return {ProbeSample} The sample, never throwing.
 */
export function buildSample(args: {
  httpStatus: number | null;
  body: string | null;
  elapsedMs: number;
  error: string | null;
}): ProbeSample {
  const {httpStatus, body, elapsedMs} = args;
  const sample: ProbeSample = {
    sampledAt: admin.firestore.Timestamp.now(),
    ok: false,
    complete: false,
    seriesPresent: 0,
    httpStatus,
    elapsedMs,
    bytes: body === null ? null : Buffer.byteLength(body, "utf8"),
    referenceTimes: Object.fromEntries(SERIES.map((s) => [s, null])),
    error: args.error,
  };

  if (args.error !== null) return sample;
  if (httpStatus === null || httpStatus < 200 || httpStatus >= 300) {
    sample.error = `HTTP ${httpStatus}`;
    return sample;
  }
  if (body === null) {
    sample.error = "empty body";
    return sample;
  }

  let json: Record<string, unknown>;
  try {
    json = JSON.parse(body) as Record<string, unknown>;
  } catch (e) {
    sample.error = e instanceof Error ? e.message : String(e);
    return sample;
  }

  for (const s of SERIES) {
    sample.referenceTimes[s] = referenceTimeOf(json[s]);
  }
  sample.seriesPresent =
    Object.values(sample.referenceTimes).filter((v) => v !== null).length;
  sample.ok = true;
  sample.complete = sample.seriesPresent === SERIES.length;
  if (!sample.complete) {
    const missing = SERIES.filter((s) => sample.referenceTimes[s] === null);
    sample.error = `missing series: ${missing.join(",")}`;
  }
  return sample;
}

/**
 * Take one sample. Never throws: a failed probe is a data point, not an error.
 * @return {Promise<ProbeSample>} The recorded sample.
 */
export async function probeOnce(): Promise<ProbeSample> {
  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);

  try {
    const res = await fetch(PROBE_URL, {
      signal: controller.signal,
      headers: {"User-Agent": "RIVR-cadence-probe/1.0"},
    });
    const body = await res.text();
    return buildSample({
      httpStatus: res.status,
      body,
      elapsedMs: Date.now() - started,
      error: null,
    });
  } catch (e) {
    return buildSample({
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
 * Hourly cadence probe. Writes one document per sample to `publish_cadence_log`.
 *
 * Storage is deliberately append-only and flat: a week of hourly samples is 168
 * documents, and the analysis (when does a run actually land, how late, how
 * often does the fetch fail) is far easier over rows than over an aggregate that
 * has already thrown away the shape.
 *
 * The log line is emitted BEFORE the write and the write is guarded, so a
 * Firestore failure loses the document but never the observation — review found
 * the first version could drop a sample leaving neither, which is this repo's
 * documented silent-failure mode reproduced in new code.
 */
export const probePublishCadence = functions
  .runWith({memory: "256MB", timeoutSeconds: 180})
  .pubsub.schedule("0 * * * *")
  .timeZone("UTC")
  .onRun(async () => {
    const sample = await probeOnce();

    const rt = SERIES.map((s) => `${s}=${sample.referenceTimes[s] ?? "-"}`)
      .join(" ");
    if (sample.complete) {
      logger.info(
        `📈 cadence ok ${sample.elapsedMs}ms ${sample.bytes}B ${rt}`
      );
    } else if (sample.ok) {
      logger.warn(
        `📈 cadence DEGRADED ${sample.seriesPresent}/${SERIES.length} series ` +
        `${sample.elapsedMs}ms ${sample.bytes}B ${rt} — ${sample.error}`
      );
    } else {
      logger.warn(
        `📈 cadence FAIL ${sample.elapsedMs}ms ` +
        `http=${sample.httpStatus} err=${sample.error}`
      );
    }

    try {
      await db.collection("publish_cadence_log").add(sample);
    } catch (e) {
      // A lost document is a gap in the dataset. Say so loudly — guard 1 asks
      // for no gaps over an hour, and an unlogged gap is undetectable.
      logger.error(
        "📈 cadence WRITE FAILED — sample lost, dataset now has a gap",
        {error: e instanceof Error ? e.message : String(e)}
      );
    }
  });
