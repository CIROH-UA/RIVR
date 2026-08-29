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
import {evaluateAlert, labelFor, ReachData, reachKey, timeToPeak}
  from "./notification-service.js";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import {categoryFor} from "./flow-classification.js";

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

// ─────────────────────────────────────────────────────────────────────────────
// ADR 0011 Phase 6 guard 3, added 2026-08-29.
//
// Until now an alert carried a raw recurrence interval and a raw streamflow
// number, and the push notification read "Forecast: 147362 CFS (Exceeds 25-year
// flood threshold)". Neither of those words appears anywhere in the app: the
// card for that same river says "Extreme". Two vocabularies for one river, and
// the alert is the one the user reads on a lock screen without the app open.
//
// The fixture ladder is 2/5/10/25-year at 1000/2000/3000/4000 CFS, so the
// category boundaries are exactly the thresholds the existing tests already
// pin.

describe("evaluateAlert — the category the user will also see", () => {
  test("a peak in the 2-to-5-year band is Action", () => {
    assert.equal(evaluateAlert("123", reach(1000), "cfs")?.category, "Action");
    assert.equal(evaluateAlert("123", reach(1500), "cfs")?.category, "Action");
  });

  test("5-to-10 is Moderate, 10-to-25 is Major", () => {
    assert.equal(evaluateAlert("123", reach(2000), "cfs")?.category,
      "Moderate");
    assert.equal(evaluateAlert("123", reach(2999), "cfs")?.category,
      "Moderate");
    assert.equal(evaluateAlert("123", reach(3000), "cfs")?.category, "Major");
    assert.equal(evaluateAlert("123", reach(3999), "cfs")?.category, "Major");
  });

  test("at and above the 25-year level is Extreme", () => {
    assert.equal(evaluateAlert("123", reach(4000), "cfs")?.category, "Extreme");
    assert.equal(evaluateAlert("123", reach(500000), "cfs")?.category,
      "Extreme");
  });

  test("a 50-year exceedance is still Extreme, not a new category", () => {
    // The old behaviour reported returnPeriod "50-year", which the app has no
    // word for. The recurrence interval is still carried for the reader who
    // wants it; the CATEGORY is what the card would show.
    const withFifty: unknown[] = [{
      return_period_2: cms(1000),
      return_period_5: cms(2000),
      return_period_10: cms(3000),
      return_period_25: cms(4000),
      return_period_50: cms(5000),
    }];
    const alert = evaluateAlert("123", reach(5000, withFifty), "cfs");
    assert.equal(alert?.returnPeriod, "50-year");
    assert.equal(alert?.category, "Extreme",
      "the app has no 50-year category; Extreme is the top of the ladder");
  });

  test("an incomplete ladder still alerts but cannot name a category", () => {
    // The alert path only needs ONE exceeded threshold; the category ladder
    // needs all four. Reporting "Unknown" is honest — inventing a category the
    // card could not produce is what guard 3 forbids.
    const partial: unknown[] = [{
      return_period_2: cms(1000),
      return_period_5: cms(2000),
    }];
    const alert = evaluateAlert("123", reach(2500, partial), "cfs");
    assert.notEqual(alert, null);
    assert.equal(alert?.category, "Unknown");
  });

  test("the category agrees with the app for every band", () => {
    // Walks the same flows through the shared classifier the app is pinned to.
    // If evaluateAlert ever computed its own ladder again, this diverges.
    for (const cfs of [1000, 1500, 2000, 2500, 3000, 3500, 4000, 9000]) {
      const alert = evaluateAlert("123", reach(cfs), "cfs");
      const direct = categoryFor(cfs * CFS_TO_CMS, {
        2: cms(1000), 5: cms(2000), 10: cms(3000), 25: cms(4000),
      });
      assert.equal(alert?.category, direct,
        `alert and shared classifier disagree at ${cfs} CFS`);
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// When the peak arrives. Added 2026-08-29 with the copy rewrite.
//
// The forecast points always carried a validTime and getMaxForecastFlow threw
// it away, so an alert could say how much water was coming but never when.
// That is the half a reader can act on: "in ~14 hours" decides whether you move
// the truck tonight; "147362 CFS" decides nothing.
//
// Relative, never absolute. No user timezone is stored anywhere, so "Saturday
// 4 PM" would be silently wrong for every user outside Mountain Time.

describe("timeToPeak", () => {
  const now = new Date("2026-08-29T12:00:00Z");

  test("rounds to whole hours", () => {
    assert.equal(timeToPeak("2026-08-30T02:00:00Z", now), "in ~14 hours");
    assert.equal(timeToPeak("2026-08-29T18:20:00Z", now), "in ~6 hours");
  });

  test("singular at one hour", () => {
    assert.equal(timeToPeak("2026-08-29T13:00:00Z", now), "in ~1 hour");
  });

  test("under an hour reads as within the hour", () => {
    assert.equal(timeToPeak("2026-08-29T12:20:00Z", now), "within the hour");
  });

  test("beyond two days switches to days", () => {
    assert.equal(timeToPeak("2026-09-01T12:00:00Z", now), "in ~3 days");
  });

  test("a peak already past is null, not a negative duration", () => {
    // Reachable: a stale forecast, or a peak that has passed while the flow
    // stayed high. "in ~-3 hours" would be worse than saying nothing.
    assert.equal(timeToPeak("2026-08-29T09:00:00Z", now), null);
    assert.equal(timeToPeak("2026-08-29T12:00:00Z", now), null);
  });

  test("a missing or unparseable time is null", () => {
    assert.equal(timeToPeak(null, now), null);
    assert.equal(timeToPeak("", now), null);
    assert.equal(timeToPeak("not a date", now), null);
  });
});

describe("evaluateAlert — the peak's time survives to the alert", () => {
  test("the alert carries the validTime of the PEAK point", () => {
    const data: ReachData = {
      forecast: {
        shortRange: {
          values: [
            {value: 1200, validTime: "2026-08-29T12:00:00Z"},
            {value: 4500, validTime: "2026-08-30T02:00:00Z"},
            {value: 1300, validTime: "2026-08-30T06:00:00Z"},
          ],
        },
        mediumRange: null,
      },
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
    const alert = evaluateAlert("123", data, "cfs");
    assert.equal(alert?.peakAt, "2026-08-30T02:00:00Z",
      "the time carried must belong to the highest point, not the first");
    assert.equal(alert?.forecastFlow, 4500);
  });

  test("the peak may come from the MEDIUM range", () => {
    const data: ReachData = {
      forecast: {
        shortRange: {
          values: [{value: 1200, validTime: "2026-08-29T12:00:00Z"}],
        },
        mediumRange: {
          values: [{value: 4500, validTime: "2026-09-02T00:00:00Z"}],
        },
      },
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
    assert.equal(evaluateAlert("123", data, "cfs")?.peakAt,
      "2026-09-02T00:00:00Z");
  });

  test("NOAA's no-data sentinel never becomes the peak", () => {
    const data: ReachData = {
      forecast: {
        shortRange: {
          values: [
            {value: -9999, validTime: "2026-08-29T12:00:00Z"},
            {value: 1200, validTime: "2026-08-30T02:00:00Z"},
          ],
        },
        mediumRange: null,
      },
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
    const alert = evaluateAlert("123", data, "cfs");
    assert.equal(alert?.forecastFlow, 1200);
    assert.equal(alert?.peakAt, "2026-08-30T02:00:00Z");
  });

  test("a peak point with no time yields a null peakAt, not a crash", () => {
    const data: ReachData = {
      forecast: {
        shortRange: {values: [{value: 4500, validTime: ""}]},
        mediumRange: null,
      },
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
    assert.equal(evaluateAlert("123", data, "cfs")?.peakAt, null);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// The name a notification calls a river.
//
// Custom names live only in device SharedPreferences, so until 2026-08-30 an
// alert used NOAA's official name even for a river the user had renamed — and
// that name is the first thing read on a lock screen. `favoriteLabels` already
// existed for the weekly digest; alerts now read it too.
//
// The key carries the SOURCE. Keyed by reach alone — as it was — an NWM comid
// and a GEOGLOWS linkno that are numerically equal share one slot and one
// river's label silently overwrites the other's. Both id spaces are plain
// integers with no coordination, so that is a matter of time.

describe("labelFor — the user's own name for a river", () => {
  test("a label under the source-carrying key wins", () => {
    const labels = {"nwm:18471070": "The fishing spot"};
    assert.equal(labelFor(labels, "nwm", "18471070", "White River"),
      "The fishing spot");
  });

  test("two networks sharing a reach id keep separate labels", () => {
    // The collision the old key could not express.
    const labels = {
      "nwm:12345": "Provo, upstream",
      "geoglows:12345": "Rio Napo",
    };
    assert.equal(labelFor(labels, "nwm", "12345", "x"), "Provo, upstream");
    assert.equal(labelFor(labels, "geoglows", "12345", "y"), "Rio Napo");
  });

  test("labels written before the source key are still read", () => {
    // Not migrated: the next rename or Weekly Outlook visit writes the new
    // key. Dropping them would blank a user's names on upgrade.
    assert.equal(labelFor({"18471070": "Old label"}, "nwm", "18471070", "x"),
      "Old label");
  });

  test("the new key wins over a stale legacy entry", () => {
    const labels = {"18471070": "Stale", "nwm:18471070": "Current"};
    assert.equal(labelFor(labels, "nwm", "18471070", "x"), "Current");
  });

  test("no label, an empty one, or no map at all falls back", () => {
    assert.equal(labelFor({}, "nwm", "1", "White River"), "White River");
    assert.equal(labelFor(undefined, "nwm", "1", "White River"), "White River");
    assert.equal(labelFor({"nwm:1": "   "}, "nwm", "1", "White River"),
      "White River");
  });
});

describe("the label key is a cross-language contract", () => {
  test("the Dart key format matches reachKey here", () => {
    // The app WRITES these keys and this file READS them. A format change on
    // either side does not throw — every label simply stops being found and
    // every notification silently reverts to the official name.
    const dart = readFileSync(
      resolve(__dirname, "..", "..",
        "lib/models/1_domain/shared/favorite_label_key.dart"), "utf8");
    assert.match(dart, /'\$\{source\.id\}:\$reachId'/,
      "favoriteLabelKey no longer produces `<source>:<reachId>`");
    assert.equal(reachKey("nwm", "18471070"), "nwm:18471070");
  });

  test("the Dart side also reads the legacy key", () => {
    const dart = readFileSync(
      resolve(__dirname, "..", "..",
        "lib/models/1_domain/shared/favorite_label_key.dart"), "utf8");
    assert.match(dart, /\?\? labels\[reachId\]/,
      "the app stopped reading pre-2026-08-30 labels, so a user's names " +
      "would disappear on upgrade");
  });
});
