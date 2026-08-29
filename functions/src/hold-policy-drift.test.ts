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

import {MAX_HOLD_MS, DEFAULT_MAX_HOLD_MS} from "./store-window.js";

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

/** The client's map, read out of the Dart source. */
function dartHolds(): Record<string, number> {
  const dart = readFileSync(DART, "utf8");
  const block = /const Map<ForecastProduct, Duration> maxHold = \{([\s\S]*?)\};/
    .exec(dart);
  assert.notEqual(block, null,
    "hold_policy.dart no longer declares `maxHold` — if it moved, this test " +
    "must follow it, because without it guard 4 is back to being a claim");

  const out: Record<string, number> = {};
  const entry = /ForecastProduct\.(\w+):\s*(Duration\([^)]*\))/g;
  let m: RegExpExecArray | null;
  while ((m = entry.exec(block![1])) !== null) {
    out[m[1]] = durationMs(m[2]);
  }
  assert.ok(Object.keys(out).length > 0, "no entries parsed from maxHold");
  return out;
}

describe("guard 4 — the client and the server hold for the same time", () => {
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
    const dart = readFileSync(DART, "utf8");
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
