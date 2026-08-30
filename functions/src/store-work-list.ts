// functions/src/store-work-list.ts
//
// ADR 0011 Phase 4, step 1: derive the work list — the set of reaches the
// cloud store is responsible for keeping fresh.
//
// The ADR's cost model rests on this being a *deduplicated* set:
//
//   "Cost scales with distinct favourited reaches × cadence, not with users."
//                        (ADR 0011, "Current scale", under Existing assets)
//   "Two users favouriting one reach produce one document and one fetch."
//                                                  (ADR 0011 Phase 4 guard 8)
//
// So the whole economic claim of the phase is that this function collapses
// overlap. It is pure — plain records in, plain records out, no Firestore — so
// that claim is testable without mocking anything, matching how evaluateAlert
// and the publish-cadence probe are tested in this repo.
//
// **This is NOT the alert audience.** getNotificationUsers() in
// notification-service filters to users with notifications enabled, a valid FCM
// token and a frequency matching the time slot. The store serves the app's read
// path (Phase 5), so it must cover every favourited reach regardless of whether
// its owner wants notifications. Reusing the alert query here would silently
// under-cover the store — favourites belonging to notification-disabled users
// would never be stored, and those users' app would fall back to fetching
// upstream with no error anywhere.

import {sourceOfFavourite} from "./notification-service.js";
import {ForecastProductId, ForecastSourceId, storageKey}
  from "./store-keys.js";
import {canFetch} from "./store-upstream.js";

/**
 * The fields of a user document this derivation reads. Deliberately narrow:
 * the work list has no business knowing about tokens, names or preferences.
 */
export interface FavouritingUser {
  userId: string;
  favoriteReachIds?: unknown;
  favoriteSources?: Record<string, string>;
}

/** One reach the store is responsible for. */
export interface WorkListEntry {
  source: ForecastSourceId;
  reachId: string;
  /** `source:reachId` — dedupe identity, NOT the Firestore document ID. */
  dedupeKey: string;
  /** How many users follow this reach. Drives nothing; reported for cost. */
  followerCount: number;
}

/**
 * Counts that make truncation visible. Every number here is derived from a
 * different place in the loop, so a silent drop shows up as an inconsistency
 * rather than as a smaller-but-plausible total.
 */
export interface WorkListSummary {
  usersScanned: number;
  usersWithFavourites: number;
  /** Total favourite rows seen, before dedupe. */
  favouriteRowsSeen: number;
  /** Rows rejected as malformed (non-string, empty, separator-bearing). */
  favouriteRowsRejected: number;
  /** Distinct reaches after dedupe — the number that drives cost. */
  distinctReaches: number;
  bySource: Record<ForecastSourceId, number>;
}

export interface WorkList {
  entries: WorkListEntry[];
  summary: WorkListSummary;
}

/** `source:reachId`. Distinct from storageKey, which is a document ID. */
function dedupeKeyFor(source: ForecastSourceId, reachId: string): string {
  return `${source}:${reachId}`;
}

/**
 * Collapse every user's favourites into the deduplicated set of reaches the
 * store must keep fresh.
 *
 * A reach id is only meaningful within its source — an NWM comid and a GEOGLOWS
 * linkno can be numerically identical — so dedupe is on (source, reachId), not
 * on reachId alone. Collapsing those would make one network's data overwrite
 * the other's under a single document.
 *
 * Malformed rows are counted and skipped rather than thrown on: one bad
 * favourite must not cost every other reach its refresh.
 *
 * @param {FavouritingUser[]} users - Every user document, already read.
 * @return {WorkList} Deduplicated entries plus the counts to assert on.
 */
export function deriveWorkList(users: FavouritingUser[]): WorkList {
  const byKey = new Map<string, WorkListEntry>();
  const summary: WorkListSummary = {
    usersScanned: 0,
    usersWithFavourites: 0,
    favouriteRowsSeen: 0,
    favouriteRowsRejected: 0,
    distinctReaches: 0,
    bySource: {nwm: 0, geoglows: 0},
  };

  for (const user of users) {
    summary.usersScanned++;

    const rows = user.favoriteReachIds;
    if (!Array.isArray(rows) || rows.length === 0) continue;
    summary.usersWithFavourites++;

    // A user listing the same reach twice must not count as two followers.
    const seenForThisUser = new Set<string>();

    for (const row of rows) {
      summary.favouriteRowsSeen++;

      if (typeof row !== "string" || row.trim() === "" || row.includes("__")) {
        // "__" is the storage-key separator; a reach id carrying it would make
        // the document ID ambiguous to parse back, which Phase 4's GC and
        // monitoring both need to do.
        summary.favouriteRowsRejected++;
        continue;
      }

      const reachId = row.trim();
      const source = sourceOfFavourite(user.favoriteSources, reachId);
      const key = dedupeKeyFor(source, reachId);

      if (seenForThisUser.has(key)) continue;
      seenForThisUser.add(key);

      const existing = byKey.get(key);
      if (existing) {
        existing.followerCount++;
      } else {
        byKey.set(key, {source, reachId, dedupeKey: key, followerCount: 1});
      }
    }
  }

  const entries = Array.from(byKey.values());
  summary.distinctReaches = entries.length;
  for (const e of entries) summary.bySource[e.source]++;

  return {entries, summary};
}

/**
 * Thrown when a run's own numbers disagree with each other.
 *
 * CLAUDE.md's non-negotiable for these pipelines: they fail *silently*, five
 * separate operations have exited 0 while producing wrong or partial data, and
 * exit status has never caught one. Phase 4 guard 12 says the same. So the run
 * asserts on counts and refuses to proceed rather than writing a plausible
 * subset.
 */
export class WorkListAssertionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WorkListAssertionError";
  }
}

/**
 * Check a derived work list against what the caller expected before anything
 * downstream acts on it.
 *
 * Deliberately strict about zero: a work list that collapses to nothing when
 * users *do* hold favourites is the signature of a failed or partial user
 * read, and it would otherwise look like a clean run with nothing to do.
 *
 * @param {WorkList} list - The derived list.
 * @param {number} expectedUsers - How many user documents were read.
 * @throws {WorkListAssertionError} When the numbers cannot all be true.
 */
export function assertWorkListConsistent(
  list: WorkList,
  expectedUsers: number
): void {
  const s = list.summary;

  if (s.usersScanned !== expectedUsers) {
    throw new WorkListAssertionError(
      `scanned ${s.usersScanned} users but ${expectedUsers} were read — ` +
      "the derivation dropped users"
    );
  }

  if (s.distinctReaches !== list.entries.length) {
    throw new WorkListAssertionError(
      `summary says ${s.distinctReaches} distinct reaches but ` +
      `${list.entries.length} entries were produced`
    );
  }

  const bySourceTotal = s.bySource.nwm + s.bySource.geoglows;
  if (bySourceTotal !== list.entries.length) {
    throw new WorkListAssertionError(
      `per-source counts total ${bySourceTotal} but ${list.entries.length} ` +
      "entries were produced — a source is unaccounted for"
    );
  }

  const accepted = s.favouriteRowsSeen - s.favouriteRowsRejected;
  if (s.distinctReaches > accepted) {
    throw new WorkListAssertionError(
      `${s.distinctReaches} distinct reaches from only ${accepted} accepted ` +
      "favourite rows — dedupe cannot produce more than it consumed"
    );
  }

  if (s.usersWithFavourites > 0 && s.distinctReaches === 0) {
    throw new WorkListAssertionError(
      `${s.usersWithFavourites} users hold favourites but the work list is ` +
      "empty — refusing to treat this as 'nothing to do'"
    );
  }
}

/**
 * Document IDs the work list covers, for the products under consideration.
 *
 * Anything in the collection outside this set is an orphan: a reach nobody
 * favourites any more, still inside the GC's grace, which no run will rewrite.
 *
 * @param {WorkList} workList - Reaches the store keeps fresh.
 * @param {readonly ForecastProductId[]} products - Products under refresh.
 * @return {Set<string>} Document IDs a run could actually update.
 */
export function liveDocumentIdsFor(
  workList: WorkList,
  products: readonly ForecastProductId[]
): Set<string> {
  const ids = new Set<string>();
  for (const entry of workList.entries) {
    for (const product of products) {
      // A product this source cannot serve has no document to sample.
      if (!canFetch(entry.source, product, entry.reachId)) continue;
      ids.add(storageKey(entry.source, entry.reachId, product));
    }
  }
  return ids;
}
