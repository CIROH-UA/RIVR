// functions/src/stale-token-cleanup.test.ts
//
// ADR 0008 defect, observed live during ADR 0011 Phase 8 guard 5 on
// 2026-08-30: the alert run logged four stale FCM tokens and four cleanup
// FAILURES in the same cycle —
//
//   ❌ Failed to clean up stale tokens
//   "Element at index 0 is not a valid array element. Nested arrays are not
//    supported."
//
// `FieldValue.arrayRemove` takes VARARGS. Passing it one array asks Firestore
// to remove a single element that happens to be an array, which it refuses. So
// no stale token was ever pruned, and every subsequent alert cycle retried the
// same dead devices forever.
//
// **This is a source-level guard, and it says so.** Exercising the real
// behaviour needs a Firestore emulator, which this suite does not run. What it
// pins is the one character that was wrong and would be silently wrong again:
// the spread. A test that cannot fail on the actual defect is worse than none,
// so this one was mutation-checked against the exact pre-fix source.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync, readdirSync} from "node:fs";
import {resolve} from "node:path";

/**
 * EVERY file that prunes stale tokens, not just the one that was on fire.
 *
 * The first version of this test read `notification-service.ts` alone. An
 * identical `arrayRemove(staleTokens)` sat in `weekly-digest.ts` the whole
 * time, so the alert path was fixed, the guard passed, and the ADR was updated
 * to say both ADR 0008 defects were closed — while the weekly digest kept
 * failing to prune dead tokens every Friday. Found by review on 2026-08-30.
 *
 * A guard that names one file cannot notice a second copy. This one is derived
 * from the sources rather than hardcoded, so a third copy is covered on the
 * day it appears.
 */
const CLEANUP_SOURCES = ["notification-service.ts", "weekly-digest.ts"]
  .map((f) => ({
    file: f,
    src: readFileSync(resolve(__dirname, "..", "src", f), "utf8"),
  }));

describe("stale FCM tokens are actually removed", () => {
  for (const {file, src} of CLEANUP_SOURCES) {
    test(`${file}: arrayRemove is called with SPREAD varargs`, () => {
      const calls = [...src.matchAll(/arrayRemove\(([^)]*)\)/g)];
      assert.notEqual(calls.length, 0,
        `arrayRemove is gone from ${file} — if stale-token cleanup moved, ` +
        "this test must follow it");

      // EVERY call, not just the first: a second, broken one appended to an
      // already-guarded file used to sail through.
      for (const call of calls) {
        assert.match(call[1], /^\.\.\./,
          "arrayRemove takes varargs. Passing the array itself throws " +
          "'Nested arrays are not supported', which is what made stale-token " +
          "pruning fail loudly on every run and prune nothing.");
      }
    });

    test(`${file}: the argument is the stale token list`, () => {
      const calls = [...src.matchAll(/arrayRemove\(([^)]*)\)/g)];
      for (const call of calls) {
        assert.match(call[1], /staleTokens/,
          "spreading the wrong variable would compile and remove the wrong " +
          "tokens, which is worse than removing none");
      }
    });
  }

  // The gap that let the second copy survive: nothing checked that the list
  // above covers every file which prunes tokens.
  test("no OTHER source file prunes tokens unguarded", () => {
    const dir = resolve(__dirname, "..", "src");
    const guarded = new Set(CLEANUP_SOURCES.map((c) => c.file));
    // RECURSIVE, and matching EVERY call rather than the first.
    //
    // The Phase 8 re-review defeated this assertion two ways: a pruner in a
    // subdirectory was invisible to a flat `readdirSync`, and a second broken
    // `arrayRemove` appended to an already-guarded file was invisible to
    // `.exec()`, which returns only the first match. `functions/src/` is flat
    // today with one call per file, so neither was live — but the comment
    // above claimed a third copy would be "covered on the day it appears",
    // and it would not have been.
    const offenders = readdirSync(dir, {recursive: true})
      .map(String)
      .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts"))
      .filter((f) => !guarded.has(f))
      .filter((f) => readFileSync(resolve(dir, f), "utf8").includes(
        "arrayRemove"));

    assert.deepEqual(offenders, [],
      "these files prune tokens but are not covered by this guard: " +
      `${offenders.join(", ")}. Add them to CLEANUP_SOURCES.`);
  });
});
