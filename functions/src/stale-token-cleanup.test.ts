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
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

const SOURCE = readFileSync(
  resolve(__dirname, "..", "src", "notification-service.ts"), "utf8");

describe("stale FCM tokens are actually removed", () => {
  test("arrayRemove is called with SPREAD varargs, not the array", () => {
    const call = /arrayRemove\(([^)]*)\)/.exec(SOURCE);
    assert.notEqual(call, null,
      "arrayRemove is gone from notification-service.ts — if stale-token " +
      "cleanup moved, this test must follow it");

    assert.match(call![1], /^\.\.\./,
      "arrayRemove takes varargs. Passing the array itself throws " +
      "'Nested arrays are not supported', which is what made stale-token " +
      "pruning a no-op that failed loudly on every cycle and pruned nothing.");
  });

  test("the argument is the stale token list", () => {
    const call = /arrayRemove\(([^)]*)\)/.exec(SOURCE);
    assert.match(call![1], /staleTokens/,
      "spreading the wrong variable would compile and remove the wrong " +
      "tokens, which is worse than removing none");
  });
});
