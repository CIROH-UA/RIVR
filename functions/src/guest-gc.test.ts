// functions/src/guest-gc.test.ts
//
// ADR 0014 guard 6: guestGcDaily "refuses when more than X% of users qualify;
// never selects a user with a `password` provider." The rest pins the idle
// rule, because the realistic failure is not subtle: a date that fails to
// parse, or a clock skew, makes EVERY guest look abandoned at once.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  AuthUserSummary,
  GUEST_IDLE_MS,
  GuestDocSummary,
  GuestGcAssertionError,
  assertGuestGcSane,
  selectAbandonedGuests,
} from "./guest-gc.js";

const NOW = new Date("2026-09-21T12:00:00.000Z");

function agedDays(days: number): string {
  return new Date(NOW.getTime() - days * 86400_000).toISOString();
}

function anon(uid: string, createdDaysAgo: number): AuthUserSummary {
  return {uid, providerIds: [], createdAt: agedDays(createdDaysAgo)};
}

function account(uid: string, createdDaysAgo: number): AuthUserSummary {
  return {uid, providerIds: ["password"], createdAt: agedDays(createdDaysAgo)};
}

function doc(
  uid: string,
  fields: Partial<Omit<GuestDocSummary, "uid">> = {},
): [string, GuestDocSummary] {
  return [uid, {
    uid,
    isGuest: true,
    favoriteCount: 0,
    hasTokens: false,
    ...fields,
  }];
}

describe("rule 1 — a real account is never a candidate", () => {
  test("password provider with a 400-day-old guest-looking doc is retained", () => {
    const d = selectAbandonedGuests(
      [account("a", 400)],
      new Map([doc("a", {isGuest: true, lastActiveAt: agedDays(400)})]),
      NOW,
    );
    assert.equal(d.toDelete.length, 0);
    assert.equal(d.retained["has-provider"], 1);
    assert.equal(d.anonymousScanned, 0);
  });

  test("a doc that says isGuest=false is kept even with no provider (link in flight)", () => {
    const d = selectAbandonedGuests(
      [anon("g", 400)],
      new Map([doc("g", {isGuest: false, lastActiveAt: agedDays(400)})]),
      NOW,
    );
    assert.equal(d.toDelete.length, 0);
    assert.equal(d.retained["doc-says-account"], 1);
  });
});

describe("rule 2 — idleness is the NEWEST sign of life", () => {
  test("89 days idle is kept, 91 days is deleted", () => {
    const d = selectAbandonedGuests(
      [anon("keep", 200), anon("go", 200)],
      new Map([
        doc("keep", {lastActiveAt: agedDays(89)}),
        doc("go", {lastActiveAt: agedDays(91)}),
      ]),
      NOW,
    );
    assert.deepEqual(d.toDelete.map((c) => c.uid), ["go"]);
    assert.equal(d.retained["active"], 1);
  });

  test("a recent lastLoginDate rescues a stale lastActiveAt", () => {
    const d = selectAbandonedGuests(
      [anon("g", 200)],
      new Map([doc("g", {
        lastActiveAt: agedDays(120),
        lastLoginDate: agedDays(10),
      })]),
      NOW,
    );
    assert.equal(d.toDelete.length, 0);
  });

  test("no document at all: judged on Auth creation time alone", () => {
    const d = selectAbandonedGuests(
      [anon("fresh", 5), anon("old", 100)],
      new Map(),
      NOW,
    );
    assert.deepEqual(d.toDelete.map((c) => c.uid), ["old"]);
    assert.equal(d.toDelete[0].hasDoc, false);
  });

  test("unparseable dates everywhere: cannot prove idle, so keep", () => {
    const d = selectAbandonedGuests(
      [{uid: "g", providerIds: [], createdAt: "not a date"}],
      new Map([doc("g", {lastActiveAt: "also not a date"})]),
      NOW,
    );
    assert.equal(d.toDelete.length, 0);
    assert.equal(d.retained["active"], 1);
  });

  test("the window is 90 days", () => {
    assert.equal(GUEST_IDLE_MS, 90 * 24 * 60 * 60 * 1000);
  });

  test("candidates carry their favourite count for the log line", () => {
    const d = selectAbandonedGuests(
      [anon("g", 200)],
      new Map([doc("g", {lastActiveAt: agedDays(100), favoriteCount: 3})]),
      NOW,
    );
    assert.equal(d.toDelete[0].favoriteCount, 3);
  });
});

describe("rule 3 — refuse a wipe", () => {
  test("nothing to delete never throws", () => {
    const d = selectAbandonedGuests([anon("g", 1)], new Map(), NOW);
    assert.doesNotThrow(() => assertGuestGcSane(d));
  });

  test("deleting every guest is refused (clock-skew shape)", () => {
    const users = ["a", "b", "c", "d"].map((u) => anon(u, 200));
    const d = selectAbandonedGuests(users, new Map(), NOW);
    assert.equal(d.toDelete.length, 4);
    assert.throws(() => assertGuestGcSane(d), GuestGcAssertionError);
  });

  test("half is allowed, just over half is not", () => {
    const users = [
      anon("go1", 200), anon("go2", 200),
      anon("keep1", 1), anon("keep2", 1),
    ];
    const half = selectAbandonedGuests(users, new Map(), NOW);
    assert.doesNotThrow(() => assertGuestGcSane(half));
    const over = selectAbandonedGuests([...users, anon("go3", 200)], new Map(), NOW);
    assert.throws(() => assertGuestGcSane(over), GuestGcAssertionError);
  });

  test("accounts do not pad the denominator", () => {
    // 1 abandoned guest + 9 accounts: 100% of ANONYMOUS users, not 10%.
    const users = [anon("go", 200), ...Array.from({length: 9}, (_, i) => account(`a${i}`, 1))];
    const d = selectAbandonedGuests(users, new Map(), NOW);
    assert.equal(d.anonymousScanned, 1);
    assert.throws(() => assertGuestGcSane(d), GuestGcAssertionError);
  });

  test("the absolute cap holds even when the fraction is fine", () => {
    const users = [
      ...Array.from({length: 3}, (_, i) => anon(`go${i}`, 200)),
      ...Array.from({length: 7}, (_, i) => anon(`keep${i}`, 1)),
    ];
    const d = selectAbandonedGuests(users, new Map(), NOW);
    assert.doesNotThrow(() => assertGuestGcSane(d, 0.5, 500));
    assert.throws(() => assertGuestGcSane(d, 0.5, 2), GuestGcAssertionError);
  });

  test("a candidate list with zero anonymous scanned is impossible and refused", () => {
    assert.throws(() => assertGuestGcSane({
      toDelete: [{uid: "x", idleMs: 1, favoriteCount: 0, hasDoc: false}],
      retained: {"has-provider": 0, "doc-says-account": 0, "active": 0},
      anonymousScanned: 0,
      totalScanned: 0,
    }), GuestGcAssertionError);
  });
});
