// functions/src/store-window.test.ts
//
// ADR 0011 Phase 5. These tests exist because of a device measurement, not a
// code review: on 2026-08-28 a clean-install iPhone made 78 NOAA calls at
// 15:14 UTC and zero at 15:34 UTC, with nothing changed in between except
// where the clock sat relative to the refresher. The store was correct and
// unused for 15 minutes of every hour.
//
// The first block pins the write-time floor. The second pins the decision to
// re-verify rather than let a correct document rot — and, just as important,
// the cap that stops that becoming "serve it forever".

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {windowSampleFrom} from "./store-firestore.js";

import {
  REFRESH_MARGIN_MS,
  buildStoreDocument,
  nextGeoglowsRefresh,
  nextHourlyRefresh,
  storeValidUntil,
  validUntil,
} from "./store-document.js";
import {
  DEFAULT_MAX_HOLD_MS,
  MAX_HOLD_MS,
  StoredWindowSample,
  maxHoldMs,
  planWindowExtensions,
} from "./store-window.js";


/**
 * Treat every supplied sample as live.
 *
 * The planner takes the work list's document ids so it can tell an ORPHAN — a
 * reach nobody favourites, which no run will ever rewrite — from a document
 * upstream has stopped feeding. Every case below predates that distinction and
 * is about the second thing, so they all opt in as live.
 *
 * @param {readonly StoredWindowSample[]} samples - Samples under test.
 * @return {Set<string>} Their document ids.
 */
function liveOf(samples: readonly StoredWindowSample[]): Set<string> {
  return new Set(samples.map((s) => s.documentId));
}

describe("refresh schedule arithmetic", () => {
  test("the next hourly refresh is the next :20, strictly after now", () => {
    assert.equal(
      nextHourlyRefresh(new Date("2026-08-28T15:00:00Z")).toISOString(),
      "2026-08-28T15:20:00.000Z");
    assert.equal(
      nextHourlyRefresh(new Date("2026-08-28T15:19:59Z")).toISOString(),
      "2026-08-28T15:20:00.000Z");
    // Exactly on the boundary rolls forward: a run starting at :20 cannot be
    // the run that rescues a document expiring at :20.
    assert.equal(
      nextHourlyRefresh(new Date("2026-08-28T15:20:00Z")).toISOString(),
      "2026-08-28T16:20:00.000Z");
    assert.equal(
      nextHourlyRefresh(new Date("2026-08-28T23:45:00Z")).toISOString(),
      "2026-08-29T00:20:00.000Z");
  });

  test("the next GEOGLOWS refresh is the next 11:30 UTC", () => {
    // Was 01:30 until 2026-08-29, when it turned out the day's run has never
    // published by that hour; 11:30 sits an hour past the measured 10:15-10:30
    // publication window.
    assert.equal(
      nextGeoglowsRefresh(new Date("2026-08-28T00:15:00Z")).toISOString(),
      "2026-08-28T11:30:00.000Z");
    assert.equal(
      nextGeoglowsRefresh(new Date("2026-08-28T11:30:00Z")).toISOString(),
      "2026-08-29T11:30:00.000Z");
    assert.equal(
      nextGeoglowsRefresh(new Date("2026-08-28T23:55:00Z")).toISOString(),
      "2026-08-29T11:30:00.000Z");
  });
});

describe("the write-time floor closes the gap that was measured", () => {
  // The exact case from the device run: written at 14:20, publication lag says
  // 15:05, refresher does not return until 15:20.
  const written = new Date("2026-08-28T14:20:17.000Z");

  test("hourly products used to expire 15 minutes before the refresher", () => {
    assert.equal(
      validUntil("nwm", "shortRange", written, "23021904").toISOString(),
      "2026-08-28T15:05:00.000Z");
  });

  test("a stored hourly window now outlives the next refresher run", () => {
    const stamped = storeValidUntil("nwm", "shortRange", written, "23021904");
    assert.equal(stamped.toISOString(), "2026-08-28T15:30:00.000Z");
    assert.ok(
      stamped.getTime() >=
        nextHourlyRefresh(written).getTime() + REFRESH_MARGIN_MS,
      "the window must cover the refresher plus room to finish");
  });

  test("every managed NWM product is covered past the next refresher", () => {
    const products = [
      "currentFlow", "shortRange", "mediumRange", "longRange",
    ] as const;
    // Walk a full day at five-minute steps: there must be no instant at which
    // a freshly written document expires before the next run can replace it.
    for (const product of products) {
      for (let m = 0; m < 24 * 60; m += 5) {
        const now = new Date(Date.UTC(2026, 7, 28, 0, m));
        const stamped = storeValidUntil("nwm", product, now, "23021904");
        const rescue = nextHourlyRefresh(now).getTime() + REFRESH_MARGIN_MS;
        assert.ok(stamped.getTime() >= rescue,
          `${product} at ${now.toISOString()} expires before its refresher`);
      }
    }
  });

  test("a GEOGLOWS window outlives its refresher at every hour of the day",
    () => {
      // Publication lag says 00:15 the next day, which is a long window and
      // usually wins outright. The floor still has to hold at the one hour
      // where it does not — just before midnight, when the publish boundary is
      // minutes away and the next refresher run is on the far side of it.
      for (let m = 0; m < 24 * 60; m += 5) {
        const now = new Date(Date.UTC(2026, 7, 28, 0, m));
        const stamped = storeValidUntil("geoglows", "geoglowsForecast", now, "23021904");
        const rescuer = nextGeoglowsRefresh(
          new Date(now.getTime() + REFRESH_MARGIN_MS));
        assert.ok(stamped.getTime() >= rescuer.getTime() + REFRESH_MARGIN_MS,
          `at ${now.toISOString()} the window ends before a usable refresh`);
      }
    });

  test("buildStoreDocument actually stamps the floored window", () => {
    // The wiring, not just the arithmetic: a document built at the measured
    // instant must carry 15:30, not the 15:05 that sent the device to NOAA.
    const doc = buildStoreDocument({
      source: "nwm",
      reachId: "10376596",
      product: "shortRange",
      payload: {shortRange: {}},
      unit: "CFS",
      referenceTime: "2026-08-28T12:00:00Z",
      fetchedAt: new Date("2026-08-28T14:20:17.000Z"),
    });
    assert.equal(doc.window.validUntil, "2026-08-28T15:30:00.000Z");
  });

  test("a sweep just BEFORE the scheduled minute still clears the run after it",
    () => {
      // The 2026-08-29 case: a manual trigger at 02:16 must not treat the
      // 02:20 run — four minutes away — as the thing that will rescue the
      // document, because that run is itself the one doing the stamping.
      const offCycle = new Date("2026-08-29T02:16:30.000Z");
      const stamped = storeValidUntil("nwm", "shortRange", offCycle, "23021904");
      assert.equal(stamped.toISOString(), "2026-08-29T03:30:00.000Z");
      assert.ok(stamped > new Date("2026-08-29T03:20:00.000Z"),
        "must outlive the 03:20 run, not merely the 02:20 one");
    });

  test("no instant in the day stamps a window its own refresher cannot save",
    () => {
      // Minute by minute, including every minute around :20 where the old
      // floor picked the imminent run as its rescuer.
      for (let m = 0; m < 24 * 60; m++) {
        const now = new Date(Date.UTC(2026, 7, 29, 0, m));
        const stamped = storeValidUntil("nwm", "shortRange", now, "23021904");
        // The first refresh that starts at least a margin from now.
        const rescuer = nextHourlyRefresh(
          new Date(now.getTime() + REFRESH_MARGIN_MS));
        assert.ok(stamped.getTime() >= rescuer.getTime() + REFRESH_MARGIN_MS,
          `at ${now.toISOString()} the window ends before a usable refresh`);
      }
    });

  test("static products keep their 30-day window; the floor is a no-op", () => {
    const written = new Date("2026-08-28T02:30:00.000Z");
    assert.equal(
      storeValidUntil("nwm", "reachMetadata", written, "23021904").toISOString(),
      validUntil("nwm", "reachMetadata", written, "23021904").toISOString());
  });

  test("the floor never SHORTENS a window", () => {
    const products = [
      "currentFlow", "shortRange", "mediumRange", "longRange",
      "returnPeriods", "reachMetadata",
    ] as const;
    for (const product of products) {
      for (let h = 0; h < 24; h++) {
        const now = new Date(Date.UTC(2026, 7, 28, h, 7));
        assert.ok(
          storeValidUntil("nwm", product, now, "23021904").getTime() >=
            validUntil("nwm", product, now, "23021904").getTime(),
          `${product} at ${h}:07 was shortened by the floor`);
      }
    }
  });
});

describe("re-verifying a document upstream has not replaced", () => {
  const NOW = new Date("2026-08-28T16:20:00.000Z");

  function sample(over: Partial<StoredWindowSample> = {}): StoredWindowSample {
    return {
      documentId: "nwm__10376596__shortRange",
      source: "nwm",
      reachId: "10376596",
      product: "shortRange",
      fetchedAt: "2026-08-28T15:20:00.000Z",
      validUntil: "2026-08-28T16:30:00.000Z",
      ...over,
    };
  }

  test("a document expiring before the next run is extended past it", () => {
    const plan = planWindowExtensions(liveOf([sample()]), [sample()], NOW);
    assert.equal(plan.extend.length, 1);
    assert.equal(plan.extend[0].documentId, "nwm__10376596__shortRange");
    assert.equal(plan.extend[0].validUntil, "2026-08-28T17:30:00.000Z");
    assert.equal(plan.abandoned.length, 0);
  });

  test("a document already covered is left alone", () => {
    const plan = planWindowExtensions(liveOf([sample({validUntil: "2026-08-29T00:00:00.000Z"})]), 
      [sample({validUntil: "2026-08-29T00:00:00.000Z"})], NOW);
    assert.equal(plan.extend.length, 0);
    assert.equal(plan.covered, 1);
  });

  test("the extension is computed from NOW, so it always clears the cap", () => {
    // A document written moments ago and one written 50 minutes ago land on
    // the same new expiry: coverage is a property of the clock, not of age.
    const plan = planWindowExtensions(liveOf([
      sample({documentId: "a", fetchedAt: "2026-08-28T16:19:00.000Z"}),
      sample({documentId: "b", fetchedAt: "2026-08-28T15:30:00.000Z"}),
    ]), [
      sample({documentId: "a", fetchedAt: "2026-08-28T16:19:00.000Z"}),
      sample({documentId: "b", fetchedAt: "2026-08-28T15:30:00.000Z"}),
    ], NOW);
    assert.deepEqual(
      plan.extend.map((e) => e.validUntil),
      ["2026-08-28T17:30:00.000Z", "2026-08-28T17:30:00.000Z"]);
  });

  test("past its hold cap a document is abandoned, not extended", () => {
    // Seven hours old, cap for an hourly product is six.
    const plan = planWindowExtensions(liveOf([sample({fetchedAt: "2026-08-28T09:20:00.000Z"})]), 
      [sample({fetchedAt: "2026-08-28T09:20:00.000Z"})], NOW);
    assert.equal(plan.extend.length, 0);
    assert.deepEqual(plan.abandoned, ["nwm__10376596__shortRange"]);
  });

  test("long range holds far longer, because its publish lag is far longer",
    () => {
      // The 12Z run did not land until 21:20Z on 2026-08-28. An hourly cap
      // would have abandoned every long-range document while it was still the
      // only long-range data in existence — the bug this file exists to fix.
      const nineHoursOld = sample({
        documentId: "nwm__10376596__longRange",
        product: "longRange",
        fetchedAt: "2026-08-28T07:20:00.000Z",
        validUntil: "2026-08-28T12:05:00.000Z",
      });
      const plan = planWindowExtensions(liveOf([nineHoursOld]), [nineHoursOld], NOW);
      assert.equal(plan.abandoned.length, 0);
      assert.equal(plan.extend.length, 1);
    });

  test("a hold cap exists for every managed product", () => {
    for (const p of ["currentFlow", "shortRange", "mediumRange",
      "longRange", "geoglowsForecast"] as const) {
      assert.ok(MAX_HOLD_MS[p] > 0, `${p} has no hold cap`);
      assert.equal(maxHoldMs(p, "23021904"), MAX_HOLD_MS[p]);
    }
    // The near-static products are named now, and must be: they hold a 30-day
    // window and are rewritten only when missing or nearly expired, so the
    // 6-hour default called a healthy 17-hour-old document DOWN the minute the
    // per-product health check reached production (2026-08-29).
    for (const p of ["returnPeriods", "reachMetadata"] as const) {
      assert.ok(maxHoldMs(p, "23021904") > 30 * 24 * 3600_000,
        `${p} holds a 30-day window; a shorter cap reports it stale`);
    }

    // A genuinely unnamed product still falls back to the short default rather
    // than to "forever", which is the direction a mistake here must fail in.
    // `returnPeriods` used to stand in for this case and no longer can.
    assert.equal(maxHoldMs("mediumRangeBlend", "23021904"), DEFAULT_MAX_HOLD_MS);
  });

  test("an unreadable window is named and left exactly as it is", () => {
    const plan = planWindowExtensions(liveOf([
      sample({documentId: "bad-fetched", fetchedAt: "not-a-date"}),
      sample({documentId: "bad-until", validUntil: ""}),
    ]), [
      sample({documentId: "bad-fetched", fetchedAt: "not-a-date"}),
      sample({documentId: "bad-until", validUntil: ""}),
    ], NOW);
    assert.equal(plan.extend.length, 0);
    assert.deepEqual(plan.malformed.sort(), ["bad-fetched", "bad-until"]);
  });

  test("repeated extension cannot hold a value forever", () => {
    // fetchedAt is never rewritten, so the cap keeps counting from the real
    // fetch. Simulate hourly re-verification of a value upstream never
    // replaces: it must stop being extended, not drift indefinitely.
    const fetchedAt = "2026-08-28T09:20:00.000Z";
    const capEnd = Date.parse(fetchedAt) + 6 * 3600_000; // 15:20
    let validUntilNow = "2026-08-28T10:30:00.000Z";
    let extensions = 0;
    let abandoned = false;

    for (let h = 10; h <= 20; h++) {
      const at = new Date(Date.UTC(2026, 7, 28, h, 20));
      const plan = planWindowExtensions(liveOf([sample({fetchedAt, validUntil: validUntilNow})]), 
        [sample({fetchedAt, validUntil: validUntilNow})], at);

      if (plan.abandoned.length > 0) {
        assert.deepEqual(plan.abandoned, ["nwm__10376596__shortRange"]);
        abandoned = true;
        break;
      }
      if (plan.extend.length === 0) continue; // covered to the cap already
      validUntilNow = plan.extend[0].validUntil;
      extensions++;

      // THE invariant, and the reason this test changed shape. An extension
      // must never promise past the hold cap. It used to stamp the full
      // refresh floor, so the last one before abandonment reached an hour and
      // ten minutes BEYOND the cap — and the client, which stops vouching
      // exactly at the cap, spent that gap warning about the newest data in
      // existence. For GEOGLOWS the same arithmetic gave a day of it.
      assert.ok(Date.parse(validUntilNow) <= capEnd,
        `extended to ${validUntilNow}, past the 15:20 cap — the client would ` +
        "warn while the server was still vouching");
    }

    assert.ok(extensions > 0, "nothing was ever extended");
    assert.ok(abandoned, "the document was never abandoned; it can be held " +
      "forever one extension at a time");
  });

  test("an empty sample set is a no-op, not an error", () => {
    const plan = planWindowExtensions(liveOf([]), [], NOW);
    assert.deepEqual(plan.extend, []);
    assert.deepEqual(plan.abandoned, []);
    assert.equal(plan.covered, 0);
  });
});

describe("an orphan is not an outage", () => {
  // The live defect this fixes, measured 2026-08-30. Four reaches that nobody
  // favourites any more kept their documents for the GC's seven-day grace. No
  // run rewrites an orphan, so every hour they sat further past their hold cap
  // and `extendWindowCoverage` reported "store windows past their hold cap" at
  // ERROR — 83 store errors in seven days, on a store that was working
  // perfectly.
  //
  // CLAUDE.md's rule is that over-warning trains dismissal, and this is how:
  // a real outage would have looked exactly like the noise everyone had
  // already learned to skip. It also falsified the stated precondition for
  // removing the Phase 5 kill switch — "once the store has run clean".
  const NOW = new Date("2026-08-30T16:20:00.000Z");

  /**
   * A document 31 hours stale — well past every hourly cap.
   * @param {string} reachId - Which reach.
   * @return {StoredWindowSample} The sample.
   */
  function stale(reachId: string): StoredWindowSample {
    return {
      documentId: `nwm__${reachId}__shortRange`,
      source: "nwm",
      reachId,
      product: "shortRange",
      fetchedAt: "2026-08-29T09:20:00.000Z",
      validUntil: "2026-08-29T10:30:00.000Z",
    };
  }

  test("an unfollowed reach is counted as orphaned, never abandoned", () => {
    const orphan = stale("1352774");
    const plan = planWindowExtensions(new Set(), [orphan], NOW);

    assert.equal(plan.orphaned, 1);
    assert.deepEqual(plan.abandoned, [],
      "an orphan reported as abandoned is an hourly ERROR about a store " +
      "that is behaving correctly");
  });

  test("a FOLLOWED reach past its cap is still abandoned, and loudly", () => {
    // The other direction, which matters more: silencing orphans must not
    // silence the real signal. Mutation-checked by making the planner skip
    // every sample, which turns this red.
    const real = stale("23021904");
    const plan = planWindowExtensions(
      new Set([real.documentId]), [real], NOW);

    assert.deepEqual(plan.abandoned, [real.documentId]);
    assert.equal(plan.orphaned, 0);
  });

  test("a mixed sweep separates the two", () => {
    const orphan = stale("1352774");
    const real = stale("23021904");
    const plan = planWindowExtensions(
      new Set([real.documentId]), [orphan, real], NOW);

    assert.equal(plan.orphaned, 1);
    assert.deepEqual(plan.abandoned, [real.documentId],
      "the four orphans measured in production were drowning exactly this " +
      "signal");
  });

  test("an orphan is not extended either — it is simply left alone", () => {
    // A fresh orphan must not have its window re-stamped: writing to a
    // document no run will ever refresh again is a write per hour for seven
    // days, for a reach nobody is looking at.
    const fresh: StoredWindowSample = {
      documentId: "nwm__1352774__shortRange",
      source: "nwm",
      reachId: "1352774",
      product: "shortRange",
      fetchedAt: "2026-08-30T16:00:00.000Z",
      validUntil: "2026-08-30T16:25:00.000Z",
    };
    const plan = planWindowExtensions(new Set(), [fresh], NOW);

    assert.deepEqual(plan.extend, []);
    assert.equal(plan.orphaned, 1);
    assert.equal(plan.covered, 0);
  });
});

describe("the island cap reaches the abandonment decision", () => {
  // Phase 9 review, finding 2. The pure planner was thoroughly tested with
  // hand-built samples and the CONNECTION into it was not, so both of these
  // passed 438/438:
  //
  //   store-firestore.ts  reachId: ""                    (sampler drops it)
  //   store-window.ts     maxHoldMs(s.product, "23021904") (planner ignores it)
  //
  // Same shape as the Dart fakes that accepted `reachId` and threw it away —
  // fixed on one side of the language boundary only. `assessProductFreshness`
  // and `assessRunCurrency` were already pinned, which made this look
  // accidental rather than considered.
  //
  // What it costs: a healthy Hawaii short-range document, 12 h old on a
  // 12-hourly run, is judged by the CONUS 6-hour cap — abandoned every cycle,
  // never extended, every device holding that favourite dropping to the live
  // path for half of each cycle. That is guard 1's exact failure, plus an
  // hourly `store windows past their hold cap` error of precisely the kind
  // this phase spent the day removing.
  const NOW = new Date("2026-08-30T16:20:00.000Z");
  const ISLAND = "800000010";
  const CONUS = "23021904";

  /**
   * A short-range document fetched `ageHours` ago.
   * @param {string} reachId - Which reach.
   * @param {number} ageHours - How long ago it was written.
   * @return {StoredWindowSample} The sample.
   */
  function doc(reachId: string, ageHours: number): StoredWindowSample {
    return {
      documentId: `nwm__${reachId}__shortRange`,
      source: "nwm",
      reachId,
      product: "shortRange",
      fetchedAt: new Date(NOW.getTime() - ageHours * 3600_000).toISOString(),
      validUntil: NOW.toISOString(),
    };
  }

  test("a 12h-old ISLAND document is not abandoned", () => {
    // 12 h is one whole Hawaii cycle: the newest value that exists.
    const s = doc(ISLAND, 12);
    const plan = planWindowExtensions(new Set([s.documentId]), [s], NOW);

    assert.deepEqual(plan.abandoned, [],
      "judged by the CONUS 6-hour cap this is abandoned every cycle, and " +
      "every device with that favourite falls to the live path");
    assert.equal(plan.extend.length, 1,
      "and it must be EXTENDED, not merely left alone");
  });

  test("the same age on a CONUS document IS abandoned", () => {
    // The direction that matters more: the island cap must not leak onto
    // CONUS reaches, or a genuinely stalled document is held for a day.
    const s = doc(CONUS, 12);
    const plan = planWindowExtensions(new Set([s.documentId]), [s], NOW);

    assert.deepEqual(plan.abandoned, [s.documentId]);
  });

  test("a mixed sweep decides each document by ITS OWN reach", () => {
    // The wiring, stated as a difference. A planner that reads one constant
    // reach for every sample passes both tests above in isolation.
    const island = doc(ISLAND, 12);
    const conus = doc(CONUS, 12);
    const plan = planWindowExtensions(
      new Set([island.documentId, conus.documentId]), [island, conus], NOW);

    assert.deepEqual(plan.abandoned, [conus.documentId],
      "exactly one of these two is stale, and which one depends on the reach");
    assert.equal(plan.extend.length, 1);
  });

  test("an island document past even ITS cap is still abandoned", () => {
    // Not "hold forever": 25 h is past the 24 h island cap.
    const s = doc(ISLAND, 25);
    const plan = planWindowExtensions(new Set([s.documentId]), [s], NOW);
    assert.deepEqual(plan.abandoned, [s.documentId]);
  });
});

describe("the sample carries the reach out of Firestore", () => {
  // The other half of Phase 9 review finding 2, and the half my first fix
  // missed: the tests above build samples by hand, so dropping `reachId` in
  // the Firestore mapping still passed all 442. The mapping was inline in a
  // loop that needs an emulator; it is now `windowSampleFrom`, which is pure.
  //
  // `reachId` is not one field among several here. It decides which hold and
  // run-age cap the document is judged by, and an empty one is silently CONUS
  // — so losing it makes every island document expire between runs while
  // every test stays green.

  test("reachId survives the mapping", () => {
    const s = windowSampleFrom("nwm__800000010__shortRange", {
      source: "nwm",
      reachId: "800000010",
      product: "shortRange",
      window: {
        fetchedAt: "2026-08-30T04:20:00.000Z",
        validUntil: "2026-08-30T16:30:00.000Z",
      },
      runId: "2026-08-30T00:00:00Z",
    });

    assert.equal(s.reachId, "800000010",
      "an empty reachId is silently CONUS, so every island document would " +
      "be judged by a cap six times too short");
    assert.equal(s.documentId, "nwm__800000010__shortRange");
    assert.equal(s.fetchedAt, "2026-08-30T04:20:00.000Z");
    assert.equal(s.validUntil, "2026-08-30T16:30:00.000Z");
    assert.equal(s.runId, "2026-08-30T00:00:00Z");
  });

  test("the mapped sample decides by its own reach, end to end", () => {
    // Mapping and planner together, which is the connection that was broken.
    const NOW = new Date("2026-08-30T16:20:00.000Z");
    const twelveHoursAgo =
      new Date(NOW.getTime() - 12 * 3600_000).toISOString();

    const island = windowSampleFrom("nwm__800000010__shortRange", {
      source: "nwm", reachId: "800000010", product: "shortRange",
      window: {fetchedAt: twelveHoursAgo, validUntil: NOW.toISOString()},
    });

    const plan = planWindowExtensions(
      new Set([island.documentId]), [island], NOW);

    assert.deepEqual(plan.abandoned, [],
      "a healthy Hawaii document, read from Firestore and planned, must " +
      "survive its own 24-hour cap rather than CONUS's six");
  });

  test("a document with no reachId does not crash, it degrades to CONUS", () => {
    // The safe direction, stated so it is a decision. A malformed document
    // should cost an extra refetch, never a thrown planner.
    const s = windowSampleFrom("nwm__x__shortRange", {
      source: "nwm", product: "shortRange",
      window: {fetchedAt: "2026-08-30T04:20:00.000Z", validUntil: "x"},
    });
    assert.equal(s.reachId, "");
    assert.doesNotThrow(() =>
      planWindowExtensions(new Set([s.documentId]), [s], new Date()));
  });
});
