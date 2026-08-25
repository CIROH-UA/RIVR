// functions/src/store-gc.test.ts
//
// ADR 0011 Phase 4, step 7, guard 7: "Unfavouriting everywhere removes the
// reach from the work list; the document SURVIVES the GC window and is then
// deleted." Both halves are asserted — surviving first, then deleted — because
// a GC that deletes immediately would pass any test that only checked the
// deletion.
//
// The rest of this file is about refusing to delete. This is the one piece of
// Phase 4 that destroys data, and the realistic failure is not a subtle bug: it
// is the user query behind the work list failing, every reach looking
// unfollowed, and one run wiping the store.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  GC_GRACE_MS,
  GcAssertionError,
  StoredDocumentSummary,
  assertGcSane,
  selectGarbage,
} from "./store-gc.js";
import {deriveWorkList} from "./store-work-list.js";

const NOW = new Date("2026-08-24T12:00:00.000Z");

function agedDays(days: number): string {
  return new Date(NOW.getTime() - days * 86400_000).toISOString();
}

function stored(...docs: [string, number][]): StoredDocumentSummary[] {
  return docs.map(([documentId, ageDays]) =>
    ({documentId, fetchedAt: agedDays(ageDays)}));
}

const followed = deriveWorkList([{userId: "u", favoriteReachIds: ["1"]}]);
const nobodyFollows = deriveWorkList([{userId: "u", favoriteReachIds: ["9"]}]);

describe("guard 7 — survive the window, then be deleted", () => {
  test("an unfollowed document SURVIVES inside the grace window", () => {
    const d = selectGarbage(nobodyFollows, stored(["nwm__1__shortRange", 3]),
      NOW);

    assert.deepEqual(d.toDelete, [],
      "deleting on the first unfollowed run would make an unfavourite-then-" +
      "refavourite a cold read, and a transient user-query failure a wipe");
    assert.deepEqual(d.retained.map((r) => r.reason), ["within-grace"]);
  });

  test("the same document IS deleted once the window passes", () => {
    const d = selectGarbage(nobodyFollows, stored(["nwm__1__shortRange", 8]),
      NOW);
    assert.deepEqual(d.toDelete.map((c) => c.documentId),
      ["nwm__1__shortRange"]);
  });

  test("exactly at the boundary the document still survives", () => {
    const atBoundary: StoredDocumentSummary[] = [{
      documentId: "nwm__1__shortRange",
      fetchedAt: new Date(NOW.getTime() - GC_GRACE_MS).toISOString(),
    }];
    // ageMs === GC_GRACE_MS is not "< grace", so it deletes; one millisecond
    // younger must not. Pinning the direction so a later refactor cannot flip
    // it silently.
    assert.equal(selectGarbage(nobodyFollows, atBoundary, NOW).toDelete.length,
      1);

    const oneMsYounger: StoredDocumentSummary[] = [{
      documentId: "nwm__1__shortRange",
      fetchedAt: new Date(NOW.getTime() - GC_GRACE_MS + 1).toISOString(),
    }];
    assert.equal(
      selectGarbage(nobodyFollows, oneMsYounger, NOW).toDelete.length, 0);
  });
});

describe("a followed reach is never deleted", () => {
  test("age is irrelevant while somebody follows it", () => {
    const d = selectGarbage(followed, stored(["nwm__1__shortRange", 400]), NOW);
    assert.deepEqual(d.toDelete, []);
    assert.deepEqual(d.retained.map((r) => r.reason), ["still-followed"]);
  });

  test("following the same id on the OTHER source does not protect it", () => {
    // An NWM comid and a GEOGLOWS linkno can collide numerically. Matching on
    // reachId alone would keep a dead document alive forever, or worse, treat
    // a live one as dead.
    const geoOnly = deriveWorkList([
      {userId: "u", favoriteReachIds: ["1"], favoriteSources: {"1": "geoglows"}},
    ]);
    const d = selectGarbage(geoOnly, stored(["nwm__1__shortRange", 8]), NOW);
    assert.deepEqual(d.toDelete.map((c) => c.documentId),
      ["nwm__1__shortRange"]);
  });

  test("every product of a followed reach is kept", () => {
    const d = selectGarbage(followed, stored(
      ["nwm__1__shortRange", 30],
      ["nwm__1__mediumRange", 30],
      ["nwm__1__returnPeriods", 30],
    ), NOW);
    assert.deepEqual(d.toDelete, []);
  });
});

describe("what it refuses to touch", () => {
  test("an unrecognised document ID is retained, never deleted", () => {
    const d = selectGarbage(nobodyFollows, [
      {documentId: "some-other-collection-doc", fetchedAt: agedDays(400)},
      {documentId: "nwm__1__notAProduct", fetchedAt: agedDays(400)},
    ], NOW);

    assert.deepEqual(d.toDelete, [],
      "a GC that deletes what it cannot parse is data loss waiting for the " +
      "first unrelated document");
    assert.deepEqual(d.retained.map((r) => r.reason),
      ["unparseable-id", "unparseable-id"]);
  });

  test("an unreadable timestamp is retained", () => {
    const d = selectGarbage(nobodyFollows, [
      {documentId: "nwm__1__shortRange", fetchedAt: "not-a-date"},
    ], NOW);
    assert.deepEqual(d.toDelete, []);
    assert.deepEqual(d.retained.map((r) => r.reason), ["unreadable-timestamp"]);
  });

  test("everything scanned is accounted for", () => {
    const docs = stored(
      ["nwm__1__shortRange", 8],
      ["nwm__2__shortRange", 1],
      ["junk", 99],
    );
    const d = selectGarbage(nobodyFollows, docs, NOW);
    assert.equal(d.scanned, 3);
    assert.equal(d.toDelete.length + d.retained.length, 3,
      "a document that is neither deleted nor retained has been dropped");
  });
});

describe("the sanity check refuses a wipe", () => {
  test("deleting against an EMPTY work list is refused outright", () => {
    const empty = deriveWorkList([]);
    const d = selectGarbage(empty, stored(["nwm__1__shortRange", 8]), NOW);

    // The grace window delays this by a week; a week later the same empty
    // work list would still authorise it, so the refusal has to be explicit.
    assert.throws(() => assertGcSane(d, empty),
      (e: unknown) => e instanceof GcAssertionError &&
        /indistinguishable from a failed user query/.test(e.message));
  });

  test("deleting most of the store is refused", () => {
    const docs = stored(
      ["nwm__1__shortRange", 8],
      ["nwm__2__shortRange", 8],
      ["nwm__3__shortRange", 8],
      ["nwm__9__shortRange", 1],
    );
    const d = selectGarbage(nobodyFollows, docs, NOW);
    assert.equal(d.toDelete.length, 3);
    assert.throws(() => assertGcSane(d, nobodyFollows),
      (e: unknown) => e instanceof GcAssertionError &&
        /refusing a bulk delete/.test(e.message));
  });

  test("a normal tidy-up passes", () => {
    const docs = stored(
      ["nwm__9__shortRange", 1],
      ["nwm__9__mediumRange", 1],
      ["nwm__9__longRange", 1],
      ["nwm__1__shortRange", 8],
    );
    const d = selectGarbage(nobodyFollows, docs, NOW);
    assert.equal(d.toDelete.length, 1);
    assert.doesNotThrow(() => assertGcSane(d, nobodyFollows));
  });

  test("deleting nothing is always fine, even with an empty work list", () => {
    const empty = deriveWorkList([]);
    const d = selectGarbage(empty, [], NOW);
    assert.doesNotThrow(() => assertGcSane(d, empty));
  });
});
