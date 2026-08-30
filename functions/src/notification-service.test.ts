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

describe("an alert never announces a crest that already happened", () => {
  // The defect, carried forward from ADR 0011 Phase 8 and closed 2026-08-30.
  // `getMaxForecastFlow` took the maximum over the WHOLE series, past points
  // included — the same shape as the weekly digest bug found the same week,
  // and worse here, because this peak drives BOTH the flood category the
  // alert claims AND its "in ~14 hours" line.
  //
  // Concretely: a river that crested overnight and is now falling could wake
  // someone at the old crest's severity, describing a time already past.
  const NOW = new Date("2026-08-30T12:00:00Z");

  /**
   * A point n hours from NOW.
   * @param {number} h - Offset in hours, negative for the past.
   * @param {number} v - Flow value.
   * @return {object} A forecast point.
   */
  function p(h: number, v: number) {
    return {
      value: v,
      validTime: new Date(NOW.getTime() + h * 3600_000).toISOString(),
    };
  }

  /**
   * Reach data with one short-range series.
   * @param {Array<{value: number, validTime: string}>} values - The series.
   * @return {ReachData} The reach.
   */
  function reach(values: Array<{value: number; validTime: string}>): ReachData {
    return {
      forecast: {shortRange: {values}, mediumRange: null},
      returnPeriods: RETURN_PERIODS,
      riverName: "Test River",
    };
  }

  test("a crest 8 hours ago does not set the alert's flow", () => {
    // Crested at 9000 overnight, now receding through 1200.
    const alert = evaluateAlert(
      "123", reach([p(-8, 9000), p(-2, 3000), p(1, 1200), p(6, 1100)]),
      "cfs", NOW);

    assert.notEqual(alert?.forecastFlow, 9000,
      "the 9000 crest is in the past; alerting on it wakes someone about " +
      "water that has already gone by");
  });

  test("a crest still AHEAD is exactly what it should alert on", () => {
    // The other direction, which matters more: windowing must not swallow
    // the real signal. This is the whole purpose of the alert.
    const alert = evaluateAlert(
      "123", reach([p(-2, 1000), p(1, 1100), p(9, 9000)]), "cfs", NOW);

    assert.equal(alert?.forecastFlow, 9000);
    assert.equal(alert?.peakAt, p(9, 9000).validTime);
  });

  test("the anchor keeps the current reading, it is not a t >= now filter", () => {
    // Ported behaviour, and the distinction the third Phase 8 review caught
    // in the digest. The anchor is the point NEAREST now — normally the most
    // recent past reading, i.e. the current value. A `t >= now` filter drops
    // it, and with a 3-hourly series that is enough to change which crest is
    // reported.
    const alert = evaluateAlert(
      "123", reach([p(-1, 9000), p(2, 1000)]), "cfs", NOW);

    assert.equal(alert?.forecastFlow, 9000,
      "the reading one hour ago is the CURRENT value, not the past");
  });

  test("a wholly lapsed forecast still classifies rather than going Unknown", () => {
    // `upcomingFrom`'s fallback. A reach whose forecast has entirely expired
    // must still produce an assessment — silently returning Unknown would
    // stop an all-clear from ever being sent.
    const alert = evaluateAlert(
      "123", reach([p(-30, 9000), p(-26, 8000)]), "cfs", NOW);

    assert.notEqual(alert, undefined);
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
    // A FIXED `now`, not the wall clock. The peak is windowed to what is
    // still ahead, so without a seam this fixture's answer changes with the
    // date the suite happens to run — the exact failure that cost three
    // review rounds in Phase 8, three times in a row, each fix removing one
    // clock dependency and introducing another.
    const now = new Date("2026-08-29T10:00:00Z");
    const alert = evaluateAlert("123", data, "cfs", now);
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

  test("the app PRESERVES legacy entries when it writes", () => {
    // The app never reads these labels — it renders from the favourite's own
    // customName — so the legacy fallback lives here on the server. What the
    // app must do is not DROP the old entries when it writes a new one, or
    // this fallback would have nothing to fall back to.
    //
    // The behaviour itself is tested in Dart
    // (test/models/1_domain/shared/favorite_label_key_test.dart, "entries
    // under the OLD bare-reachId key are preserved"). This pins the merge that
    // makes it possible, from the side that depends on it.
    const dart = readFileSync(
      resolve(__dirname, "..", "..",
        "lib/models/1_domain/shared/favorite_label_key.dart"), "utf8");
    assert.match(dart, /\{\.\.\.existing, key: trimmed\}/,
      "labelsAfterRename stopped merging, so writing one label would drop " +
      "every pre-2026-08-30 entry and the fallback above would never fire");
  });
});
