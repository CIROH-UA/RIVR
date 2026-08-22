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

import * as functions from "firebase-functions/v1";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/** Unfiltered streamflow returns every series' referenceTime in one response. */
const PROBE_URL =
  "https://api.water.noaa.gov/nwps/v1/reaches/9962444/streamflow";

/** Generous: we are measuring how slow it gets, not enforcing a budget. */
const PROBE_TIMEOUT_MS = 120_000;

const SERIES = [
  "analysisAssimilation",
  "shortRange",
  "mediumRange",
  "longRange",
] as const;

interface ProbeSample {
  sampledAt: FirebaseFirestore.Timestamp;
  ok: boolean;
  httpStatus: number | null;
  elapsedMs: number;
  bytes: number | null;
  /** series name -> ISO referenceTime, or null when absent from the response. */
  referenceTimes: Record<string, string | null>;
  error: string | null;
}

/**
 * Pull every distinct `referenceTime` under a series node. The API nests these
 * differently per series (mean/member1..6 for mediumRange, series.data for
 * shortRange), so walk rather than assume a shape.
 * @param {unknown} node Parsed JSON subtree for one series.
 * @return {string|null} The single referenceTime found, or null.
 */
function referenceTimeOf(node: unknown): string | null {
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
  // More than one would mean the series is not internally consistent — worth
  // seeing in the data rather than silently picking the first.
  return Array.from(found).sort().join("|");
}

/**
 * Take one sample. Never throws: a failed probe is a data point, not an error.
 * @return {Promise<ProbeSample>} The recorded sample.
 */
export async function probeOnce(): Promise<ProbeSample> {
  const started = Date.now();
  const base: ProbeSample = {
    sampledAt: admin.firestore.Timestamp.now(),
    ok: false,
    httpStatus: null,
    elapsedMs: 0,
    bytes: null,
    referenceTimes: Object.fromEntries(SERIES.map((s) => [s, null])),
    error: null,
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);

  try {
    const res = await fetch(PROBE_URL, {
      signal: controller.signal,
      headers: {"User-Agent": "RIVR-cadence-probe/1.0"},
    });
    base.httpStatus = res.status;

    const text = await res.text();
    base.bytes = Buffer.byteLength(text, "utf8");
    base.elapsedMs = Date.now() - started;

    if (!res.ok) {
      base.error = `HTTP ${res.status}`;
      return base;
    }

    const json = JSON.parse(text) as Record<string, unknown>;
    for (const s of SERIES) {
      base.referenceTimes[s] = referenceTimeOf(json[s]);
    }
    base.ok = true;
    return base;
  } catch (e) {
    base.elapsedMs = Date.now() - started;
    base.error = e instanceof Error ? e.message : String(e);
    return base;
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
 */
export const probePublishCadence = functions
  .runWith({memory: "256MB", timeoutSeconds: 180})
  .pubsub.schedule("0 * * * *")
  .timeZone("UTC")
  .onRun(async () => {
    const sample = await probeOnce();

    await db.collection("publish_cadence_log").add(sample);

    // Logged as one line so a week reads cleanly in Cloud Logging without
    // opening Firestore.
    const rt = SERIES.map((s) => `${s}=${sample.referenceTimes[s] ?? "-"}`)
      .join(" ");
    if (sample.ok) {
      logger.info(
        `📈 cadence ok ${sample.elapsedMs}ms ${sample.bytes}B ${rt}`
      );
    } else {
      logger.warn(
        `📈 cadence FAIL ${sample.elapsedMs}ms ` +
        `http=${sample.httpStatus} err=${sample.error}`
      );
    }
  });
