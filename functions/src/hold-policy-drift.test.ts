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

import {ForecastProductId} from "./store-keys.js";
import {SERIES_BY_PRODUCT} from "./store-upstream.js";
import {
  MAX_HOLD_MS,
  DEFAULT_MAX_HOLD_MS,
  ISLAND_MAX_HOLD_MS,
  ISLAND_MAX_RUN_AGE_MS,
  MAX_RUN_AGE_MS,
  maxHoldMs,
  maxRunAgeMs,
} from "./store-window.js";

const REPO = resolve(__dirname, "..", "..") + "/";
const CONUS = "23021904";
const ISLAND = "800000010";
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
 * Handles line comments only. A BLOCK comment containing a whole earlier copy
 * of a map declaration, placed ABOVE the live one, would still be the block
 * parsed, since the block regex takes the first match — a false pass. Left as
 * a note rather than code: line comments are the Dart convention, every other
 * block-comment shape fails safe (a commented entry INSIDE the map is caught
 * by the last-match-wins entry scan and fails the test), and the line-comment
 * case is the one that actually happened.
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

/** The client's island hold caps. */
function dartIslandHolds(): Record<string, number> {
  return dartMap("islandMaxHold");
}

/** The client's island run-age caps. */
function dartIslandRunAges(): Record<string, number> {
  return dartMap("islandMaxRunAge");
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

describe("guard 4 — the island caps are shared too", () => {
  // Phase 9 added a SECOND pair of tables, for Hawaii and Puerto Rico, whose
  // short range publishes 6- or 12-hourly against CONUS's hourly. Everything
  // the block above argues applies to them identically: a client that holds
  // longer than the server keeps showing water the server has given up on.
  //
  // Written at the same time as the tables themselves rather than after,
  // because the pattern this ADR keeps rediscovering is that the cross-
  // language claim is made in a comment first and pinned much later, if ever.
  test("every server island hold cap has an identical client cap", () => {
    const dart = dartIslandHolds();
    for (const [product, ms] of Object.entries(ISLAND_MAX_HOLD_MS)) {
      assert.equal(dart[product], ms,
        `${product}: island hold caps disagree — server ${ms / 3600_000}h, ` +
        `client ${(dart[product] ?? NaN) / 3600_000}h`);
    }
  });

  test("every server island run-age cap has an identical client cap", () => {
    const dart = dartIslandRunAges();
    for (const [product, ms] of Object.entries(ISLAND_MAX_RUN_AGE_MS)) {
      assert.equal(dart[product], ms,
        `${product}: island run-age caps disagree — server ` +
        `${ms / 3600_000}h, client ${(dart[product] ?? NaN) / 3600_000}h`);
    }
  });

  test("the client adds no island cap the server does not know", () => {
    for (const product of Object.keys(dartIslandHolds())) {
      assert.ok(product in ISLAND_MAX_HOLD_MS,
        `${product} has a client island hold cap with no server counterpart`);
    }
    for (const product of Object.keys(dartIslandRunAges())) {
      assert.ok(product in ISLAND_MAX_RUN_AGE_MS,
        `${product} has a client island run-age cap with no counterpart`);
    }
  });

  test("the island tables cannot reach a GEOGLOWS document", () => {
    // A near-miss found while verifying the deploy on 2026-08-30. GEOGLOWS
    // river ids are also 9 digits, and nothing stops one landing inside the
    // NWM island COMID band — `isIslandReach` reads the number, not the
    // network. None of the reaches in the store today collide, but that is
    // luck, not design.
    //
    // What actually makes it safe is that the island tables name ONLY
    // `shortRange`, which GEOGLOWS does not have. That is an implicit
    // coupling, and implicit couplings in this ADR have a record of being
    // broken by an edit that looked obviously correct. Adding
    // `geoglowsForecast` to either table would silently give an island-band
    // GEOGLOWS reach the wrong cap; this fails first.
    for (const table of [ISLAND_MAX_HOLD_MS, ISLAND_MAX_RUN_AGE_MS]) {
      for (const product of Object.keys(table)) {
        assert.ok(!product.startsWith("geoglows"),
          `${product} is a GEOGLOWS product with an NWM island cap. The ` +
          "island band is an NHDPlus COMID range and says nothing about a " +
          "GEOGLOWS river id that happens to fall inside it.");
      }
    }
  });

  test("products fetching the SAME series have the same caps", () => {
    // The defect this pins, introduced and found on 2026-08-30.
    // `currentFlow` does not fetch analysis assimilation:
    // `store-upstream.ts` maps it to `"short_range"`. It was nonetheless given
    // its own publish schedule and left out of the island cap tables, on a
    // correct argument about the product its NAME describes.
    //
    // Derived from the fetch map rather than hardcoded, so the day someone
    // renames the product or repoints it at a different series, this follows.
    const bySeries = new Map<string, ForecastProductId[]>();
    for (const [product, series] of Object.entries(SERIES_BY_PRODUCT)) {
      if (!series) continue;
      bySeries.set(series,
        [...(bySeries.get(series) ?? []), product as ForecastProductId]);
    }
    for (const [series, products] of bySeries) {
      if (products.length < 2) continue;
      const [first, ...rest] = products;
      for (const other of rest) {
        assert.equal(maxHoldMs(other, CONUS), maxHoldMs(first, CONUS),
          `${first} and ${other} both fetch "${series}" but hold differently`);
        assert.equal(maxHoldMs(other, ISLAND), maxHoldMs(first, ISLAND),
          `${first} and ${other} both fetch "${series}" but hold differently ` +
          "on island reaches — the exact hole the misnamed product fell " +
          "through");
        assert.equal(maxRunAgeMs(other, ISLAND), maxRunAgeMs(first, ISLAND),
          `${first} and ${other} both fetch "${series}" but judge run age ` +
          "differently on island reaches");
      }
    }
  });

  test("an island override is never STRICTER than the CONUS cap", () => {
    // The direction check, not just equality. An island override tighter than
    // the shared cap would be pointless at best and, for the run-age table,
    // would alarm on data that is normal for the domain — which is the exact
    // failure that motivated these tables. Stated as a property so a future
    // edit that flips one number is caught for the right reason.
    for (const [product, ms] of Object.entries(ISLAND_MAX_HOLD_MS)) {
      assert.ok(ms > (MAX_HOLD_MS[product] ?? DEFAULT_MAX_HOLD_MS),
        `${product}: island reaches publish more SLOWLY than CONUS, so a ` +
        "tighter island cap cannot be right");
    }
    for (const [product, ms] of Object.entries(ISLAND_MAX_RUN_AGE_MS)) {
      const conus = MAX_RUN_AGE_MS[product];
      if (conus === undefined) continue;
      assert.ok(ms > conus, `${product}: same argument for run age`);
    }
  });
});
