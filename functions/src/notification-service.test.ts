// functions/src/notification-service.test.ts
//
// Threshold logic for river alerts (JAWRA reviewer R2-10, which asked how
// notification logic is verified — previously manual-only, via the
// triggerAlertCheck HTTP endpoint).
//
// Scope: evaluateAlert only. It is pure — threshold maths and a CFS→CMS
// conversion, no Firestore, FCM or network. The surrounding
// checkAlertsForTimeSlot is deliberately NOT covered here; it reads and writes
// live Firestore and calls messaging().send(), and this repo has no mocking
// library. Adding one is a dependency decision, not a detail to slip into a
// test pass.
//
// Two defects these tests exist for, both found by reading the code while
// writing them rather than by the tests themselves:
//
//  1. The comparison was `forecastCms > scaledThreshold` — strictly greater —
//     so a flow landing EXACTLY on a return period produced no alert. The
//     server's other classifier, weekly-digest.ts categoryIndexFor(), uses
//     `peakCms < t2`, which classifies that same flow as Action. The digest
//     would say Action while the alert stayed silent. That is the drift ADR
//     0011 decision 13 exists to prevent.
//
//  2. "Highest exceeded threshold wins" was not actually guaranteed.
//     extractReturnPeriodThresholds builds keys as "2-year"/"25-year" — plain
//     strings, not integer-like — so Object.entries() iterates in Firestore
//     field order, not numeric order. The loop overwrites on every match, so a
//     document whose fields happened to be stored 25/2/10/5 would report the
//     LOWEST exceeded threshold as the winner.
//
// Tests marked REGRESSION fail against the version that shipped before them.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {evaluateAlert, ReachData} from "./notification-service.js";

/** The conversion evaluateAlert applies to forecast values (CFS → CMS). */
const CFS_TO_CMS = 0.0283168;

/**
 * A CMS threshold expressed as the CFS flow that lands exactly on it.
 * Building fixtures this way keeps the boundary case exact: no float drift
 * between "the threshold" and "the flow that equals it".
 * @param {number} cfs - Flow in CFS.
 * @return {number} The same flow in CMS.
 */
function cms(cfs: number): number {
  return cfs * CFS_TO_CMS;
}

/** Return periods as NOAA hands them over: one object, CMS values. */
const RETURN_PERIODS: unknown[] = [{
  return_period_2: cms(1000),
  return_period_5: cms(2000),
  return_period_10: cms(3000),
  return_period_25: cms(4000),
}];

/**
 * A reach whose highest forecast value is the given CFS flow.
 * @param {number} cfs - Peak forecast flow in CFS.
 * @param {unknown[]} returnPeriods - Return-period payload to evaluate against.
 * @return {ReachData} Fixture shaped as batchFetchReachData produces it.
 */
function reach(
  cfs: number,
  returnPeriods: unknown[] = RETURN_PERIODS
): ReachData {
  return {
    forecast: {
      shortRange: {values: [{value: cfs, validTime: "2026-08-24T12:00:00Z"}]},
      mediumRange: null,
    },
    returnPeriods,
    riverName: "Test River",
  };
}

describe("evaluateAlert — when an alert fires", () => {
  test("no alert when the peak is below every threshold", () => {
    assert.equal(evaluateAlert("123", reach(500), "cfs"), null);
  });

  // REGRESSION. The case R2-10 asked about. `>` returned null here.
  test("fires at exactly the threshold, not only above it", () => {
    const alert = evaluateAlert("123", reach(1000), "cfs");
    assert.notEqual(alert, null,
      "a peak landing exactly on the 2-year return period must alert; " +
      "weekly-digest already classifies this flow as Action");
    assert.equal(alert?.returnPeriod, "2-year");
  });

  test("one unit below the threshold still does not fire", () => {
    assert.equal(evaluateAlert("123", reach(999.9), "cfs"), null,
      "the boundary is inclusive, not a wider band");
  });

  test("the highest exceeded threshold wins, not the first", () => {
    // 3,500 CFS clears 2/5/10-year, sits under 25-year.
    const alert = evaluateAlert("123", reach(3500), "cfs");
    assert.equal(alert?.returnPeriod, "10-year");
    assert.equal(alert?.threshold, 3000);
  });

  // REGRESSION. Keys are strings, so Object.entries() followed Firestore field
  // order and the last match won — here that was the 5-year.
  test("highest still wins when the document field order is shuffled", () => {
    const shuffled: unknown[] = [{
      return_period_25: cms(4000),
      return_period_2: cms(1000),
      return_period_10: cms(3000),
      return_period_5: cms(2000),
    }];
    const alert = evaluateAlert("123", reach(5000, shuffled), "cfs");
    assert.equal(alert?.returnPeriod, "25-year",
      "the winner must come from the recurrence year, not field order");
    assert.equal(alert?.threshold, 4000);
  });
});

describe("evaluateAlert — unit conversion", () => {
  // Forecast values arrive in CFS; thresholds are stored in CMS. The alert is
  // rendered in whichever unit the user set, so both numbers have to land in
  // the same one.
  test("cfs user sees the CFS flow and the threshold converted back to CFS",
    () => {
      const alert = evaluateAlert("123", reach(5000), "cfs");
      assert.equal(alert?.forecastFlow, 5000);
      assert.equal(alert?.threshold, 4000);
    });

  test("cms user sees both numbers in CMS", () => {
    const alert = evaluateAlert("123", reach(5000), "cms");
    // 5000 × 0.0283168 = 141.58 → 142; 4000 × 0.0283168 = 113.27 → 113.
    assert.equal(alert?.forecastFlow, 142);
    assert.equal(alert?.threshold, 113);
  });

  test("the two units describe the same event, not different ones", () => {
    const inCfs = evaluateAlert("123", reach(5000), "cfs");
    const inCms = evaluateAlert("123", reach(5000), "cms");
    assert.equal(inCfs?.returnPeriod, inCms?.returnPeriod,
      "the unit is presentation only — it must not change which " +
      "threshold was exceeded");
  });
});

describe("evaluateAlert — missing and incomplete data", () => {
  // Every one of these returns null rather than throwing: checkAlertsForTimeSlot
  // evaluates reaches in a loop, so a throw here would abandon the remaining
  // users in the batch.
  test("no forecast is null, not a throw", () => {
    const noForecast: ReachData = {
      forecast: null,
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
    assert.equal(evaluateAlert("123", noForecast, "cfs"), null);
  });

  test("forecast present but every value is the -9999 sentinel is null", () => {
    const sentinel: ReachData = {
      forecast: {
        shortRange: {
          values: [{value: -9999, validTime: "2026-08-24T12:00:00Z"}],
        },
        mediumRange: null,
      },
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
    assert.equal(evaluateAlert("123", sentinel, "cfs"), null,
      "NOAA's no-data sentinel must not be read as a record-breaking flow");
  });

  test("empty return periods is null, not a throw", () => {
    assert.equal(evaluateAlert("123", reach(5000, []), "cfs"), null);
  });

  test("a return-period object with no recognised fields is null", () => {
    assert.equal(evaluateAlert("123", reach(5000, [{}]), "cfs"), null);
    assert.equal(
      evaluateAlert("123", reach(5000, [{unrelated: 5}]), "cfs"), null);
  });

  // Documented divergence, not an endorsement. categoryIndexFor() in
  // weekly-digest.ts requires all four of 2/5/10/25 and returns -1 otherwise;
  // evaluateAlert evaluates against whatever subset it finds. The same reach
  // with a partial return-period document can therefore alert while the digest
  // declines to classify it. ADR 0011 Phase 6 guard 3 is where these two get
  // reconciled; pinning it here so that work starts from a known state.
  test("a partial return-period set still evaluates against what is there",
    () => {
      const partial: unknown[] = [{return_period_2: cms(1000)}];
      const alert = evaluateAlert("123", reach(5000, partial), "cfs");
      assert.equal(alert?.returnPeriod, "2-year");
    });
});
