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
  oldestLiveRun,
  RunSample,
  FREE_TIER_WRITES_PER_DAY,
  HEARTBEAT_STALE_MS,
  PROBE_STALE_MS,
  ProbeRuns,
  assessStoreHealth,
  assessProductFreshness,
  decideTriggers,
  probeRunFor,
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

describe("per-product freshness — the hole the heartbeat had", () => {
  /**
   * Build a stored-document sample.
   * @param {string} product - Product id.
   * @param {number} ageHours - How long ago it was fetched.
   * @param {string} id - Document id.
   * @return {object} A StoredWindowSample.
   */
  function sample(product: string, ageHours: number, id = "d") {
    return {
      documentId: `${product}__${id}`,
      source: "nwm",
      product,
      fetchedAt: new Date(NOW.getTime() - ageHours * 3600_000).toISOString(),
      validUntil: NOW.toISOString(),
    };
  }

  // The failure a per-collection heartbeat structurally cannot see: one
  // product stops being WRITTEN while another product's writes keep the
  // aggregate fresh.
  //
  // Note what this is NOT. An earlier version of this comment called it "the
  // regression this whole change exists for, measured in production", meaning
  // the 2026-08-29 GEOGLOWS incident. That was wrong: in that incident the
  // 01:30 job wrote punctually every day carrying a run one day old, so
  // `fetchedAt` never aged past ~24 h and this check would have said healthy
  // too. Catching that one needs run currency, not write recency. This test
  // models a genuinely stalled writer — 50 h against a 48 h cap — which is a
  // real failure and a real gap in the old check, just not that one.
  test("a stalled GEOGLOWS is caught even though NWM keeps writing", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000), // a fresh write exists
      new Date(NOW.getTime() - 600_000), // probe is live
      NOW,
      [
        sample("shortRange", 0.5),
        sample("geoglowsForecast", 50), // cap is 48h
      ] as never);

    assert.notEqual(h.status, "healthy",
      "one product stalled while the aggregate looked fresh — this is the " +
      "exact failure that ran undetected in production for days");
    assert.match(h.problems.join(" "), /geoglowsForecast/);
  });

  test("the threshold is the product's own hold cap, not one number", () => {
    // 20h is stale for shortRange (6h) and fine for geoglowsForecast (48h).
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [sample("shortRange", 20), sample("geoglowsForecast", 20)] as never);

    const joined = h.problems.join(" ");
    assert.match(joined, /shortRange/);
    assert.ok(!joined.includes("geoglowsForecast"),
      "geoglowsForecast is well inside its 48h cap and must not be reported");
  });

  test("the NEWEST document per product is judged, not the oldest", () => {
    // One reach failing to fetch is a per-reach failure the run already
    // records and retries. It is not a stalled product, and reporting it as
    // one would make the alarm cry wolf until nobody reads it.
    const fresh = assessProductFreshness(
      [sample("shortRange", 30, "old"), sample("shortRange", 1, "new")] as never,
      NOW);
    assert.equal(fresh.length, 1);
    assert.equal(fresh[0].stale, false);
  });

  test("a product with no documents is skipped, not reported down", () => {
    // Nobody has favourited a river needing it, so there is nothing to be
    // stale. Reporting absence as failure would alarm on an empty store.
    const fresh = assessProductFreshness([sample("shortRange", 1)] as never, NOW);
    assert.deepEqual(fresh.map((p) => p.product), ["shortRange"]);
  });

  test("an unparseable fetchedAt is ignored, it does not read as age zero", () => {
    // Date.parse("") is NaN; treating that as fresh would hide a stall behind
    // a malformed document.
    const fresh = assessProductFreshness(
      [{
        documentId: "x", source: "nwm", product: "shortRange",
        fetchedAt: "", validUntil: "",
      }] as never,
      NOW);
    assert.deepEqual(fresh, []);
  });

  // Caught in production on 2026-08-29, within a minute of the per-product
  // check going live: storeHealth returned 503 "down" with
  // "returnPeriods has not advanced for 17h (cap 6h)". Nothing was wrong. The
  // near-static products are on no refresh cycle at all — they hold a 30-day
  // window and storeStaticDaily rewrites one only when it is missing or within
  // 7 days of expiring, so an untouched 23-day-old document is healthy.
  //
  // A false alarm is worse than no alarm: Phase 7 hands this signal to users,
  // and one that cries wolf gets ignored before the day it is right.
  test("the near-static products are not judged by the hourly default", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [sample("returnPeriods", 17), sample("reachMetadata", 17)] as never);

    assert.equal(h.status, "healthy",
      `17h is normal for a 30-day product: ${h.problems.join("; ")}`);
  });

  test("a static product IS reported once it stops being maintained", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [sample("returnPeriods", 33 * 24)] as never);

    assert.notEqual(h.status, "healthy",
      "past its 30-day window plus slack, nothing is refreshing it");
  });

  test("healthy products are still reported, so the log shows coverage", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [sample("shortRange", 1), sample("mediumRange", 2)] as never);
    assert.equal(h.status, "healthy");
    assert.equal(h.products.length, 2);
  });

  test("omitting samples keeps the old coarse behaviour", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW);
    assert.equal(h.status, "healthy");
    assert.deepEqual(h.products, []);
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

describe("the probe key is not always the product name", () => {
  // Round 3, B3. The store's analysisAssimilation document holds a SHORT RANGE
  // body with a shortRange run, because that is what the client derives
  // current flow from. The probe's analysisAssimilation key comes from NOAA's
  // ?series=analysis_assimilation endpoint — a genuinely different series,
  // measured ~3 hours BEHIND short range.
  //
  // Compared directly, isRunNewer(AA 20:00Z, stored SR 23:00Z) is false, so
  // the product read "unchanged" and never triggered again — while its own
  // validUntil expired every hour.
  const probeSample = probe({
    analysisAssimilation: "2026-08-24T20:00:00Z",
    shortRange: "2026-08-24T23:00:00Z",
  });

  test("analysisAssimilation is compared against the shortRange probe key",
    () => {
      assert.equal(probeRunFor(probeSample, "analysisAssimilation"),
        "2026-08-24T23:00:00Z",
        "the AA document carries a shortRange run, so it must be compared " +
        "against the shortRange probe key");
    });

  test("a stored shortRange run does NOT read as unchanged", () => {
    const d = decideTriggers(probeSample,
      {analysisAssimilation: "2026-08-24T22:00:00Z"},
      ["analysisAssimilation"]);

    assert.deepEqual(d.triggered, ["analysisAssimilation"],
      "comparing against the AA series made this product stop triggering " +
      "after its first write");
  });

  test("it still does not trigger when genuinely level", () => {
    const d = decideTriggers(probeSample,
      {analysisAssimilation: "2026-08-24T23:00:00Z"},
      ["analysisAssimilation"]);
    assert.deepEqual(d.triggered, []);
  });

  test("every other product uses its own key", () => {
    for (const p of ["shortRange", "mediumRange", "longRange"] as const) {
      assert.equal(probeRunFor(probe({[p]: "2026-08-24T12:00:00Z"}), p),
        "2026-08-24T12:00:00Z");
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Orphaned documents. Found in production 2026-08-29, not in review: four
// documents belonging to reach 9962444 — unfavourited, still inside the GC's
// seven-day grace — held runs from 2026-08-24. Because the sample took the
// oldest run across EVERY document of a product, every product read as
// "upstream advanced" every hour. One run planned 116 fetches and wrote 0.
// That is Phase 4 guard 1 ("no new run means zero fetches") failing silently,
// for however long it had been since that reach was unfavourited.

describe("the oldest stored run ignores documents no run can update", () => {
  const live = new Set([
    "nwm__100__shortRange",
    "nwm__200__shortRange",
  ]);

  function s(documentId: string, runId: string | null): RunSample {
    return {documentId, runId};
  }

  test("a followed reach that is behind still holds the sample back", () => {
    // The reason the sample is ascending in the first place. Must survive.
    assert.equal(
      oldestLiveRun([
        s("nwm__100__shortRange", "2026-08-29T02:00:00Z"),
        s("nwm__200__shortRange", "2026-08-29T00:00:00Z"),
      ], live),
      "2026-08-29T00:00:00Z");
  });

  test("an orphan's frozen run does not hold the sample back", () => {
    assert.equal(
      oldestLiveRun([
        s("nwm__100__shortRange", "2026-08-29T02:00:00Z"),
        s("nwm__200__shortRange", "2026-08-29T02:00:00Z"),
        // The 9962444 case: old, and not in the work list.
        s("nwm__9962444__shortRange", "2026-08-24T23:00:00Z"),
      ], live),
      "2026-08-29T02:00:00Z");
  });

  test("the orphan case would have triggered before, and does not now", () => {
    const samples = [
      s("nwm__100__shortRange", "2026-08-29T02:00:00Z"),
      s("nwm__9962444__shortRange", "2026-08-24T23:00:00Z"),
    ];
    const upstream = "2026-08-29T02:00:00Z";
    const held = oldestLiveRun(samples, live);
    const decision = decideTriggers(
      {referenceTimes: {shortRange: upstream}, sampledAt: new Date()},
      {shortRange: held},
      ["shortRange"]);
    assert.deepEqual(decision.triggered, []);
    assert.match(decision.reasons.shortRange!, /unchanged/);
  });

  test("no live documents at all still reads as an empty store", () => {
    // Must trigger: this is a genuinely uncovered product, not an orphan.
    assert.equal(
      oldestLiveRun([s("nwm__9962444__shortRange", "2026-08-24T23:00:00Z")],
        live),
      null);
  });

  test("live documents without a run do not read as an empty store", () => {
    // Null would trigger a full fan-out. They are simply not orderable.
    assert.equal(oldestLiveRun([s("nwm__100__shortRange", null)], live), null);
    assert.equal(
      oldestLiveRun([
        s("nwm__100__shortRange", null),
        s("nwm__200__shortRange", "2026-08-29T02:00:00Z"),
      ], live),
      "2026-08-29T02:00:00Z");
  });

  test("an empty collection reads as an empty store", () => {
    assert.equal(oldestLiveRun([], live), null);
  });
});
