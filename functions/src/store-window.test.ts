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

  test("the next GEOGLOWS refresh is the next :50, strictly after now", () => {
    // Was a single 01:30 daily slot until 2026-08-29, when it turned out the
    // 00Z run has never published by that hour.
    assert.equal(
      nextGeoglowsRefresh(new Date("2026-08-28T00:15:00Z")).toISOString(),
      "2026-08-28T00:50:00.000Z");
    assert.equal(
      nextGeoglowsRefresh(new Date("2026-08-28T00:50:00Z")).toISOString(),
      "2026-08-28T01:50:00.000Z");
    assert.equal(
      nextGeoglowsRefresh(new Date("2026-08-28T23:55:00Z")).toISOString(),
      "2026-08-29T00:50:00.000Z");
  });
});

describe("the write-time floor closes the gap that was measured", () => {
  // The exact case from the device run: written at 14:20, publication lag says
  // 15:05, refresher does not return until 15:20.
  const written = new Date("2026-08-28T14:20:17.000Z");

  test("hourly products used to expire 15 minutes before the refresher", () => {
    assert.equal(
      validUntil("nwm", "shortRange", written).toISOString(),
      "2026-08-28T15:05:00.000Z");
  });

  test("a stored hourly window now outlives the next refresher run", () => {
    const stamped = storeValidUntil("nwm", "shortRange", written);
    assert.equal(stamped.toISOString(), "2026-08-28T15:30:00.000Z");
    assert.ok(
      stamped.getTime() >=
        nextHourlyRefresh(written).getTime() + REFRESH_MARGIN_MS,
      "the window must cover the refresher plus room to finish");
  });

  test("every managed NWM product is covered past the next refresher", () => {
    const products = [
      "analysisAssimilation", "shortRange", "mediumRange", "longRange",
    ] as const;
    // Walk a full day at five-minute steps: there must be no instant at which
    // a freshly written document expires before the next run can replace it.
    for (const product of products) {
      for (let m = 0; m < 24 * 60; m += 5) {
        const now = new Date(Date.UTC(2026, 7, 28, 0, m));
        const stamped = storeValidUntil("nwm", product, now);
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
        const stamped = storeValidUntil("geoglows", "geoglowsForecast", now);
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
      const stamped = storeValidUntil("nwm", "shortRange", offCycle);
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
        const stamped = storeValidUntil("nwm", "shortRange", now);
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
      storeValidUntil("nwm", "reachMetadata", written).toISOString(),
      validUntil("nwm", "reachMetadata", written).toISOString());
  });

  test("the floor never SHORTENS a window", () => {
    const products = [
      "analysisAssimilation", "shortRange", "mediumRange", "longRange",
      "returnPeriods", "reachMetadata",
    ] as const;
    for (const product of products) {
      for (let h = 0; h < 24; h++) {
        const now = new Date(Date.UTC(2026, 7, 28, h, 7));
        assert.ok(
          storeValidUntil("nwm", product, now).getTime() >=
            validUntil("nwm", product, now).getTime(),
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
      product: "shortRange",
      fetchedAt: "2026-08-28T15:20:00.000Z",
      validUntil: "2026-08-28T16:30:00.000Z",
      ...over,
    };
  }

  test("a document expiring before the next run is extended past it", () => {
    const plan = planWindowExtensions([sample()], NOW);
    assert.equal(plan.extend.length, 1);
    assert.equal(plan.extend[0].documentId, "nwm__10376596__shortRange");
    assert.equal(plan.extend[0].validUntil, "2026-08-28T17:30:00.000Z");
    assert.equal(plan.abandoned.length, 0);
  });

  test("a document already covered is left alone", () => {
    const plan = planWindowExtensions(
      [sample({validUntil: "2026-08-29T00:00:00.000Z"})], NOW);
    assert.equal(plan.extend.length, 0);
    assert.equal(plan.covered, 1);
  });

  test("the extension is computed from NOW, so it always clears the cap", () => {
    // A document written moments ago and one written 50 minutes ago land on
    // the same new expiry: coverage is a property of the clock, not of age.
    const plan = planWindowExtensions([
      sample({documentId: "a", fetchedAt: "2026-08-28T16:19:00.000Z"}),
      sample({documentId: "b", fetchedAt: "2026-08-28T15:30:00.000Z"}),
    ], NOW);
    assert.deepEqual(
      plan.extend.map((e) => e.validUntil),
      ["2026-08-28T17:30:00.000Z", "2026-08-28T17:30:00.000Z"]);
  });

  test("past its hold cap a document is abandoned, not extended", () => {
    // Seven hours old, cap for an hourly product is six.
    const plan = planWindowExtensions(
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
      const plan = planWindowExtensions([nineHoursOld], NOW);
      assert.equal(plan.abandoned.length, 0);
      assert.equal(plan.extend.length, 1);
    });

  test("a hold cap exists for every managed product", () => {
    for (const p of ["analysisAssimilation", "shortRange", "mediumRange",
      "longRange", "geoglowsForecast"] as const) {
      assert.ok(MAX_HOLD_MS[p] > 0, `${p} has no hold cap`);
      assert.equal(maxHoldMs(p), MAX_HOLD_MS[p]);
    }
    // An unnamed product falls back to the short default rather than to
    // "forever", which is the direction a mistake here must fail in.
    assert.equal(maxHoldMs("returnPeriods"), DEFAULT_MAX_HOLD_MS);
  });

  test("an unreadable window is named and left exactly as it is", () => {
    const plan = planWindowExtensions([
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
    let validUntilNow = "2026-08-28T10:30:00.000Z";
    let extensions = 0;
    for (let h = 10; h <= 20; h++) {
      const at = new Date(Date.UTC(2026, 7, 28, h, 20));
      const plan = planWindowExtensions(
        [sample({fetchedAt, validUntil: validUntilNow})], at);
      if (plan.extend.length === 0) {
        assert.deepEqual(plan.abandoned, ["nwm__10376596__shortRange"]);
        break;
      }
      validUntilNow = plan.extend[0].validUntil;
      extensions++;
    }
    // Six-hour cap on a 09:20 fetch: extended at 10:20 through 15:20, then
    // abandoned. The exact count matters less than that it terminates.
    assert.ok(extensions > 0, "nothing was ever extended");
    assert.ok(extensions <= 6, `held for ${extensions} hours past a 6h cap`);
  });

  test("an empty sample set is a no-op, not an error", () => {
    const plan = planWindowExtensions([], NOW);
    assert.deepEqual(plan.extend, []);
    assert.deepEqual(plan.abandoned, []);
    assert.equal(plan.covered, 0);
  });
});
