// functions/src/store-gc.ts
//
// ADR 0011 Phase 4, step 7: drop documents nobody follows any more.
//
//   "GC documents absent from the union and unrefreshed for ~7 days."
//   Guard 7: "Unfavouriting everywhere removes the reach from the work list;
//   the document SURVIVES the GC window and is then deleted."
//
// The delay is the whole point and is easy to mistake for a bug. Deleting the
// instant a reach leaves the work list would mean a user who unfavourites and
// immediately re-favourites gets a cold read, and — worse — a transient failure
// in the user query would present as "nobody follows anything" and wipe the
// entire store in one run. The window turns that catastrophe into a delay.
//
// Selection is pure: it takes the work list and a listing of what is stored,
// and returns what to delete. Nothing here performs a delete, so the decision
// is testable without touching Firestore and the destructive step stays in one
// obvious place at the call site.

import {ParsedStorageKey, parseStorageKey} from "./store-keys.js";
import {WorkList} from "./store-work-list.js";

/**
 * How long an unfollowed document survives before deletion.
 *
 * The ADR says "~7 days". It is a deliberate safety margin, not a tuning
 * parameter: it must comfortably exceed the longest plausible outage of the
 * user query that feeds the work list, because that query returning empty is
 * indistinguishable from every user unfavouriting everything.
 */
export const GC_GRACE_MS = 7 * 24 * 60 * 60 * 1000;

/** One stored document as the GC needs to see it. */
export interface StoredDocumentSummary {
  documentId: string;
  /** `window.fetchedAt` — when the value was last refreshed. */
  fetchedAt: string;
}

export type GcSkipReason =
  | "still-followed"
  | "within-grace"
  | "unparseable-id"
  | "unreadable-timestamp";

export interface GcCandidate {
  documentId: string;
  key: ParsedStorageKey;
  ageMs: number;
}

export interface GcDecision {
  /** Safe to delete: unfollowed AND past the grace window. */
  toDelete: GcCandidate[];
  /** Everything retained, with the reason, so a surprising run is auditable. */
  retained: {documentId: string; reason: GcSkipReason}[];
  scanned: number;
}

/**
 * Decide which stored documents may be deleted.
 *
 * A document is deleted only when BOTH are true: its (source, reachId) is
 * absent from the work list, and it has not been refreshed within
 * [GC_GRACE_MS]. Either alone is insufficient — a followed reach is kept
 * however old, and an unfollowed one is kept until the window passes.
 *
 * Unrecognised document IDs are retained, never deleted. This collection may
 * one day hold something this code does not know about, and a garbage
 * collector that deletes what it cannot parse is a data-loss bug waiting for
 * the first unrelated document.
 *
 * @param {WorkList} workList - Reaches currently followed.
 * @param {StoredDocumentSummary[]} stored - Everything in the store.
 * @param {Date} now - Reference instant.
 * @return {GcDecision} What to delete, and why everything else was kept.
 */
export function selectGarbage(
  workList: WorkList,
  stored: StoredDocumentSummary[],
  now: Date
): GcDecision {
  const followed = new Set(
    workList.entries.map((e) => `${e.source}:${e.reachId}`)
  );

  const decision: GcDecision = {
    toDelete: [],
    retained: [],
    scanned: stored.length,
  };

  for (const doc of stored) {
    const key = parseStorageKey(doc.documentId);
    if (!key) {
      decision.retained.push({
        documentId: doc.documentId, reason: "unparseable-id",
      });
      continue;
    }

    if (followed.has(`${key.source}:${key.reachId}`)) {
      decision.retained.push({
        documentId: doc.documentId, reason: "still-followed",
      });
      continue;
    }

    const fetchedAt = Date.parse(doc.fetchedAt);
    if (Number.isNaN(fetchedAt)) {
      // Cannot prove it is old enough, so keep it. Deleting on an unreadable
      // timestamp would make a formatting change into data loss.
      decision.retained.push({
        documentId: doc.documentId, reason: "unreadable-timestamp",
      });
      continue;
    }

    const ageMs = now.getTime() - fetchedAt;
    if (ageMs < GC_GRACE_MS) {
      decision.retained.push({
        documentId: doc.documentId, reason: "within-grace",
      });
      continue;
    }

    decision.toDelete.push({documentId: doc.documentId, key, ageMs});
  }

  return decision;
}

/**
 * Thrown when a GC run looks like it is about to do something catastrophic.
 */
export class GcAssertionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GcAssertionError";
  }
}

/**
 * Refuse a GC run that would delete an implausible share of the store.
 *
 * The failure this prevents: the user query behind the work list fails or
 * returns an empty page, every reach looks unfollowed, and one run deletes
 * everything. The grace window already delays that by a week, but a week later
 * the same empty work list would still authorise it. So a run that wants to
 * delete most of the store stops and asks for a human instead.
 *
 * @param {GcDecision} decision - The proposed deletions.
 * @param {WorkList} workList - The work list the decision was made against.
 * @param {number} maxFraction - Largest share deletable in one run.
 * @throws {GcAssertionError} When the run looks like a wipe rather than a tidy.
 */
export function assertGcSane(
  decision: GcDecision,
  workList: WorkList,
  maxFraction = 0.5
): void {
  if (decision.toDelete.length === 0) return;

  if (workList.entries.length === 0) {
    throw new GcAssertionError(
      `GC would delete ${decision.toDelete.length} documents while the work ` +
      "list is EMPTY — an empty work list is indistinguishable from a failed " +
      "user query, so this is refused rather than treated as 'nobody follows " +
      "anything'"
    );
  }

  const fraction = decision.toDelete.length / Math.max(decision.scanned, 1);
  if (fraction > maxFraction) {
    throw new GcAssertionError(
      `GC would delete ${decision.toDelete.length} of ${decision.scanned} ` +
      `documents (${Math.round(fraction * 100)}%), over the ` +
      `${Math.round(maxFraction * 100)}% ceiling — refusing a bulk delete ` +
      "that was not explicitly authorised"
    );
  }
}
