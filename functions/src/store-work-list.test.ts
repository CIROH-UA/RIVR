// functions/src/store-work-list.test.ts
//
// ADR 0011 Phase 4, step 1. The work list carries the phase's entire cost
// argument — "cost scales with distinct favourited reaches × cadence, not with
// users", and guard 8's "two users favouriting one reach produce one document
// and one fetch". Both are claims about deduplication, so they are what these
// tests assert.
//
// The assertion helper is tested as carefully as the derivation. CLAUDE.md's
// non-negotiable for these pipelines is that they fail *silently* — five
// operations have exited 0 while producing wrong or partial data — and Phase 4
// guard 12 requires that a broken run raises an alarm rather than passing
// quietly. An assertion that cannot fail is worse than none, because it reads
// like coverage.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  FavouritingUser,
  WorkList,
  WorkListAssertionError,
  assertWorkListConsistent,
  deriveWorkList,
} from "./store-work-list.js";

function user(
  userId: string,
  favoriteReachIds: unknown,
  favoriteSources: Record<string, string> = {}
): FavouritingUser {
  return {userId, favoriteReachIds, favoriteSources};
}

/** Entry lookup by (source, reachId), so assertions do not depend on order. */
function entry(list: WorkList, source: string, reachId: string) {
  return list.entries.find(
    (e) => e.source === source && e.reachId === reachId
  );
}

describe("deduplication — the phase's cost argument", () => {
  // Guard 8, stated directly.
  test("two users favouriting one reach produce ONE entry", () => {
    const list = deriveWorkList([
      user("a", ["123"]),
      user("b", ["123"]),
    ]);

    assert.equal(list.entries.length, 1,
      "overlap between users must not multiply the work");
    assert.equal(entry(list, "nwm", "123")?.followerCount, 2);
    assert.equal(list.summary.favouriteRowsSeen, 2,
      "both rows were seen — the collapse is dedupe, not a dropped read");
  });

  test("distinct reaches stay distinct", () => {
    const list = deriveWorkList([
      user("a", ["1", "2"]),
      user("b", ["2", "3"]),
    ]);
    assert.equal(list.summary.distinctReaches, 3);
    assert.equal(entry(list, "nwm", "2")?.followerCount, 2);
    assert.equal(entry(list, "nwm", "1")?.followerCount, 1);
  });

  // An NWM comid and a GEOGLOWS linkno can be numerically identical. Deduping
  // on reachId alone would collapse two different rivers into one document and
  // let one network's data overwrite the other's.
  test("the same id on different sources is two reaches, not one", () => {
    const list = deriveWorkList([
      user("a", ["760021642"]),
      user("b", ["760021642"], {"760021642": "geoglows"}),
    ]);

    assert.equal(list.entries.length, 2);
    assert.equal(entry(list, "nwm", "760021642")?.followerCount, 1);
    assert.equal(entry(list, "geoglows", "760021642")?.followerCount, 1);
    assert.deepEqual(list.summary.bySource, {nwm: 1, geoglows: 1});
  });

  test("one user listing a reach twice is one follower, not two", () => {
    const list = deriveWorkList([user("a", ["123", "123"])]);
    assert.equal(list.entries.length, 1);
    assert.equal(entry(list, "nwm", "123")?.followerCount, 1,
      "a duplicated row in one document is not a second follower");
  });
});

describe("source resolution follows the app's rule", () => {
  test("only an explicit geoglows entry is geoglows", () => {
    const list = deriveWorkList([
      user("a", ["1", "2", "3"], {"2": "geoglows", "3": "something-else"}),
    ]);
    assert.equal(entry(list, "nwm", "1")?.source, "nwm");
    assert.equal(entry(list, "geoglows", "2")?.source, "geoglows");
    assert.equal(entry(list, "nwm", "3")?.source, "nwm",
      "an unrecognised source value falls back to NWM, as in the app");
  });

  test("a missing favoriteSources map is all NWM", () => {
    const list = deriveWorkList([{userId: "a", favoriteReachIds: ["1"]}]);
    assert.equal(entry(list, "nwm", "1")?.source, "nwm");
  });
});

describe("malformed input is counted and skipped, never thrown on", () => {
  // One bad favourite must not cost every other reach its refresh.
  test("non-strings, blanks and separator-bearing ids are rejected", () => {
    const list = deriveWorkList([
      user("a", ["good", "", "  ", 42, null, {x: 1}, "has__separator"]),
    ]);

    assert.equal(list.entries.length, 1);
    assert.equal(entry(list, "nwm", "good")?.followerCount, 1);
    assert.equal(list.summary.favouriteRowsSeen, 7);
    assert.equal(list.summary.favouriteRowsRejected, 6);
  });

  test("ids are trimmed before use", () => {
    const list = deriveWorkList([user("a", ["  123  "]), user("b", ["123"])]);
    assert.equal(list.entries.length, 1,
      "whitespace must not fork one reach into two documents");
    assert.equal(entry(list, "nwm", "123")?.followerCount, 2);
  });

  test("users with no favourites are scanned but contribute nothing", () => {
    const list = deriveWorkList([
      user("a", []),
      user("b", undefined),
      user("c", "not-an-array"),
      user("d", ["1"]),
    ]);
    assert.equal(list.summary.usersScanned, 4);
    assert.equal(list.summary.usersWithFavourites, 1);
    assert.equal(list.summary.distinctReaches, 1);
  });

  test("no users at all is an empty list, not an error", () => {
    const list = deriveWorkList([]);
    assert.deepEqual(list.entries, []);
    assert.equal(list.summary.distinctReaches, 0);
    assert.doesNotThrow(() => assertWorkListConsistent(list, 0));
  });
});

describe("the count assertion can actually fail", () => {
  test("a consistent list passes", () => {
    const list = deriveWorkList([user("a", ["1"]), user("b", ["1", "2"])]);
    assert.doesNotThrow(() => assertWorkListConsistent(list, 2));
  });

  test("fewer users scanned than were read is caught", () => {
    const list = deriveWorkList([user("a", ["1"])]);
    // The signature of a user read that returned a partial page.
    assert.throws(() => assertWorkListConsistent(list, 18),
      WorkListAssertionError);
  });

  test("a summary disagreeing with the entries is caught", () => {
    const list = deriveWorkList([user("a", ["1", "2"])]);
    list.summary.distinctReaches = 99;
    assert.throws(() => assertWorkListConsistent(list, 1),
      WorkListAssertionError);
  });

  test("per-source counts that do not total the entries are caught", () => {
    const list = deriveWorkList([user("a", ["1", "2"])]);
    list.summary.bySource.nwm = 1; // one entry unaccounted for
    assert.throws(() => assertWorkListConsistent(list, 1),
      WorkListAssertionError);
  });

  test("more distinct reaches than accepted rows is caught", () => {
    const list = deriveWorkList([user("a", ["1"])]);
    list.summary.favouriteRowsSeen = 1;
    list.summary.favouriteRowsRejected = 1; // accepted = 0, but 1 entry exists
    assert.throws(() => assertWorkListConsistent(list, 1),
      WorkListAssertionError);
  });

  // The one that matters most: an empty work list looks exactly like a clean
  // run with nothing to do, and would let a failed user read pass as success.
  test("favourites held but nothing derived is refused, not called idle", () => {
    const list = deriveWorkList([user("a", ["1"])]);
    list.entries.length = 0;
    list.summary.distinctReaches = 0;
    list.summary.bySource = {nwm: 0, geoglows: 0};

    assert.throws(
      () => assertWorkListConsistent(list, 1),
      (e: unknown) => e instanceof WorkListAssertionError &&
        /refusing to treat this as 'nothing to do'/.test(e.message),
      "an empty list with users holding favourites must raise, not pass"
    );
  });
});

describe("production shape", () => {
  // ADR 0011 records the live scale: 18 users, 14 with favourites, 36
  // favourite rows, 29 distinct reaches. Reproducing those ratios keeps the
  // derivation honest about the case it actually runs against — 36 rows
  // collapsing to 29 means 7 shared follows.
  test("36 rows across 14 of 18 users collapse to 29 distinct reaches", () => {
    const users: FavouritingUser[] = [];

    // 18 users, 4 of them holding nothing.
    for (let i = 0; i < 4; i++) users.push(user(`empty${i}`, []));

    // 29 distinct reaches spread round-robin over the 14 who do.
    const rows: string[][] = Array.from({length: 14}, () => []);
    for (let r = 0; r < 29; r++) rows[r % 14].push(`r${r}`);

    // 7 shared follows: user i also follows a reach OWNED by another user, so
    // each is a genuine second follower rather than a within-user duplicate.
    for (let i = 0; i < 7; i++) rows[i].push(`r${i + 7}`);

    for (let i = 0; i < 14; i++) users.push(user(`u${i}`, rows[i]));

    const list = deriveWorkList(users);
    assert.equal(list.summary.usersScanned, 18);
    assert.equal(list.summary.usersWithFavourites, 14);
    assert.equal(list.summary.favouriteRowsSeen, 36);
    assert.equal(list.summary.favouriteRowsRejected, 0);
    assert.equal(list.summary.distinctReaches, 29,
      "36 rows over 29 reaches means 7 shared follows the store fetches once");
    assert.doesNotThrow(() => assertWorkListConsistent(list, 18));

    // The cost claim, arithmetically: 7 fetches saved by overlap.
    const totalFollows = list.entries
      .reduce((n, e) => n + e.followerCount, 0);
    assert.equal(totalFollows, 36);
    assert.equal(totalFollows - list.entries.length, 7);
  });
});
