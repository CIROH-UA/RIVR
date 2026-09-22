// functions/src/guest-gc.ts
//
// ADR 0014 B3 — guest garbage collection.
//
// The app opens as a guest (anonymous Firebase user) since 2026.2.3. A guest
// who favourites a river and never returns leaves a `users/{uid}` document
// that keeps that reach in the store's hourly refresh cycle forever (ADR 0014
// M6/E2) and, if they turned alerts on, keeps receiving pushes nobody can
// switch off. Nothing else removes it: Firebase's own anonymous auto-delete
// is deliberately OFF because it deletes the Auth user and leaves the
// document (ADR 0014 B2).
//
// The shape follows store-gc.ts: a PURE decision over plain summaries, then a
// separate sanity assertion that refuses a run which looks like a wipe. The
// function in index.ts wires Auth + Firestore to these and does the deleting.
//
// The rules that must never be broken, each pinned by guest-gc.test.ts:
//   1. A user with ANY sign-in provider is never a candidate. Guest-ness is
//      decided from Auth (no providers), and cross-checked against the
//      document's isGuest flag: both must agree.
//   2. Idleness is measured from the newest of lastActiveAt, lastLoginDate,
//      and the Auth creation time. A guest with no document at all is judged
//      on creation time alone — those exist when the doc write failed at
//      sign-in and are the emptiest orphans of all.
//   3. A run that would delete more than the ceiling fraction of guests, or
//      more than an absolute cap, is refused outright.

export const GUEST_IDLE_MS = 90 * 24 * 60 * 60 * 1000;

/** What the function reads off Firebase Auth for one user. */
export interface AuthUserSummary {
  uid: string;
  /** Provider ids, e.g. ["password"]. Empty for an anonymous user. */
  providerIds: string[];
  /** ISO-8601 from UserRecord.metadata.creationTime. */
  createdAt: string;
}

/** What the function reads off users/{uid}; undefined when no doc exists. */
export interface GuestDocSummary {
  uid: string;
  isGuest: boolean;
  lastActiveAt?: string;
  lastLoginDate?: string;
  favoriteCount: number;
  hasTokens: boolean;
}

export type GuestSkipReason =
  | "has-provider"
  | "doc-says-account"
  | "active";

export interface GuestCandidate {
  uid: string;
  idleMs: number;
  favoriteCount: number;
  hasDoc: boolean;
}

export interface GuestGcDecision {
  toDelete: GuestCandidate[];
  retained: Record<GuestSkipReason, number>;
  /** Anonymous Auth users considered (the denominator for the ceiling). */
  anonymousScanned: number;
  /** Every Auth user seen, providers or not. */
  totalScanned: number;
}

function parseIso(value: string | undefined): number | null {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
}

/**
 * Decide which guests are abandoned. Pure: no I/O, no clock.
 *
 * @param {AuthUserSummary[]} authUsers - Every Auth user, from listUsers().
 * @param {Map<string, GuestDocSummary>} docs - users/{uid} summaries by uid.
 * @param {Date} now - The clock, injected so tests never depend on wall time.
 * @param {number} idleMs - Idle window; defaults to GUEST_IDLE_MS.
 * @return {GuestGcDecision} What to delete and why the rest were kept.
 */
export function selectAbandonedGuests(
  authUsers: AuthUserSummary[],
  docs: Map<string, GuestDocSummary>,
  now: Date,
  idleMs = GUEST_IDLE_MS,
): GuestGcDecision {
  const decision: GuestGcDecision = {
    toDelete: [],
    retained: {"has-provider": 0, "doc-says-account": 0, "active": 0},
    anonymousScanned: 0,
    totalScanned: authUsers.length,
  };

  for (const user of authUsers) {
    // Rule 1 — a real account is never touched, whatever the document says.
    if (user.providerIds.length > 0) {
      decision.retained["has-provider"] += 1;
      continue;
    }
    decision.anonymousScanned += 1;

    const doc = docs.get(user.uid);
    // A document that has been linked (isGuest false) while Auth still shows
    // no provider is a contradiction — most likely a link in flight. Keep.
    if (doc && !doc.isGuest) {
      decision.retained["doc-says-account"] += 1;
      continue;
    }

    // Rule 2 — newest sign of life wins.
    const signs = [
      parseIso(doc?.lastActiveAt),
      parseIso(doc?.lastLoginDate),
      parseIso(user.createdAt),
    ].filter((v): v is number => v !== null);
    const newest = signs.length > 0 ? Math.max(...signs) : null;
    if (newest === null) {
      // No parseable date anywhere: we cannot prove idleness, so keep.
      decision.retained["active"] += 1;
      continue;
    }
    const idle = now.getTime() - newest;
    if (idle < idleMs) {
      decision.retained["active"] += 1;
      continue;
    }

    decision.toDelete.push({
      uid: user.uid,
      idleMs: idle,
      favoriteCount: doc?.favoriteCount ?? 0,
      hasDoc: doc !== undefined,
    });
  }

  return decision;
}

export class GuestGcAssertionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GuestGcAssertionError";
  }
}

/**
 * Refuse a run that looks like a wipe rather than a tidy.
 *
 * Two independent ceilings, because they fail differently: the fraction
 * catches a clock or parsing bug that makes every guest look idle; the
 * absolute cap bounds the blast radius on a day when the fraction is
 * legitimately high (a launch-week surge that all lapses at once).
 *
 * @param {GuestGcDecision} decision - Output of selectAbandonedGuests.
 * @param {number} maxFraction - Largest share of anonymous users deletable.
 * @param {number} maxAbsolute - Largest count deletable in one run.
 * @throws {GuestGcAssertionError} When either ceiling is exceeded.
 */
export function assertGuestGcSane(
  decision: GuestGcDecision,
  maxFraction = 0.5,
  maxAbsolute = 500,
): void {
  const n = decision.toDelete.length;
  if (n === 0) return;
  if (decision.anonymousScanned === 0) {
    throw new GuestGcAssertionError(
      `guest GC would delete ${n} users while scanning zero anonymous users — ` +
      "the candidate list cannot be right; refusing.",
    );
  }
  const fraction = n / decision.anonymousScanned;
  if (fraction > maxFraction) {
    throw new GuestGcAssertionError(
      `guest GC would delete ${n} of ${decision.anonymousScanned} anonymous ` +
      `users (${Math.round(fraction * 100)}%), over the ` +
      `${Math.round(maxFraction * 100)}% ceiling — refusing a bulk delete.`,
    );
  }
  if (n > maxAbsolute) {
    throw new GuestGcAssertionError(
      `guest GC would delete ${n} users, over the absolute cap of ` +
      `${maxAbsolute} per run — refusing; run again tomorrow.`,
    );
  }
}
