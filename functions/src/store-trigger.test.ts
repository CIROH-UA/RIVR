// functions/src/store-trigger.test.ts
//
// ADR 0011 Phase 4. Guard 1 — "no new run -> ZERO fetches beyond the probe" —
// is decided here. Everything downstream is correct only if this refuses to
// trigger when upstream has not moved.
//
// The failure mode worth stating: the probe deliberately does not retry, so a
// null referenceTime means that endpoint genuinely failed this hour. Treating
// null as "something changed" would turn every upstream outage into a full
// fan-out across every reach — the exact cost this phase removes.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  FREE_TIER_WRITES_PER_DAY,
  HEARTBEAT_STALE_MS,
  PROBE_STALE_MS,
  ProbeRuns,
  assessStoreHealth,
  decideTriggers,
  quotaUsage,
} from "./store-trigger.js";
import {ForecastProductId} from "./store-keys.js";

const MANAGED: ForecastProductId[] =
  ["analysisAssimilation", "shortRange", "mediumRange", "longRange"];

const NOW = new Date("2026-08-24T12:00:00.000Z");

function probe(referenceTimes: Record<string, string | null>): ProbeRuns {
  return {referenceTimes, sampledAt: NOW};
}

describe("guard 1 — trigger only on a real advance", () => {
  test("an unchanged run does not trigger", () => {
    const d = decideTriggers(
      probe({shortRange: "2026-08-24T11:00:00Z"}),
      {shortRange: "2026-08-24T11:00:00Z"},
      ["shortRange"]);

    assert.deepEqual(d.triggered, []);
    assert.match(d.reasons.shortRange, /unchanged/);
  });

  test("a newer upstream run triggers", () => {
    const d = decideTriggers(
      probe({shortRange: "2026-08-24T12:00:00Z"}),
      {shortRange: "2026-08-24T11:00:00Z"},
      ["shortRange"]);
    assert.deepEqual(d.triggered, ["shortRange"]);
  });

  test("an empty store triggers", () => {
    const d = decideTriggers(
      probe({shortRange: "2026-08-24T12:00:00Z"}), {}, ["shortRange"]);
    assert.deepEqual(d.triggered, ["shortRange"]);
  });

  // The expensive mistake: a failed probe endpoint must not read as new data.
  test("a probe reporting NO run does not trigger", () => {
    const d = decideTriggers(
      probe({shortRange: null}),
      {shortRange: "2026-08-24T11:00:00Z"},
      ["shortRange"]);

    assert.deepEqual(d.triggered, [],
      "treating a failed probe endpoint as an advance would fan out across " +
      "every reach on every upstream outage");
    assert.match(d.reasons.shortRange, /no run this hour/);
  });

  test("an OLDER upstream run does not trigger", () => {
    const d = decideTriggers(
      probe({shortRange: "2026-08-24T06:00:00Z"}),
      {shortRange: "2026-08-24T12:00:00Z"},
      ["shortRange"]);
    assert.deepEqual(d.triggered, []);
  });

  test("products are decided independently of each other", () => {
    const d = decideTriggers(
      probe({
        analysisAssimilation: "2026-08-24T12:00:00Z",
        shortRange: "2026-08-24T12:00:00Z",
        mediumRange: "2026-08-24T06:00:00Z",
        longRange: null,
      }),
      {
        analysisAssimilation: "2026-08-24T11:00:00Z",
        shortRange: "2026-08-24T12:00:00Z",
        mediumRange: "2026-08-24T00:00:00Z",
        longRange: "2026-08-24T00:00:00Z",
      },
      MANAGED);

    assert.deepEqual(d.triggered.sort(),
      ["analysisAssimilation", "mediumRange"]);
  });

  test("every candidate gets a recorded reason, triggered or not", () => {
    const d = decideTriggers(probe({}), {}, MANAGED);
    assert.deepEqual(Object.keys(d.reasons).sort(), [...MANAGED].sort(),
      "a product with no recorded reason is a silent decision");
  });
});

describe("the heartbeat can actually say the store is broken", () => {
  test("a recent write and a recent probe are healthy", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 3600_000),
      new Date(NOW.getTime() - 600_000),
      NOW);
    assert.equal(h.status, "healthy");
    assert.deepEqual(h.problems, []);
  });

  // The failure the ADR says is otherwise invisible: a run that keeps exiting
  // 0 while writing nothing looks exactly like a quiet upstream.
  test("no write for longer than a publish cycle is not healthy", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - HEARTBEAT_STALE_MS - 1),
      new Date(NOW.getTime() - 600_000),
      NOW);
    assert.notEqual(h.status, "healthy");
    assert.match(h.problems.join(" "), /no successful write/);
  });

  test("a stalled probe is a problem even when writes look recent", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - PROBE_STALE_MS - 1),
      NOW);
    assert.notEqual(h.status, "healthy",
      "without a live probe the store cannot know upstream advanced, so it " +
      "would sit still and look fine while going stale");
  });

  test("an empty store with no probe is down, not healthy", () => {
    const h = assessStoreHealth(null, null, NOW);
    assert.equal(h.status, "down");
    assert.equal(h.problems.length, 2);
  });

  test("every problem is reported, not just the first", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - HEARTBEAT_STALE_MS - 1),
      new Date(NOW.getTime() - PROBE_STALE_MS - 1),
      NOW);
    assert.equal(h.problems.length, 2);
    assert.equal(h.status, "down");
  });
});

describe("guard 11 — usage against the documented free tier", () => {
  test("usage is expressed as a share of the daily allowance", () => {
    const q = quotaUsage(500, 200);
    assert.equal(q.reads, 500);
    assert.equal(q.writes, 200);
    assert.equal(q.writesPctOfFree, (200 / FREE_TIER_WRITES_PER_DAY) * 100);
  });

  test("a realistic run sits far under the allowance", () => {
    // 29 distinct reaches x 4 products, plus the reads to decide.
    const q = quotaUsage(150, 116);
    assert.ok(q.writesPctOfFree < 1,
      `expected well under 1% of the write allowance, got ${q.writesPctOfFree}`);
  });
});
