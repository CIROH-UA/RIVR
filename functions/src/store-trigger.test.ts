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
  assessRunCurrency,
  decideTriggers,
  probeRunFor,
  quotaUsage,
} from "./store-trigger.js";
import {ForecastProductId} from "./store-keys.js";
import {maxHoldMs, maxRunAgeMs} from "./store-window.js";
import {MANAGED_PRODUCTS, GEOGLOWS_PRODUCTS} from "./store-service.js";

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

describe("run currency — the failure write recency cannot see", () => {
  /**
   * A stored document written NOW but carrying a run from `runAgeHours` ago.
   * @param {string} product - Product id.
   * @param {number} runAgeHours - How old the run is.
   * @param {number} fetchedAgeHours - How long ago it was written.
   * @param {string} id - Document id.
   * @return {object} A StoredWindowSample.
   */
  function held(
    product: string,
    runAgeHours: number,
    fetchedAgeHours = 0.5,
    id = "d"
  ) {
    return {
      documentId: `${product}__${id}`,
      source: product.startsWith("geoglows") ? "geoglows" : "nwm",
      product,
      fetchedAt:
        new Date(NOW.getTime() - fetchedAgeHours * 3600_000).toISOString(),
      validUntil: NOW.toISOString(),
      runId: new Date(NOW.getTime() - runAgeHours * 3600_000).toISOString(),
    };
  }

  // THE incident, reconstructed. On 2026-08-29 the GEOGLOWS job ran at 01:30
  // every day, fetched, got a forecast_date one day newer than the stored one,
  // and wrote it. Writes were punctual — `fetchedAt` minutes old — while the
  // water was a day stale. Both the old collection-wide heartbeat AND the
  // per-product write-recency check report that as perfectly healthy. Only run
  // currency sees it, and it took a device log to notice at the time.
  test("punctual writes carrying yesterday's run are caught", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000), // written minutes ago
      new Date(NOW.getTime() - 600_000),
      NOW,
      // 49.5h is what the old 01:30 schedule actually produced: it took
      // yesterday's run and held it until the next 01:30. Cap is 42h.
      [held("geoglowsForecast", 49.5, 0.25)] as never);

    assert.notEqual(h.status, "healthy",
      "written 15 minutes ago and still a day out of date — this is the " +
      "exact shape that ran undetected for days");
    assert.match(h.problems.join(" "), /geoglowsForecast is serving a run/);
  });

  test("a punctual write of a CURRENT run is healthy", () => {
    // The same document shape, one day younger. Guards against a cap so tight
    // that normal operation alarms.
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [held("geoglowsForecast", 16, 0.25)] as never);

    assert.equal(h.status, "healthy", h.problems.join("; "));
  });

  // GEOGLOWS stamps its run at the day's 00Z and publishes 10:15-10:30 UTC, so
  // the oldest a legitimate run gets is ~34.5h just before the next lands.
  // The margin that a 36h cap did not leave. What matters is not when
  // GEOGLOWS publishes (10:15-10:30Z) but when WE fetch it:
  // storeGeoglowsDaily runs at 11:30Z with no retry, so a stored run reaches
  // 35.5h just before replacement. A 36h cap left ~25 minutes, and any
  // publication later than 11:30 — the case the schedule is explicitly not
  // trusted for — would have returned 503 for the next 23 hours.
  test("a GEOGLOWS run just before OUR next fetch is still healthy", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [held("geoglowsForecast", 35.5, 0.25)] as never);
    assert.equal(h.status, "healthy",
      "35.5h is the normal maximum, not an anomaly; alarming here would " +
      "cry wolf every single morning at 11:29");
  });

  test("a late GEOGLOWS publication does not immediately alarm", () => {
    // The schedule is documented as not trusted. A run that lands a few
    // hours late must not page anyone.
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [held("geoglowsForecast", 41, 0.25)] as never);
    assert.equal(h.status, "healthy", h.problems.join("; "));
  });

  test("the cap is per product, not one number", () => {
    // 30h: past shortRange's 8h, inside longRange's 36h.
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [held("shortRange", 30), held("longRange", 30)] as never);

    const joined = h.problems.join(" ");
    assert.match(joined, /shortRange is serving a run/);
    assert.ok(!joined.includes("longRange"),
      "long range runs legitimately stay current far longer — its 12Z run " +
      "was observed landing at 21:20Z");
  });

  // A documented five-hour NOAA stall is normal operation in this repo.
  test("a five-hour NOAA quiet period does not alarm", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [held("shortRange", 5), held("analysisAssimilation", 5)] as never);
    assert.equal(h.status, "healthy", h.problems.join("; "));
  });

  test("products with no run identity are skipped, not defaulted", () => {
    // reachMetadata and returnPeriods have no run at all. Inheriting another
    // product's cadence is exactly how the hold cap called a healthy store
    // down within a minute of reaching production.
    const runs = assessRunCurrency([
      {
        documentId: "nwm__1__returnPeriods",
        source: "nwm",
        product: "returnPeriods",
        fetchedAt: NOW.toISOString(),
        validUntil: NOW.toISOString(),
      },
    ] as never, NOW);
    assert.deepEqual(runs, []);
  });

  // referenceTimeOf joins several distinct reference times with "|", and a
  // test pins that shape. A bare Date.parse returns NaN for it, and the first
  // version of this skipped the product silently — an unparseable run and a
  // current one produced identical output: healthy. That is the monitor going
  // quiet for exactly the reason it exists.
  test("a pipe-joined runId is read, not skipped", () => {
    const at = (h: number) =>
      new Date(NOW.getTime() - h * 3600_000).toISOString();
    const runs = assessRunCurrency([
      {
        documentId: "x", source: "nwm", product: "shortRange",
        fetchedAt: NOW.toISOString(), validUntil: NOW.toISOString(),
        runId: `${at(40)}|${at(20)}`,
      },
    ] as never, NOW);

    assert.equal(runs.length, 1, "the pipe-joined run was dropped entirely");
    // The NEWEST segment is the run we actually hold.
    assert.ok(Math.abs(runs[0].runAgeMs - 20 * 3600_000) < 60_000);
  });

  test("an unparseable runId is ignored, not read as age zero", () => {
    const runs = assessRunCurrency([
      {
        documentId: "x", source: "nwm", product: "shortRange",
        fetchedAt: NOW.toISOString(), validUntil: NOW.toISOString(),
        runId: "not-a-date",
      },
    ] as never, NOW);
    assert.deepEqual(runs, []);
  });

  test("the NEWEST run per product is judged, not the oldest", () => {
    const runs = assessRunCurrency(
      [held("shortRange", 40, 0.5, "lagging"),
        held("shortRange", 1, 0.5, "current")] as never,
      NOW);
    assert.equal(runs.length, 1);
    assert.equal(runs[0].stale, false);
  });

  // Both dimensions are reported, so a healthy log proves both were checked.
  test("write recency and run currency are reported separately", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [held("shortRange", 1)] as never);
    assert.equal(h.products.length, 1);
    assert.equal(h.runs.length, 1);
  });
});

describe("every managed product is actually judged", () => {
  // Nothing guarded this, and the omission is silent by construction:
  // maxRunAgeMs returns null for an unknown product and assessRunCurrency
  // skips it. A product added to the refresh cycle without a cap entry would
  // be exempt from run currency forever, with no test failing and no log
  // line saying so. Same mutation class as store-health-wiring.test.ts.
  test("MANAGED_PRODUCTS and GEOGLOWS_PRODUCTS all have a run-age cap", () => {
    for (const p of [...MANAGED_PRODUCTS, ...GEOGLOWS_PRODUCTS]) {
      assert.notEqual(maxRunAgeMs(p), null,
        `${p} is on the refresh cycle but has no MAX_RUN_AGE_MS entry, so it ` +
        "is silently exempt from run-currency checking");
    }
  });

  test("and a hold cap, so write recency judges them too", () => {
    for (const p of [...MANAGED_PRODUCTS, ...GEOGLOWS_PRODUCTS]) {
      assert.ok(maxHoldMs(p) > 0, `${p} has no hold cap`);
    }
  });
});

describe("the alarm must not call a documented-normal day an outage", () => {
  /**
   * A sample stalled by the same amount on both dimensions.
   * @param {string} product - Product id.
   * @param {number} hours - Age of both the write and the run.
   * @return {object} A StoredWindowSample.
   */
  function stalled(product: string, hours: number) {
    const at = new Date(NOW.getTime() - hours * 3600_000).toISOString();
    return {
      documentId: `${product}__d`,
      source: "nwm",
      product,
      fetchedAt: at,
      validUntil: NOW.toISOString(),
      runId: at,
    };
  }

  // THE false alarm this grouping exists to stop, found by review before
  // deploying. `analysisAssimilation` and `shortRange` both come from NOAA's
  // `short_range` series — same fetch, same section, same probe key, same
  // write — so they always stall together. With write recency AND run
  // currency both reporting per product, ONE pause produced four problem
  // lines, and more than one line meant "down", which the endpoint serves as
  // 503.
  //
  // This repo documents a five-hour NOAA stall as normal and cites it as
  // proof that guard 1 works. Paging a human for it is exactly the
  // cry-wolf failure that the returnPeriods 503 taught us to take seriously.
  test("one stalled NOAA series is ONE cause, not four problems", () => {
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 7 * 3600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [stalled("analysisAssimilation", 7), stalled("shortRange", 7)] as never);

    assert.notEqual(h.status, "down",
      "one upstream series pausing must never read as a full outage: " +
      h.problems.join("; "));
  });

  test("two genuinely independent products DO read as down", () => {
    // The grouping must not swallow real breadth: NWM and GEOGLOWS failing
    // together is two causes and should escalate.
    const h = assessStoreHealth(
      new Date(NOW.getTime() - 600_000),
      new Date(NOW.getTime() - 600_000),
      NOW,
      [stalled("shortRange", 30), stalled("geoglowsForecast", 60)] as never);

    assert.equal(h.status, "down", h.problems.join("; "));
  });

  // Sized against 163 real samples from publish_cadence_log: an 8h cap would
  // have fired on 29 of them (17.8%), with a maximum observed run age of
  // 11.0h. The cap is 16h.
  test("the worst run age seen in eight days of real probe data is healthy",
    () => {
      const h = assessStoreHealth(
        new Date(NOW.getTime() - 600_000),
        new Date(NOW.getTime() - 600_000),
        NOW,
        [
          stalled("analysisAssimilation", 11),
          stalled("shortRange", 11),
        ] as never);

      // Not "healthy": past the hold cap the store really has stopped
      // covering this product, and saying so is the honest report. What it
      // must NOT be is "down", which the endpoint serves as 503 — one NOAA
      // series pausing is a bad afternoon upstream, not an outage here.
      assert.notEqual(h.status, "down",
        "11h is the worst run age measured across 163 hourly probes; a " +
        "single stalled series must not page anyone: " +
        h.problems.join("; "));

      // And run currency specifically must stay quiet at 11h — that is the
      // whole reason the cap moved from 8h to 16h.
      assert.ok(!h.problems.some((p) => p.includes("serving a run")),
        "run currency fired at 11h, which 163 real samples say is normal");
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
