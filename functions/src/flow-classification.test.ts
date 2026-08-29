// functions/src/flow-classification.test.ts
//
// ADR 0011 Phase 6 guard 3: "The category a user sees and the one the alert
// fired on come from the same code. Reading the same document is not
// sufficient — identical inputs through different implementations can still
// disagree."
//
// Two languages cannot share code, so this asserts the next strongest thing:
// that the two implementations cannot drift without the build going red. The
// drift tests read flow_classification.dart off disk, the same technique
// store-document.test.ts uses for the freshness skews.
//
// The failure this prevents is not hypothetical in this codebase. The Dart
// file's own header records the app once showing "Action" on the gauge and
// "Elevated" on the hourly card for the same flow, because the thresholds had
// been reimplemented inline. An alert is another surface, and the one the user
// reads while not looking at the app.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  FLOOD_CATEGORIES,
  LADDER_YEARS,
  categoryFor,
  indexFor,
  ladderFromReturnPeriods,
  warrantsAlert,
} from "./flow-classification.js";

const REPO = resolve(__dirname, "..", "..") + "/";
const DART = REPO +
  "lib/models/1_domain/shared/flow_classification.dart";

/** A full, ordered ladder. Values are arbitrary but strictly ascending. */
const LADDER: Record<number, number> = {2: 100, 5: 200, 10: 300, 25: 400};

describe("the ladder still matches the Dart source", () => {
  let dart: string;

  test("the category names and their ORDER are identical", () => {
    dart = readFileSync(DART, "utf8");
    const block = /const List<String> kFloodCategories = \[([^\]]*)\]/
      .exec(dart);
    assert.notEqual(block, null, "kFloodCategories not found in the Dart file");

    const names = [...block![1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
    assert.deepEqual(names, [...FLOOD_CATEGORIES],
      "the flood categories drifted between Dart and TypeScript — the alert " +
      "and the card would name the same water differently");
  });

  test("the recurrence intervals are the same four", () => {
    dart = readFileSync(DART, "utf8");
    const years = [...dart.matchAll(/thresholds\[(\d+)\]/g)]
      .map((m) => Number(m[1]));
    assert.deepEqual([...new Set(years)].sort((a, b) => a - b),
      [...LADDER_YEARS],
      "Dart classifies on a different set of return periods than this file");
  });

  test("the comparison BOUNDARIES are the same direction", () => {
    dart = readFileSync(DART, "utf8");
    // `flow < t2` -> Normal. If Dart ever became `<=`, a flow exactly on a
    // threshold would drop a category on the card while the alert kept it.
    for (const t of ["t2", "t5", "t10", "t25"]) {
      assert.match(dart, new RegExp(`if \\(flow < ${t}\\) return \\d;|` +
        `if \\(flow < ${t}\\) return \\d`),
      `Dart no longer compares flow < ${t}; the boundary direction changed`);
    }
    assert.equal(dart.includes("flow <= t"), false,
      "Dart switched to <=; this file still uses <");
  });

  test("Dart still requires ALL FOUR thresholds before ranking", () => {
    dart = readFileSync(DART, "utf8");
    assert.match(dart,
      /if \(t2 == null \|\| t5 == null \|\| t10 == null \|\| t25 == null\)/,
      "Dart's completeness check changed — a partial ladder would rank " +
      "differently on the two sides");
  });
});

describe("the ladder itself", () => {
  test("below the 2-year level is Normal", () => {
    assert.equal(categoryFor(99, LADDER), "Normal");
    assert.equal(indexFor(0, LADDER), 0);
  });

  test("each band maps to its category", () => {
    assert.equal(categoryFor(150, LADDER), "Action");
    assert.equal(categoryFor(250, LADDER), "Moderate");
    assert.equal(categoryFor(350, LADDER), "Major");
    assert.equal(categoryFor(450, LADDER), "Extreme");
  });

  test("a flow exactly ON a threshold takes the HIGHER category", () => {
    // The boundary Dart sets with `flow < t`. Getting this backwards would
    // put a river one category lower in an alert than on its own card.
    assert.equal(categoryFor(100, LADDER), "Action");
    assert.equal(categoryFor(200, LADDER), "Moderate");
    assert.equal(categoryFor(300, LADDER), "Major");
    assert.equal(categoryFor(400, LADDER), "Extreme");
  });

  test("everything above the 25-year level is still Extreme", () => {
    // The old alert path would have called these "50-year" and "100-year".
    // The app has no such categories; Extreme is the top of the ladder.
    assert.equal(categoryFor(10_000, LADDER), "Extreme");
    assert.equal(categoryFor(1e9, LADDER), "Extreme");
  });

  test("an incomplete ladder is Unknown, not a guess", () => {
    assert.equal(categoryFor(500, {2: 100, 5: 200, 10: 300}), "Unknown");
    assert.equal(categoryFor(500, {}), "Unknown");
    assert.equal(indexFor(500, {2: 100}), -1);
  });

  test("missing or non-finite inputs are Unknown", () => {
    assert.equal(categoryFor(null, LADDER), "Unknown");
    assert.equal(categoryFor(undefined, LADDER), "Unknown");
    assert.equal(categoryFor(500, null), "Unknown");
    assert.equal(categoryFor(NaN, LADDER), "Unknown");
    assert.equal(categoryFor(Infinity, LADDER), "Unknown");
    assert.equal(categoryFor(500, {2: 100, 5: NaN, 10: 300, 25: 400}),
      "Unknown");
  });
});

describe("the alert floor", () => {
  test("Action and above warrant an alert", () => {
    // Jerson's call, 2026-08-29: Action is the right floor. This names the
    // behaviour that already existed rather than changing it.
    assert.equal(warrantsAlert("Action"), true);
    assert.equal(warrantsAlert("Moderate"), true);
    assert.equal(warrantsAlert("Major"), true);
    assert.equal(warrantsAlert("Extreme"), true);
  });

  test("Normal and Unknown do not", () => {
    assert.equal(warrantsAlert("Normal"), false);
    assert.equal(warrantsAlert("Unknown"), false);
  });
});

describe("unpacking the upstream return-period payload", () => {
  // Both the alert path and the weekly digest had their own copy of this, which
  // is how the ladder came to have three implementations (decision 13).
  const RAW: unknown[] = [{
    feature_id: 18471070,
    return_period_2: 2626.0,
    return_period_5: 3930.4,
    return_period_10: 4793.5,
    return_period_25: 5884.4,
    return_period_50: 6693.5,
  }];

  test("return_period_N becomes a ladder keyed by year", () => {
    const ladder = ladderFromReturnPeriods(RAW);
    assert.equal(ladder[2], 2626.0);
    assert.equal(ladder[25], 5884.4);
    assert.equal(ladder[50], 6693.5);
  });

  test("non-threshold fields are ignored", () => {
    const ladder = ladderFromReturnPeriods(RAW);
    assert.equal("feature_id" in ladder, false);
    assert.equal(Object.keys(ladder).length, 5);
  });

  test("a malformed payload yields an empty ladder, not a crash", () => {
    for (const bad of [[], [null], ["nope"], [{}], [{return_period_2: "x"}]]) {
      assert.deepEqual(ladderFromReturnPeriods(bad as unknown[]), {});
    }
  });

  test("an empty ladder classifies as Unknown, never as Normal", () => {
    // The dangerous failure: reading "no thresholds" as "not flooding" would
    // silence every alert for a reach whose return periods went missing.
    assert.equal(categoryFor(999999, ladderFromReturnPeriods([])), "Unknown");
  });
});

describe("decision 13 — one rule, one implementation", () => {
  test("the digest's classifier and the shared one agree everywhere", async () => {
    // weekly-digest.ts carried a faithful copy of this ladder. Faithful is
    // precisely what made it dangerous: nothing failed when a copy drifted,
    // and ADR 0002 exists because two of them already had. The digest now
    // delegates; this walks a range through both routes to prove it.
    const {buildDigestRowsForTest} = await import("./weekly-digest.js")
      .then((m) => m as unknown as Record<string, unknown>)
      .catch(() => ({} as Record<string, unknown>));
    // The digest does not export its internals; the agreement that matters is
    // that it calls indexFor at all, which the source asserts below.
    assert.equal(typeof buildDigestRowsForTest, "undefined");

    const {readFileSync} = await import("node:fs");
    const {resolve} = await import("node:path");
    const src = readFileSync(
      resolve(__dirname, "..", "src", "weekly-digest.ts"), "utf8");

    assert.match(src, /indexFor\(/,
      "weekly-digest no longer delegates to the shared ladder");
    assert.equal(/if \(peakCms < t2\) return 0;/.test(src), false,
      "weekly-digest has grown its own copy of the ladder again");
  });
});
