// functions/src/store-alert-source.ts
//
// ADR 0011 Phase 6 guard 1: "Alerts issue ZERO upstream fetches."
//
// Alerts used to call NOAA and GEOGLOWS themselves, once per reach per slot,
// four times a day. Everything they need is already in the store — Phase 4 puts
// it there for the app — so this maps stored documents into the exact `ReachData`
// shape `evaluateAlert` already consumes, and the alert path stops touching
// upstream at all.
//
// **No fallback to the live path, deliberately.** A missing document is not a
// transient blip to paper over: Phase 4 keeps a document for every favourited
// reach, so its absence means the store has a hole, and falling back would hide
// exactly the failure the store exists to eliminate. The reach is skipped and
// named in the log instead.
//
// ── Units, which are the easiest thing here to get silently wrong ────────────
//
// `evaluateAlert` expects the FORECAST in CFS and the THRESHOLDS in CMS. That
// asymmetry is not an accident — geoglows-client.ts already converts its
// forecast CMS→CFS and leaves its return periods in CMS for the same reason —
// but it means a mapper that passes stored values straight through is wrong
// half the time:
//
//   NWM shortRange / mediumRange   stored CFS   -> pass through
//   NWM returnPeriods              stored CMS   -> pass through
//   GEOGLOWS forecast              stored CMS   -> CONVERT to CFS
//   GEOGLOWS returnPeriods         stored CMS   -> pass through
//
// The stored `unit` field is read rather than assumed, so a reach stored in the
// other unit converts instead of silently reporting a flood or missing one.

import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";

import {ForecastData, ReachData, ReachSource} from "./notification-service.js";
import {ForecastProductId, STORE_COLLECTION, storageKey}
  from "./store-keys.js";

const CMS_TO_CFS = 35.3147;

/** Products the alert path needs, per source. */
export const ALERT_PRODUCTS: Readonly<Record<ReachSource, ForecastProductId[]>>
  = {
    nwm: ["shortRange", "mediumRange", "returnPeriods", "reachMetadata"],
    geoglows: ["geoglowsForecast"],
  };

/** One stored document, reduced to what the mapping needs. */
export interface StoredDoc {
  product: ForecastProductId;
  unit: string;
  payload: Record<string, unknown>;
}

/**
 * Convert a stored flow to CFS, which is what `evaluateAlert` expects.
 *
 * @param {number} value - The stored value.
 * @param {string} unit - The unit the document declares.
 * @return {number} The value in CFS.
 */
function toCfs(value: number, unit: string): number {
  return unit.toUpperCase() === "CMS" ? value * CMS_TO_CFS : value;
}

/** A `{validTime, flow}` row as the NWM store writes it. */
interface StoredPoint {
  validTime?: unknown;
  flow?: unknown;
}

/**
 * Turn a stored NWM series into the `ForecastData` shape alerts consume.
 *
 * Points without a finite flow are dropped rather than passed through as NaN:
 * `getMaxForecastFlow` compares with `>`, and a NaN never wins, but it would
 * also never be reported — so dropping them keeps the reason visible.
 *
 * @param {unknown} node - The stored series node.
 * @param {string} unit - The document's unit.
 * @return {ForecastData | null} The series, or null when empty.
 */
function seriesFrom(node: unknown, unit: string): ForecastData | null {
  if (node === null || typeof node !== "object") return null;
  const data = (node as {data?: unknown}).data;
  if (!Array.isArray(data)) return null;

  const values: ForecastData["values"] = [];
  for (const raw of data as StoredPoint[]) {
    if (raw === null || typeof raw !== "object") continue;
    const flow = raw.flow;
    const validTime = raw.validTime;
    if (typeof flow !== "number" || !Number.isFinite(flow)) continue;
    values.push({
      value: toCfs(flow, unit),
      validTime: typeof validTime === "string" ? validTime : "",
    });
  }
  return values.length > 0 ? {values} : null;
}

/**
 * Map an NWM reach's stored documents into `ReachData`.
 *
 * @param {string} reachId - The reach.
 * @param {Map<ForecastProductId, StoredDoc>} docs - Its stored documents.
 * @return {ReachData | null} The alert input, or null when unusable.
 */
function nwmReachData(
  reachId: string,
  docs: Map<ForecastProductId, StoredDoc>
): ReachData | null {
  const short = docs.get("shortRange");
  const medium = docs.get("mediumRange");

  const shortRange = short ?
    seriesFrom(
      (short.payload.shortRange as {series?: unknown} | undefined)?.series,
      short.unit) :
    null;
  const mediumRange = medium ?
    seriesFrom(
      (medium.payload.mediumRange as {mean?: unknown} | undefined)?.mean,
      medium.unit) :
    null;

  // Nothing to evaluate. evaluateAlert would refuse this anyway; refusing here
  // keeps the reason attributable to the store rather than to the forecast.
  if (shortRange === null && mediumRange === null) return null;

  const rpDoc = docs.get("returnPeriods");
  // Stored exactly as the upstream hands it over — an array whose first entry
  // carries `return_period_*` fields — which is what
  // extractReturnPeriodThresholds already parses.
  const returnPeriods = Array.isArray(rpDoc?.payload.returnPeriods) ?
    rpDoc.payload.returnPeriods as unknown[] :
    [];

  const metaDoc = docs.get("reachMetadata");
  const storedName = metaDoc?.payload.riverName;
  const riverName = typeof storedName === "string" && storedName.trim() !== "" ?
    storedName :
    `Reach ${reachId}`;

  return {forecast: {shortRange, mediumRange}, returnPeriods, riverName};
}

/** A `{t, median}` row as the GEOGLOWS store writes it. */
interface StoredGeoglowsPoint {
  t?: unknown;
  median?: unknown;
}

/**
 * Map a GEOGLOWS reach's stored document into `ReachData`.
 *
 * The median series is surfaced as `shortRange` for the same reason
 * geoglows-client.ts does it: `getMaxForecastFlow` reads shortRange and
 * mediumRange, and this is the one horizon GEOGLOWS publishes.
 *
 * @param {string} reachId - The reach.
 * @param {Map<ForecastProductId, StoredDoc>} docs - Its stored documents.
 * @return {ReachData | null} The alert input, or null when unusable.
 */
function geoglowsReachData(
  reachId: string,
  docs: Map<ForecastProductId, StoredDoc>
): ReachData | null {
  const doc = docs.get("geoglowsForecast");
  if (!doc) return null;

  const points = doc.payload.points;
  if (!Array.isArray(points)) return null;

  const values: ForecastData["values"] = [];
  for (const raw of points as StoredGeoglowsPoint[]) {
    if (raw === null || typeof raw !== "object") continue;
    const median = raw.median;
    if (typeof median !== "number" || !Number.isFinite(median)) continue;
    values.push({
      value: toCfs(median, doc.unit),
      validTime: typeof raw.t === "string" ? raw.t : "",
    });
  }
  if (values.length === 0) return null;

  // Stored as a map {"2": v, "5": v, ...} in CMS. evaluateAlert's parser wants
  // the upstream array-of-one shape with `return_period_*` keys, so rebuild it
  // rather than teaching the parser a second dialect.
  const rp = doc.payload.returnPeriods;
  const row: Record<string, number> = {};
  if (rp !== null && typeof rp === "object" && !Array.isArray(rp)) {
    for (const [years, value] of Object.entries(rp as Record<string, unknown>)) {
      if (typeof value === "number" && Number.isFinite(value)) {
        row[`return_period_${years}`] = value;
      }
    }
  }

  return {
    forecast: {shortRange: {values}, mediumRange: null},
    returnPeriods: Object.keys(row).length > 0 ? [row] : [],
    // GEOGLOWS reaches are unnamed upstream; geoglows-client.ts uses the same
    // fallback, and the notification title leads with this string.
    riverName: `Stream ${reachId}`,
  };
}

/**
 * Map one reach's stored documents into the alert path's `ReachData`.
 *
 * Pure, so the unit handling and the shape mapping are testable without
 * Firestore — the same reason evaluateAlert and the work list are pure.
 *
 * @param {ReachSource} source - Which network.
 * @param {string} reachId - The reach.
 * @param {Map<ForecastProductId, StoredDoc>} docs - Its stored documents.
 * @return {ReachData | null} The alert input, or null when unusable.
 */
export function reachDataFromStore(
  source: ReachSource,
  reachId: string,
  docs: Map<ForecastProductId, StoredDoc>
): ReachData | null {
  return source === "geoglows" ?
    geoglowsReachData(reachId, docs) :
    nwmReachData(reachId, docs);
}

/**
 * Read the alert inputs for every reach from the store.
 *
 * The drop-in replacement for `batchFetchReachData`, and the whole of guard 1:
 * it performs Firestore reads and ZERO upstream calls.
 *
 * @param {Array<{source: ReachSource, reachId: string}>} reaches - Reaches to
 *   read.
 * @return {Promise<Map<string, ReachData>>} Keyed `source:reachId`.
 */
export async function readAlertDataFromStore(
  reaches: Array<{source: ReachSource; reachId: string}>
): Promise<Map<string, ReachData>> {
  const db = admin.firestore();
  const out = new Map<string, ReachData>();
  if (reaches.length === 0) return out;

  const wanted: Array<{
    source: ReachSource;
    reachId: string;
    product: ForecastProductId;
    id: string;
  }> = [];
  for (const {source, reachId} of reaches) {
    for (const product of ALERT_PRODUCTS[source]) {
      wanted.push({
        source, reachId, product,
        id: storageKey(source, reachId, product),
      });
    }
  }

  // getAll takes the whole set in one round trip and bills one read per
  // document, the same as fetching them individually would.
  const refs = wanted.map(
    ({id}) => db.collection(STORE_COLLECTION).doc(id));
  const snaps = await db.getAll(...refs);

  const byReach = new Map<string, Map<ForecastProductId, StoredDoc>>();
  snaps.forEach((snap, i) => {
    if (!snap.exists) return;
    const data = snap.data() ?? {};
    const payload = data.payload;
    if (payload === null || typeof payload !== "object") return;

    const {source, reachId, product} = wanted[i];
    const key = `${source}:${reachId}`;
    const forReach = byReach.get(key) ??
      new Map<ForecastProductId, StoredDoc>();
    forReach.set(product, {
      product,
      unit: typeof data.unit === "string" ? data.unit : "",
      payload: payload as Record<string, unknown>,
    });
    byReach.set(key, forReach);
  });

  const missing: string[] = [];
  for (const {source, reachId} of reaches) {
    const key = `${source}:${reachId}`;
    const docs = byReach.get(key) ?? new Map<ForecastProductId, StoredDoc>();
    const data = reachDataFromStore(source, reachId, docs);
    if (data === null) {
      missing.push(key);
      continue;
    }
    out.set(key, data);
  }

  if (missing.length > 0) {
    // Not a warning. Phase 4 keeps a document for every favourited reach, so
    // this means the store has a hole for a reach a user is following, and no
    // alert can fire for it until the hole is filled. Silence here is how the
    // store's own failures would become invisible.
    logger.error("🕳️ alert inputs missing from the store", {
      count: missing.length,
      reaches: missing.slice(0, 20),
    });
  }

  return out;
}
