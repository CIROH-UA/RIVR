// functions/src/store-document.ts
//
// ADR 0011 Phase 4, step 2: the shape of one stored document.
//
// The app already defines this envelope. A store document is exactly what
// `RiverDataEntry.toJson()` produces, because Phase 5 will read these documents
// straight through `RiverDataEntry.fromJson`:
//
//   lib/models/1_domain/shared/river_data/river_data_entry.dart
//   lib/models/1_domain/shared/river_data/freshness_window.dart
//   lib/models/1_domain/shared/river_data/publish_schedule.dart
//   lib/services/4_infrastructure/river_data/nwm_data_source.dart      (validUntil)
//   lib/services/4_infrastructure/river_data/geoglows_data_source.dart (validUntil)
//
// This is the second half of a cross-language contract, like store-keys.ts, and
// it fails the same silent way: a field named differently here decodes as null
// on the client, and `RiverDataEntry.fromJson` either throws inside the app or
// yields an entry with a missing payload. Neither shows up server-side.
//
// Phase 4's requirements this file implements:
//   - "Store the native upstream unit, never a user preference" (decision 12)
//   - "Each record carries the referenceTime it actually received"
//   - "Every document carries a schema version" (guard 10)
//   - "Overlapping runs cannot write backwards" (guard 6)

import {
  ForecastProductId,
  ForecastSourceId,
  storageKey,
} from "./store-keys.js";

/**
 * Must equal Dart `RiverDataEntry.schemaVersion`.
 *
 * The client DISCARDS entries whose version it does not recognise rather than
 * parsing them, so a mismatch here means every document written is silently
 * dropped on read — the store appears to work and delivers nothing.
 */
export const STORE_SCHEMA_VERSION = 1;

/**
 * Slack past a publish boundary before a value counts as stale, mirroring
 * `NwmDataSource._skew`. Without it the client invalidates the instant a cycle
 * rolls over and refetches before the new run has actually published.
 *
 * PROVISIONAL — 5 minutes is the app's current guess, not a measurement. The
 * Phase 0 probe is collecting publication lag per series (median and worst);
 * once seven consecutive days are in, this must be re-derived from the worst
 * observed lag and changed in BOTH places. Gate: ADR 0011 Phase 0 guard 2,
 * expected ~2026-08-31.
 */
export const PUBLISH_SKEW_MS = 5 * 60 * 1000;

/** The freshness window, exactly as `FreshnessWindow.toJson()` writes it. */
export interface StoreWindow {
  fetchedAt: string;
  validUntil: string;
}

/** One stored document. Field names and order mirror RiverDataEntry.toJson(). */
export interface StoreDocument {
  schema: number;
  source: ForecastSourceId;
  reachId: string;
  product: ForecastProductId;
  window: StoreWindow;
  unit: string;
  /** Present only when the upstream response carried a run identity. */
  runId?: string;
  payload: Record<string, unknown>;
}

// ── Publish schedule ─────────────────────────────────────────────────────────
// Mirrors Dart PublishSchedule. "Next" is strictly after `now` — a value
// fetched exactly on a boundary is valid until the following one.

/** Next top of the hour, strictly after [now]. @param {Date} now - Reference. @return {Date} Boundary. */
export function nextTopOfHour(now: Date): Date {
  const d = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()
  ));
  return new Date(d.getTime() + 3600_000);
}

/**
 * Next [everyHours]-hour cycle boundary after [now], aligned to 00:00 UTC.
 * @param {Date} now - Reference instant.
 * @param {number} everyHours - Cycle length; must divide 24.
 * @return {Date} The next boundary.
 */
export function nextCycle(now: Date, everyHours: number): Date {
  if (everyHours <= 0 || 24 % everyHours !== 0) {
    throw new Error(`nextCycle: everyHours must divide 24, got ${everyHours}`);
  }
  const dayStart = Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const cycleMs = everyHours * 3600_000;
  const elapsed = now.getTime() - dayStart;
  return new Date(dayStart + (Math.floor(elapsed / cycleMs) + 1) * cycleMs);
}

/** Next 00:00 UTC strictly after [now]. @param {Date} now - Reference. @return {Date} Midnight. */
export function nextUtcMidnight(now: Date): Date {
  const dayStart = Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return new Date(dayStart + 24 * 3600_000);
}

/** Thirty days — products that do not move day to day. */
const STATIC_PRODUCT_MS = 30 * 24 * 3600_000;

/**
 * When a product could next possibly publish, plus skew.
 *
 * Mirrors `NwmDataSource.validUntil` and `GeoglowsDataSource.validUntil`. A
 * disagreement means the client considers a just-written document already
 * stale (refetching upstream, defeating the store) or fresh past its run
 * (showing yesterday's water).
 *
 * @param {ForecastSourceId} source - Which network.
 * @param {ForecastProductId} product - Which product.
 * @param {Date} now - When the value was fetched.
 * @return {Date} The validUntil instant.
 */
export function validUntil(
  source: ForecastSourceId,
  product: ForecastProductId,
  now: Date
): Date {
  if (source === "geoglows") {
    switch (product) {
    case "geoglowsForecast":
    case "geoglowsEnsemble":
      return new Date(nextUtcMidnight(now).getTime() + PUBLISH_SKEW_MS);
    default:
      throw new Error(`GEOGLOWS does not support ${product}`);
    }
  }

  switch (product) {
  case "analysisAssimilation":
  case "shortRange":
    // Hourly, driven by current flow.
    return new Date(nextTopOfHour(now).getTime() + PUBLISH_SKEW_MS);
  case "mediumRange":
  case "longRange":
    // Every 6 hours (00/06/12/18Z).
    return new Date(nextCycle(now, 6).getTime() + PUBLISH_SKEW_MS);
  case "returnPeriods":
  case "reachMetadata":
    // Thresholds do not change day to day; a river's name does not change.
    return new Date(now.getTime() + STATIC_PRODUCT_MS);
  default:
    throw new Error(`NWM does not support ${product}`);
  }
}

// ── Document construction ────────────────────────────────────────────────────

export interface BuildDocumentInput {
  source: ForecastSourceId;
  reachId: string;
  product: ForecastProductId;
  /** Trimmed payload — only what the app actually reads. */
  payload: Record<string, unknown>;
  /** The NATIVE upstream unit (decision 12), never a user preference. */
  unit: string;
  /**
   * The run identity the response actually carried, or null when it carried
   * none. Never fabricate one: an invented run makes every refetch look like
   * new data and defeats supersession.
   */
  referenceTime: string | null;
  /** When this fetch completed. */
  fetchedAt: Date;
}

/**
 * Build one store document.
 *
 * @param {BuildDocumentInput} input - The fetched value and its provenance.
 * @return {StoreDocument} A document ready to write, whose ID is
 *   `documentIdFor(input)`.
 */
export function buildStoreDocument(input: BuildDocumentInput): StoreDocument {
  const {source, reachId, product, payload, unit, referenceTime, fetchedAt} =
    input;

  if (!unit || unit.trim() === "") {
    // A document with no unit is unreadable: the client converts from `unit`
    // to the user's display unit, and cannot guess.
    throw new Error(
      `buildStoreDocument: unit is required (${source}/${reachId}/${product})`
    );
  }
  if (payload === null || typeof payload !== "object" ||
      Array.isArray(payload)) {
    throw new Error(
      "buildStoreDocument: payload must be a JSON object " +
      `(${source}/${reachId}/${product})`
    );
  }
  if (Number.isNaN(fetchedAt.getTime())) {
    throw new Error("buildStoreDocument: fetchedAt is not a valid date");
  }

  // Throws on an empty or separator-bearing reach id.
  storageKey(source, reachId, product);

  const doc: StoreDocument = {
    schema: STORE_SCHEMA_VERSION,
    source,
    reachId,
    product,
    window: {
      fetchedAt: fetchedAt.toISOString(),
      validUntil: validUntil(source, product, fetchedAt).toISOString(),
    },
    unit,
    payload,
  };
  // Omitted entirely when absent, matching Dart's `if (runId != null)`.
  if (referenceTime) doc.runId = referenceTime;
  return doc;
}

/** The Firestore document ID for a built document. @param {StoreDocument} doc - The document. @return {string} Its ID. */
export function documentIdFor(doc: StoreDocument): string {
  return storageKey(doc.source, doc.reachId, doc.product);
}

// ── Supersession (guard 6) ───────────────────────────────────────────────────

/**
 * Whether [incoming] may replace [existing].
 *
 * Phase 4 guard 6: "Overlapping runs cannot write backwards — a write carrying
 * an older referenceTime must not replace a newer one." Two runs can overlap
 * whenever one is slow, and the late one may be carrying the OLDER run. Without
 * this check the store would flap between runs and a user could watch the
 * forecast move backwards.
 *
 * Rules, in order:
 *  - No existing document: write.
 *  - Different schema version: write. The reader discards unrecognised
 *    versions anyway, so refusing would strand the document permanently.
 *  - Both carry a run: write only if the incoming run is strictly newer.
 *    Equal runs are NOT rewritten — same run means same data, and rewriting
 *    burns a Firestore write to change nothing but a timestamp.
 *  - Neither carries a run: write. Without run identity the only ordering
 *    available is arrival, and the fresher fetch is the better value.
 *  - Existing has a run, incoming does not: refuse. Going from identified to
 *    unidentified loses the ability to order future writes at all.
 *  - Existing has none, incoming does: write. Gaining run identity is progress.
 *
 * @param {StoreDocument | null | undefined} existing - Current document, if any.
 * @param {StoreDocument} incoming - The candidate write.
 * @return {boolean} True when the write should proceed.
 */
export function shouldWrite(
  existing: StoreDocument | null | undefined,
  incoming: StoreDocument
): boolean {
  if (!existing) return true;
  if (existing.schema !== incoming.schema) return true;

  const had = existing.runId;
  const has = incoming.runId;

  if (had && has) return isRunNewer(has, had);
  if (had && !has) return false;
  return true;
}

/**
 * Compare two run identities. NWM and GEOGLOWS both publish ISO-8601
 * `referenceTime` strings, so parse and compare as instants; fall back to
 * string comparison when either is unparseable, which keeps a non-ISO run
 * format ordering sensibly rather than silently always writing.
 *
 * @param {string} candidate - The incoming run.
 * @param {string} current - The stored run.
 * @return {boolean} True when [candidate] is strictly newer than [current].
 */
export function isRunNewer(candidate: string, current: string): boolean {
  const a = Date.parse(candidate);
  const b = Date.parse(current);
  if (!Number.isNaN(a) && !Number.isNaN(b)) return a > b;
  return candidate > current;
}
