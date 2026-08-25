// functions/src/store-run.ts
//
// ADR 0011 Phase 4, steps 3-5: one update run over the work list, with the
// count assertion built in rather than added afterwards.
//
// Phase 4 guards this implements:
//   1. "No new run -> zero fetches beyond the probe."
//   2. "A new run -> every reach in the work list updated, count assertion
//      matches."
//   3. "A reach returning an older referenceTime than the probe is stored with
//      its OWN value and retried — never written under the probe's run."
//   4. "A reach failing entirely leaves its previous record intact and is
//      retried."
//   6. "Overlapping runs cannot write backwards." (delegated to shouldWrite)
//  12. "Silent failure is impossible: kill the fetch mid-run and confirm the
//      count assertion fires."
//
// Why the counting is this pedantic. CLAUDE.md's non-negotiable for these
// pipelines: they fail *silently*, five separate operations have exited 0 while
// producing wrong or partial data, and exit status has never caught one of
// them. So every unit of work leaves exactly one outcome behind, the outcomes
// must sum to the work planned, and a run that cannot prove that throws instead
// of reporting success.
//
// All I/O is injected. The orchestration is then testable with plain fakes and
// no mocking library, matching how the rest of functions/ is tested.

import * as logger from "firebase-functions/logger";

import {
  StoreDocument,
  buildStoreDocument,
  documentIdFor,
  shouldWrite,
} from "./store-document.js";
import {ForecastProductId, ForecastSourceId, storageKey} from "./store-keys.js";
import {WorkList, WorkListEntry} from "./store-work-list.js";

/** What a source returned for one (reach, product). */
export interface FetchedProduct {
  payload: Record<string, unknown>;
  /** The NATIVE upstream unit. */
  unit: string;
  /** The run the response actually carried, or null. Never fabricated. */
  referenceTime: string | null;
}

/** Everything the run touches that is not pure computation. */
export interface StoreRunDeps {
  /** Existing document, or null. Used for the supersession check. */
  readExisting(documentId: string): Promise<StoreDocument | null>;
  /** Persist a document under its ID. */
  writeDocument(documentId: string, doc: StoreDocument): Promise<void>;
  /** Fetch one product for one reach. Throwing marks that reach failed. */
  fetchProduct(
    source: ForecastSourceId,
    reachId: string,
    product: ForecastProductId,
  ): Promise<FetchedProduct>;
  /** Injected so tests are deterministic. */
  now(): Date;
}

/** One unit of work: a reach crossed with a product. */
export interface PlannedWrite {
  entry: WorkListEntry;
  product: ForecastProductId;
  documentId: string;
}

export type WriteOutcome =
  | "written"
  | "skipped-superseded"
  | "failed";

export interface WriteResult {
  documentId: string;
  reachId: string;
  source: ForecastSourceId;
  product: ForecastProductId;
  outcome: WriteOutcome;
  /** The run actually stored, when one was. */
  storedRun?: string | null;
  /** Present when outcome is "failed". */
  error?: string;
}

export interface StoreRunReport {
  /** Products whose upstream run advanced, so this run acted on them. */
  productsTriggered: ForecastProductId[];
  planned: number;
  written: number;
  skippedSuperseded: number;
  failed: number;
  /** Reaches with at least one failure — the retry set for the next cycle. */
  reachesToRetry: string[];
  results: WriteResult[];
  fetches: number;
}

/**
 * Thrown when a run's outcomes do not account for the work it planned.
 *
 * Deliberately fatal. A run that cannot prove it did what it planned has
 * produced an unknown partial state, and reporting success would be exactly
 * the silent failure this project has hit five times.
 */
export class StoreRunAssertionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "StoreRunAssertionError";
  }
}

/**
 * Which products a source serves. Mirrors `supportedProducts` on
 * NwmDataSource and GeoglowsDataSource — a product a source cannot serve must
 * never be planned, or every reach on that source would count as failed.
 */
export const PRODUCTS_BY_SOURCE: Record<
  ForecastSourceId,
  readonly ForecastProductId[]
> = {
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

/**
 * Cross the work list with the products whose runs advanced.
 *
 * @param {WorkList} workList - Reaches the store is responsible for.
 * @param {ForecastProductId[]} triggered - Products to refresh this run.
 * @return {PlannedWrite[]} One entry per document that will be attempted.
 */
export function planWrites(
  workList: WorkList,
  triggered: readonly ForecastProductId[]
): PlannedWrite[] {
  const planned: PlannedWrite[] = [];
  for (const entry of workList.entries) {
    const supported = PRODUCTS_BY_SOURCE[entry.source];
    for (const product of triggered) {
      if (!supported.includes(product)) continue;
      planned.push({
        entry,
        product,
        documentId: storageKey(entry.source, entry.reachId, product),
      });
    }
  }
  return planned;
}

/**
 * Run one store update.
 *
 * Guard 1 is structural: when `triggered` is empty nothing is planned, so the
 * run performs zero fetches. The caller decides what advanced by comparing the
 * probe's referenceTime to what is stored; this function does not fetch to find
 * out, because that would be the very fetch the guard forbids.
 *
 * A reach whose fetch throws leaves its previous document untouched (guard 4)
 * and lands in `reachesToRetry`. One reach failing never aborts the others.
 *
 * @param {WorkList} workList - Reaches to keep fresh.
 * @param {ForecastProductId[]} triggered - Products whose run advanced.
 * @param {StoreRunDeps} deps - Injected I/O.
 * @return {Promise<StoreRunReport>} The run's outcomes, already asserted.
 */
export async function runStoreUpdate(
  workList: WorkList,
  triggered: readonly ForecastProductId[],
  deps: StoreRunDeps
): Promise<StoreRunReport> {
  const planned = planWrites(workList, triggered);

  const report: StoreRunReport = {
    productsTriggered: [...triggered],
    planned: planned.length,
    written: 0,
    skippedSuperseded: 0,
    failed: 0,
    reachesToRetry: [],
    results: [],
    fetches: 0,
  };

  if (planned.length === 0) {
    // Guard 1. Logged rather than silent so "nothing advanced" is auditable
    // and distinguishable from "the run never ran".
    logger.info("🟰 store run: nothing advanced, zero fetches", {
      workListSize: workList.entries.length,
    });
    assertStoreRunConsistent(report);
    return report;
  }

  const retry = new Set<string>();

  for (const plan of planned) {
    const {entry, product, documentId} = plan;
    try {
      report.fetches++;
      const fetched = await deps.fetchProduct(
        entry.source, entry.reachId, product);

      const doc = buildStoreDocument({
        source: entry.source,
        reachId: entry.reachId,
        product,
        payload: fetched.payload,
        unit: fetched.unit,
        // Guard 3: the reach's OWN referenceTime, never the probe's. A reach
        // that came back on an older run is stored honestly under that run and
        // retried, which is what makes atomic publication irrelevant.
        referenceTime: fetched.referenceTime,
        fetchedAt: deps.now(),
      });

      const existing = await deps.readExisting(documentId);
      if (!shouldWrite(existing, doc)) {
        report.skippedSuperseded++;
        report.results.push({
          documentId,
          reachId: entry.reachId,
          source: entry.source,
          product,
          outcome: "skipped-superseded",
          storedRun: existing?.runId ?? null,
        });
        continue;
      }

      await deps.writeDocument(documentId, doc);
      report.written++;
      report.results.push({
        documentId,
        reachId: entry.reachId,
        source: entry.source,
        product,
        outcome: "written",
        storedRun: doc.runId ?? null,
      });
    } catch (error) {
      // Guard 4: the previous record is left intact — nothing was written —
      // and the reach is retried next cycle.
      report.failed++;
      retry.add(entry.reachId);
      report.results.push({
        documentId,
        reachId: entry.reachId,
        source: entry.source,
        product,
        outcome: "failed",
        error: error instanceof Error ? error.message : String(error),
      });
      logger.warn("⚠️ store run: reach failed, previous record left intact", {
        documentId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  report.reachesToRetry = Array.from(retry);

  // Guard 2 and guard 12. Throws rather than returns — see the class comment.
  assertStoreRunConsistent(report);

  logger.info("✅ store run complete", {
    planned: report.planned,
    written: report.written,
    skipped: report.skippedSuperseded,
    failed: report.failed,
    reachesToRetry: report.reachesToRetry.length,
  });

  return report;
}

/**
 * Every planned write must have left exactly one outcome behind.
 *
 * @param {StoreRunReport} report - The run to check.
 * @throws {StoreRunAssertionError} When the outcomes cannot all be true.
 */
export function assertStoreRunConsistent(report: StoreRunReport): void {
  const accounted =
    report.written + report.skippedSuperseded + report.failed;

  if (accounted !== report.planned) {
    throw new StoreRunAssertionError(
      `planned ${report.planned} writes but only ${accounted} outcomes were ` +
      `recorded (${report.written} written, ${report.skippedSuperseded} ` +
      `skipped, ${report.failed} failed) — the run ended in an unknown state`
    );
  }

  if (report.results.length !== report.planned) {
    throw new StoreRunAssertionError(
      `planned ${report.planned} writes but produced ${report.results.length} ` +
      "result records"
    );
  }

  if (report.fetches > report.planned) {
    throw new StoreRunAssertionError(
      `${report.fetches} fetches for ${report.planned} planned writes — ` +
      "a reach was fetched more than once"
    );
  }

  // Guard 1, asserted rather than assumed: nothing planned means nothing
  // fetched. A non-zero count here is the store fetching on a cycle where
  // upstream did not publish, which is the cost the phase exists to remove.
  if (report.planned === 0 && report.fetches !== 0) {
    throw new StoreRunAssertionError(
      `nothing was planned but ${report.fetches} fetches were made — ` +
      "'no new run means no fetches' is violated"
    );
  }

  const retryFromResults = new Set(
    report.results.filter((r) => r.outcome === "failed").map((r) => r.reachId)
  );
  if (retryFromResults.size !== report.reachesToRetry.length) {
    throw new StoreRunAssertionError(
      `${retryFromResults.size} reaches failed but ` +
      `${report.reachesToRetry.length} were queued for retry — a failure ` +
      "would be dropped"
    );
  }
}

/** Convenience for logging/monitoring: the document IDs a run wrote. */
export function writtenDocumentIds(report: StoreRunReport): string[] {
  return report.results
    .filter((r) => r.outcome === "written")
    .map((r) => r.documentId);
}

/** Re-exported so callers building documents do not need two imports. */
export {documentIdFor};
