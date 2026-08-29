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
 * Slack past a publish boundary before a value counts as stale.
 *
 * THE TWO SOURCES DO NOT USE THE SAME VALUE, and treating them as one is a
 * live defect: the server stamps a validUntil the client disagrees with, so
 * the client treats a just-written document as already stale and refetches
 * upstream — defeating the store, with no error anywhere. A single shared
 * constant here shipped exactly that bug for GEOGLOWS before review caught it.
 *
 *   NWM      `NwmDataSource._skew`      = 5 minutes
 *   GEOGLOWS `GeoglowsDataSource._skew` = 15 minutes
 *              ("Slack past 00Z: the proxy has a cold start and the run isn't
 *               instant" — a different physical reason, hence a different
 *               number.)
 *
 * PROVISIONAL — both are the app's current guesses, not measurements. The
 * Phase 0 probe is collecting publication lag per series (median and worst);
 * once seven consecutive days are in, each must be re-derived from the worst
 * observed lag for ITS source and changed in all THREE places: the two Dart
 * data sources and here. Gate: ADR 0011 Phase 0 guard 2, expected ~2026-08-31.
 */
export const NWM_SKEW_MS = 5 * 60 * 1000;
export const GEOGLOWS_SKEW_MS = 15 * 60 * 1000;

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

// ── Refresh coverage (store-only) ────────────────────────────────────────────
//
// `validUntil` above answers "when could upstream next publish?". That is the
// right question for a LIVE fetch on the device, and the two Dart data sources
// answer it identically — the drift test pins the skews.
//
// It is the WRONG question for a stored document, and Phase 5 proved it on a
// real phone. A stored value is not replaced when upstream publishes; it is
// replaced when OUR refresher next runs and writes a new one. Those are
// different instants, and the gap between them is dead air: the document is
// present, correct, still the newest that exists, and marked stale, so every
// device abandons the store and fetches live.
//
// Measured 2026-08-28: hourly documents were written at :20 and stamped
// valid until :05, so from :05 to :20 — 15 minutes of every hour — every
// hourly document in the store was expired. A clean-install device tested at
// 15:14 UTC fell through to 78 NOAA calls. The same device tested at 15:34,
// inside the covered window, made zero. GEOGLOWS has the same shape daily
// (expires 00:15, refreshes 01:30 — 75 minutes) and long range is worse still.
//
// So a stored window carries a FLOOR: it never ends before the refresher that
// owns it has had its next turn, plus room to finish. The skew constants are
// untouched and still mirror the client exactly; this is an additional store
// -only guarantee layered on top, not a redefinition of publication lag.
//
// The trade, stated plainly: inside the floor a device may render the previous
// run for up to one refresh interval rather than fetching a newer one itself.
// That is the Phase 5 bargain — trust the store — and it buys back 15 minutes
// an hour during which every device was bypassing the store entirely.

/** Minute past the hour that `storeRefreshHourly` is scheduled for. */
export const REFRESH_MINUTE = 20;

/** UTC hour and minute that `storeGeoglowsDaily` is scheduled for. */
export const GEOGLOWS_REFRESH_HOUR = 1;
export const GEOGLOWS_REFRESH_MINUTE = 30;

/**
 * Room for a refresh run to actually finish after it starts.
 *
 * Observed spread of `fetchedAt` across one run is ~2 minutes for 30 reaches
 * (09:20:13 to 09:21:56 on 2026-08-28). Ten minutes is that with room for a
 * slow upstream, and it is still far inside the next cycle.
 */
export const REFRESH_MARGIN_MS = 10 * 60 * 1000;

/**
 * When the hourly refresher next starts, strictly after [now].
 *
 * @param {Date} now - Reference instant.
 * @return {Date} The next :REFRESH_MINUTE past the hour.
 */
export function nextHourlyRefresh(now: Date): Date {
  const at = Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
    now.getUTCHours(), REFRESH_MINUTE);
  return at > now.getTime() ? new Date(at) : new Date(at + 3600_000);
}

/**
 * When the daily GEOGLOWS refresher next starts, strictly after [now].
 *
 * @param {Date} now - Reference instant.
 * @return {Date} The next 01:30 UTC.
 */
export function nextGeoglowsRefresh(now: Date): Date {
  const at = Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
    GEOGLOWS_REFRESH_HOUR, GEOGLOWS_REFRESH_MINUTE);
  return at > now.getTime() ? new Date(at) : new Date(at + 24 * 3600_000);
}

/**
 * The floor a stored document's window must not end before: the next turn of
 * whichever refresher owns this product, plus room to finish.
 *
 * @param {ForecastSourceId} source - Which network.
 * @param {ForecastProductId} product - Which product.
 * @param {Date} now - Reference instant.
 * @return {Date} Earliest acceptable validUntil for a stored document.
 */
export function refreshFloor(
  source: ForecastSourceId,
  product: ForecastProductId,
  now: Date
): Date {
  // Looked up from `now + margin`, not `now`. A run that starts a few minutes
  // BEFORE the scheduled minute — an off-cycle manual trigger, a retry, clock
  // skew — would otherwise pick the refresh that is about to start as its
  // rescuer, stamp a window ending before the one AFTER that, and leave the
  // very gap this floor exists to close. Observed 2026-08-29: a sweep at 02:16
  // stamped 03:05 while the next run it could rely on was 03:20.
  //
  // Reading it forward means "the next refresh that is far enough away to be a
  // real rescuer", which is the only one worth counting on.
  const from = new Date(now.getTime() + REFRESH_MARGIN_MS);
  const next = source === "geoglows" ?
    nextGeoglowsRefresh(from) :
    nextHourlyRefresh(from);
  return new Date(next.getTime() + REFRESH_MARGIN_MS);
}

/**
 * The window a STORED document carries: publication lag, floored by refresh
 * coverage.
 *
 * Static products already hold a 30-day window, which dwarfs any floor, so
 * this is a no-op for them.
 *
 * @param {ForecastSourceId} source - Which network.
 * @param {ForecastProductId} product - Which product.
 * @param {Date} now - When the value was fetched, or re-verified.
 * @return {Date} The validUntil to stamp.
 */
export function storeValidUntil(
  source: ForecastSourceId,
  product: ForecastProductId,
  now: Date
): Date {
  const publish = validUntil(source, product, now);
  const floor = refreshFloor(source, product, now);
  return publish.getTime() >= floor.getTime() ? publish : floor;
}

/** Thirty days — products that do not move day to day. */
const STATIC_PRODUCT_MS = 30 * 24 * 3600_000;

/**
 * When a product could next possibly publish, plus skew.
 *
 * Mirrors `NwmDataSource.validUntil` and `GeoglowsDataSource.validUntil`,
 * including their DIFFERENT skews. A
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
      return new Date(nextUtcMidnight(now).getTime() + GEOGLOWS_SKEW_MS);
    default:
      throw new Error(`GEOGLOWS does not support ${product}`);
    }
  }

  switch (product) {
  case "analysisAssimilation":
  case "shortRange":
    // Hourly, driven by current flow.
    return new Date(nextTopOfHour(now).getTime() + NWM_SKEW_MS);
  case "mediumRange":
  case "longRange":
    // Every 6 hours (00/06/12/18Z).
    return new Date(nextCycle(now, 6).getTime() + NWM_SKEW_MS);
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
      validUntil: storeValidUntil(source, product, fetchedAt).toISOString(),
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
