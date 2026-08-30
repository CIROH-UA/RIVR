// functions/src/hold-policy-drift.test.ts
//
// ADR 0011 Phase 7 guard 4: "the indicator is driven by the same signal that
// alarms operationally."
//
// This test is what makes that sentence TRUE rather than asserted. The first
// version of Phase 7 claimed the client and the server shared a threshold
// while `MAX_HOLD_MS` existed only in TypeScript — the only occurrence of the
// name anywhere in `lib/` was the comment saying it was shared. An independent
// review found it, and the lesson is that a claim of agreement between two
// languages is worth nothing without something that fails when they diverge.
//
// So: the client's `maxHold` (lib/services/4_infrastructure/river_data/
// hold_policy.dart) and the server's `MAX_HOLD_MS` must name the same products
// and the same durations. Change one alone and this fails, the same way the
// flood-category ladder is pinned across the two languages.
//
// Why the number matters on both sides: past this cap the SERVER stops
// extending a document's window and lets it expire, and the CLIENT stops
// vouching for a value it is still holding. If the client's number were
// larger it would keep showing water the server had already given up on,
// silently — which is precisely the guard-3 scenario.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  MAX_HOLD_MS,
  DEFAULT_MAX_HOLD_MS,
  MAX_RUN_AGE_MS,
} from "./store-window.js";

const REPO = resolve(__dirname, "..", "..") + "/";
const DART = REPO +
  "lib/services/4_infrastructure/river_data/hold_policy.dart";

/** Dart `Duration(...)` literal to milliseconds. */
function durationMs(literal: string): number {
  const hours = /hours:\s*(\d+)/.exec(literal);
  const days = /days:\s*(\d+)/.exec(literal);
  const minutes = /minutes:\s*(\d+)/.exec(literal);
  let ms = 0;
  if (days) ms += Number(days[1]) * 24 * 3600_000;
  if (hours) ms += Number(hours[1]) * 3600_000;
  if (minutes) ms += Number(minutes[1]) * 60_000;
  assert.notEqual(ms, 0, `unparsed Duration literal: ${literal}`);
  return ms;
}

/**
 * Strip `//` comments before matching.
 *
 * Without this the test passed while the two sides disagreed, in the
 * dangerous direction — found by mutation during the Phase 7 re-review. The
 * entry regex is global and last-match-wins, so an ordinary edit like
 *
 *     ForecastProduct.shortRange: Duration(hours: 24),
 *     // was ForecastProduct.shortRange: Duration(hours: 6), before 2026-08-30
 *
 * left the client on 24 h, the server on 6 h, and all four assertions green.
 * Recording a superseded value in a trailing comment is a normal thing to do,
 * which is what made it dangerous rather than contrived.
 *
 * @param {string} src - Dart source.
 * @return {string} The same source with line comments removed.
 */
function stripComments(src: string): string {
  return src.replace(/^\s*\/\/.*$/gm, "").replace(/\/\/.*$/gm, "");
}

/**
 * One of the client's duration maps, read out of the Dart source.
 *
 * @param {string} name - The Dart constant's name.
 * @return {Record<string, number>} Product to milliseconds.
 */
function dartMap(name: string): Record<string, number> {
  const dart = stripComments(readFileSync(DART, "utf8"));
  const block = new RegExp(
    `const Map<ForecastProduct, Duration> ${name} = \\{([\\s\\S]*?)\\};`
  ).exec(dart);
  assert.notEqual(block, null,
    `hold_policy.dart no longer declares \`${name}\` — if it moved, this ` +
    "test must follow it, because without it guard 4 is back to being a claim");

  const out: Record<string, number> = {};
  const entry = /ForecastProduct\.(\w+):\s*(Duration\([^)]*\))/g;
  let m: RegExpExecArray | null;
  while ((m = entry.exec(block![1])) !== null) {
    out[m[1]] = durationMs(m[2]);
  }
  assert.ok(Object.keys(out).length > 0, `no entries parsed from ${name}`);
  return out;
}

/** The client's hold caps. */
function dartHolds(): Record<string, number> {
  return dartMap("maxHold");
}

/** The client's run-age caps. */
function dartRunAges(): Record<string, number> {
  return dartMap("maxRunAge");
}

describe("guard 4 — the client and the server hold for the same time", () => {
  // The test's own failure mode, pinned. A commented-out entry must not be
  // able to speak for the live one, in either position.
  test("a commented-out entry cannot override the real one", () => {
    const withTrailingComment = stripComments(
      "ForecastProduct.shortRange: Duration(hours: 6),\n" +
      "// was ForecastProduct.shortRange: Duration(hours: 24), before today\n");
    assert.ok(!withTrailingComment.includes("hours: 24"),
      "a superseded value left in a comment used to win the last-match scan");

    const withLeadingComment = stripComments(
      "// ForecastProduct.shortRange: Duration(hours: 99),\n" +
      "ForecastProduct.shortRange: Duration(hours: 6),\n");
    assert.ok(!withLeadingComment.includes("hours: 99"));
  });

  test("every server cap has an identical client cap", () => {
    const dart = dartHolds();

    for (const [product, ms] of Object.entries(MAX_HOLD_MS)) {
      assert.equal(dart[product], ms,
        `${product}: the server holds for ${ms / 3600_000}h but the client ` +
        `holds for ${(dart[product] ?? NaN) / 3600_000}h. A client that ` +
        "holds LONGER keeps showing water the server has already given up " +
        "on, with no indicator — the exact scenario guard 3 names.");
    }
  });

  test("the client adds no product the server does not know", () => {
    const dart = dartHolds();

    for (const product of Object.keys(dart)) {
      assert.ok(product in MAX_HOLD_MS,
        `${product} has a client hold cap with no server counterpart. One ` +
        "side deciding a product's cadence alone is how these two drift.");
    }
  });

  test("the fallbacks agree too", () => {
    const dart = stripComments(readFileSync(DART, "utf8"));
    const fallback =
      /const Duration defaultMaxHold = (Duration\([^)]*\));/.exec(dart);
    assert.notEqual(fallback, null, "defaultMaxHold is gone from the client");

    assert.equal(durationMs(fallback![1]), DEFAULT_MAX_HOLD_MS,
      "an unnamed product must fail towards 'check again' on both sides, " +
      "and by the same margin");
  });

  test("the near-static products are named on the client too", () => {
    // The specific regression this pins. On the server these two had no entry
    // and inherited the 6-hour default meant for hourly forecasts, which
    // reported a healthy store as DOWN within a minute of reaching
    // production. They hold a 30-day window; the client must not repeat it.
    const dart = dartHolds();
    for (const product of ["reachMetadata", "returnPeriods"]) {
      assert.ok(dart[product] > 30 * 24 * 3600_000,
        `${product} holds a 30-day window; a shorter client cap makes the ` +
        "app disown a value that is completely current");
    }
  });
});

describe("guard 4 — the client judges RUN AGE by the server's numbers too",
  () => {
    // Closing guard 4 properly. Sharing MAX_HOLD_MS made the two sides agree
    // about how long ago we WROTE; it left them disagreeing about how old the
    // WATER is, which is the dimension that catches the 2026-08-29 GEOGLOWS
    // incident. Until this existed the server alarmed and the phone showed
    // nothing at all — the document looked freshly written and in-window,
    // because it was.
    test("every server run-age cap has an identical client cap", () => {
      const dart = dartRunAges();

      for (const [product, ms] of Object.entries(MAX_RUN_AGE_MS)) {
        assert.equal(dart[product], ms,
          `${product}: the server alarms at ${ms / 3600_000}h of run age but ` +
          `the client waits ${(dart[product] ?? NaN) / 3600_000}h. A client ` +
          "that waits LONGER shows yesterday's water with no warning while " +
          "the operational alarm is already firing.");
      }
    });

    test("the client adds no run-age cap the server does not know", () => {
      const dart = dartRunAges();

      for (const product of Object.keys(dart)) {
        assert.ok(product in MAX_RUN_AGE_MS,
          `${product} has a client run-age cap with no server counterpart`);
      }
    });

    test("the near-static products are judged by NEITHER side", () => {
      // They carry no run identity at all. A default here is how the hold cap
      // reported a healthy store as down within a minute of going live.
      const dart = dartRunAges();
      for (const product of ["reachMetadata", "returnPeriods"]) {
        assert.ok(!(product in dart),
          `${product} has a run-age cap but carries no run identity`);
        assert.ok(!(product in MAX_RUN_AGE_MS));
      }
    });
  });
