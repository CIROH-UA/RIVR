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

describe("an APNs credential failure is not a stale token", () => {
  // Measured 2026-08-30: 103 send failures in seven days, all
  // `messaging/third-party-auth-error`, all from ONE user. That is a build
  // installed from Xcode — it registers against Apple's SANDBOX push
  // environment, and this project has a Production APNs key and no
  // development one, so every send to it fails forever.
  //
  // Two things must both stay true, and they pull in opposite directions.
  //
  // Source-level guards, and they say so: exercising the real behaviour needs
  // the FCM SDK, which this suite does not run. What they pin is the branch
  // structure, which is what would actually be got wrong.
  const src = readFileSync(
    resolve(__dirname, "..", "src", "notification-service.ts"), "utf8");

  test("it is NEVER added to the prune list", () => {
    // The dangerous "fix" for the noise. This error means our credential does
    // not cover the token's environment — the token itself is fine. If the
    // PRODUCTION key were ever misconfigured, this same code fires for every
    // user at once, and pruning on it would erase every push token in the
    // system in a single run. An auto-remediation that can delete all user
    // state on a config mistake is worse than the noise it removes.
    const branch =
      /messaging\/third-party-auth-error[\s\S]{0,3000}?\n {6}\} else \{/
        .exec(src);
    assert.notEqual(branch, null,
      "the third-party-auth-error branch is gone; if the handling moved, " +
      "this guard must follow it");
    assert.ok(!/staleTokens\.push/.test(branch![0]),
      "third-party-auth-error must not prune: it reports OUR credential " +
      "being wrong, not the token being dead, and on a production key " +
      "mistake it fires for everybody at once");
  });

  test("the stale-token list still names only genuine token errors", () => {
    const list = /errorCode === "messaging\/registration-token-not-registered"[\s\S]{0,400}?\)/
      .exec(src);
    assert.notEqual(list, null);
    assert.ok(!list![0].includes("third-party-auth"),
      "adding it to the prune condition is the same defect by another route");
  });

  test("MANY users failing the same way is still raised loudly", () => {
    // The other direction, which matters more than the silence. Quieting the
    // per-send log must not quiet the case it can hide: the production APNs
    // key broken for everyone, which silently kills every notification the
    // app sends. One user is a debug build; two is an outage.
    //
    // **Honest note on strength.** Deleting the ERROR block outright is
    // caught by `tsc`, not by this test — `APNS_OUTAGE_THRESHOLD` becomes an
    // unused constant and `npm test` builds before it runs, so the suite
    // never executes. A mutation that does not compile proves nothing about
    // the assertion. What this DOES catch is the block being kept and
    // weakened: the threshold raised out of reach, or `logger.error`
    // downgraded to a warn, both of which compile cleanly and are the
    // realistic ways this protection would rot.
    assert.match(src, /APNS_OUTAGE_THRESHOLD = 2/,
      "the per-run threshold is what separates a debug build from an outage");
    assert.match(src, /apnsCredentialFailures\.size >= APNS_OUTAGE_THRESHOLD[\s\S]{0,200}?logger\.error/,
      "crossing the threshold must log at ERROR, or downgrading the " +
      "per-send line just deletes the signal");
  });

  test("the per-run accumulator is CLEARED at the start of a run", () => {
    // Cloud Functions instances are reused, so module state survives between
    // invocations. Without the clear, one debug build's failure accumulates
    // and the second warm run reports a fake outage — which would train
    // exactly the dismissal this whole change is removing.
    assert.match(src, /apnsCredentialFailures\.clear\(\)/,
      "a warm instance would otherwise carry failures between runs");
  });
});
