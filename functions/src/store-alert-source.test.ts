// functions/src/store-alert-source.test.ts
//
// ADR 0011 Phase 6 guard 1: "Alerts issue ZERO upstream fetches."
//
// The mapping from stored documents to the alert path's `ReachData` is where
// that guard is won or lost, and the units are the part that fails silently.
// `evaluateAlert` expects the FORECAST in CFS and the THRESHOLDS in CMS — an
// asymmetry inherited from geoglows-client.ts — so a mapper that passes stored
// values straight through is wrong for GEOGLOWS, whose forecast is stored in
// CMS. Getting it wrong by a factor of 35 does not throw: it reports a flood
// that is not happening, or misses one that is.
//
// The fixtures are the real stored shapes, read out of production Firestore on
// 2026-08-29 rather than invented.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  ALERT_PRODUCTS,
  StoredDoc,
  reachDataFromStore,
} from "./store-alert-source.js";
import {ForecastProductId} from "./store-keys.js";
import {evaluateAlert} from "./notification-service.js";

const CMS_TO_CFS = 35.3147;

/**
 * Assemble a document map the way readAlertDataFromStore does.
 * @param {Array<[ForecastProductId, string, Record<string, unknown>]>} rows -
 *   Product, unit and payload for each document.
 * @return {Map<ForecastProductId, StoredDoc>} The map.
 */
function docs(
  rows: Array<[ForecastProductId, string, Record<string, unknown>]>
): Map<ForecastProductId, StoredDoc> {
  const m = new Map<ForecastProductId, StoredDoc>();
  for (const [product, unit, payload] of rows) {
    m.set(product, {product, unit, payload});
  }
  return m;
}

/** The NWM short-range shape: payload.shortRange.series.data[]. */
function nwmShort(points: Array<[string, number]>): Record<string, unknown> {
  return {
    shortRange: {
      series: {data: points.map(([validTime, flow]) => ({validTime, flow}))},
    },
  };
}

/** The NWM medium-range shape: payload.mediumRange.mean.data[]. */
function nwmMedium(points: Array<[string, number]>): Record<string, unknown> {
  return {
    mediumRange: {
      mean: {data: points.map(([validTime, flow]) => ({validTime, flow}))},
    },
  };
}

/** The stored return-period shape: an array of one row, CMS. */
const NWM_RETURN_PERIODS = {
  returnPeriods: [{
    feature_id: 18471070,
    return_period_2: 2626.0,
    return_period_5: 3930.4,
    return_period_10: 4793.5,
    return_period_25: 5884.4,
    return_period_50: 6693.5,
    return_period_100: 7496.7,
  }],
};

describe("guard 1 — the alert path reads only these products", () => {
  test("NWM needs forecast, thresholds and a name", () => {
    assert.deepEqual([...ALERT_PRODUCTS.nwm].sort(),
      ["mediumRange", "reachMetadata", "returnPeriods", "shortRange"]);
  });

  test("GEOGLOWS needs only its one product", () => {
    assert.deepEqual([...ALERT_PRODUCTS.geoglows], ["geoglowsForecast"]);
  });
});

describe("NWM documents map to the alert's shape", () => {
  test("the short-range series becomes forecast values, CFS untouched", () => {
    const d = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([
        ["2026-08-29T04:00:00Z", 16702.1],
        ["2026-08-29T05:00:00Z", 16864.2],
      ])],
    ]));
    assert.deepEqual(d?.forecast?.shortRange?.values, [
      {value: 16702.1, validTime: "2026-08-29T04:00:00Z"},
      {value: 16864.2, validTime: "2026-08-29T05:00:00Z"},
    ]);
  });

  test("the medium range comes from the MEAN series", () => {
    const d = reachDataFromStore("nwm", "18471070", docs([
      ["mediumRange", "CFS", nwmMedium([["2026-08-30T00:00:00Z", 200]])],
    ]));
    assert.equal(d?.forecast?.mediumRange?.values.length, 1);
    assert.equal(d?.forecast?.mediumRange?.values[0].value, 200);
  });

  test("the stored return periods pass through as the parser expects", () => {
    const d = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([["2026-08-29T04:00:00Z", 100]])],
      ["returnPeriods", "CMS", NWM_RETURN_PERIODS],
    ]));
    assert.equal((d?.returnPeriods as unknown[]).length, 1);
    const row = (d?.returnPeriods as Array<Record<string, number>>)[0];
    assert.equal(row.return_period_2, 2626.0);
  });

  test("the river name comes from the stored metadata", () => {
    const d = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([["2026-08-29T04:00:00Z", 100]])],
      ["reachMetadata", "CFS", {riverName: "White River"}],
    ]));
    assert.equal(d?.riverName, "White River");
  });

  test("a missing or blank name falls back, it does not blank the title", () => {
    // The notification title LEADS with this string, so an empty one is worse
    // than a dull one.
    const withoutMeta = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([["2026-08-29T04:00:00Z", 100]])],
    ]));
    assert.equal(withoutMeta?.riverName, "Reach 18471070");

    const blank = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([["2026-08-29T04:00:00Z", 100]])],
      ["reachMetadata", "CFS", {riverName: "   "}],
    ]));
    assert.equal(blank?.riverName, "Reach 18471070");
  });

  test("a reach with no forecast at all is refused, not half-built", () => {
    assert.equal(
      reachDataFromStore("nwm", "18471070", docs([
        ["returnPeriods", "CMS", NWM_RETURN_PERIODS],
      ])),
      null);
    assert.equal(reachDataFromStore("nwm", "18471070", docs([])), null);
  });

  test("an NWM forecast stored in CMS is CONVERTED, not passed through", () => {
    // Does not happen today — NWM stores CFS — but the unit is read rather
    // than assumed, and a factor-of-35 error here would invent or hide a flood
    // without throwing.
    const d = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CMS", nwmShort([["2026-08-29T04:00:00Z", 100]])],
    ]));
    assert.equal(d?.forecast?.shortRange?.values[0].value, 100 * CMS_TO_CFS);
  });

  test("points with no usable flow are dropped, not passed on as NaN", () => {
    const d = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", {
        shortRange: {
          series: {
            data: [
              {validTime: "2026-08-29T04:00:00Z", flow: "not a number"},
              {validTime: "2026-08-29T05:00:00Z", flow: 500},
              {validTime: "2026-08-29T06:00:00Z"},
            ],
          },
        },
      }],
    ]));
    assert.equal(d?.forecast?.shortRange?.values.length, 1);
    assert.equal(d?.forecast?.shortRange?.values[0].value, 500);
  });
});

describe("GEOGLOWS documents map to the alert's shape", () => {
  /** The stored GEOGLOWS shape: points[{t, median}], returnPeriods map, CMS. */
  const GEOGLOWS_PAYLOAD = {
    riverId: 620569308,
    generatedAt: "2026-08-29T00:00:00.000Z",
    points: [
      {t: "2026-08-29T00:00:00Z", median: 1.0, lower: 0.8, upper: 1.4},
      {t: "2026-08-29T03:00:00Z", median: 3.5, lower: 2.9, upper: 4.2},
    ],
    returnPeriods: {2: 2.0, 5: 3.0, 10: 4.0, 25: 5.0, 50: 6.0, 100: 7.0},
  };

  test("the median series is CONVERTED from CMS to CFS", () => {
    // The one that matters. evaluateAlert multiplies the forecast by 0.0283168
    // to get CMS for the comparison, so handing it CMS understates the flow by
    // a factor of 35 and every GEOGLOWS alert silently stops firing.
    const d = reachDataFromStore("geoglows", "620569308",
      docs([["geoglowsForecast", "CMS", GEOGLOWS_PAYLOAD]]));
    assert.equal(d?.forecast?.shortRange?.values[0].value, 1.0 * CMS_TO_CFS);
    assert.equal(d?.forecast?.shortRange?.values[1].value, 3.5 * CMS_TO_CFS);
  });

  test("the median is surfaced as shortRange so the peak is found", () => {
    const d = reachDataFromStore("geoglows", "620569308",
      docs([["geoglowsForecast", "CMS", GEOGLOWS_PAYLOAD]]));
    assert.notEqual(d?.forecast?.shortRange, null);
    assert.equal(d?.forecast?.mediumRange, null);
  });

  test("thresholds are rebuilt into the parser's dialect, still CMS", () => {
    const d = reachDataFromStore("geoglows", "620569308",
      docs([["geoglowsForecast", "CMS", GEOGLOWS_PAYLOAD]]));
    const row = (d?.returnPeriods as Array<Record<string, number>>)[0];
    assert.equal(row.return_period_2, 2.0);
    assert.equal(row.return_period_25, 5.0);
    assert.equal(row.return_period_100, 7.0);
  });

  test("unnamed GEOGLOWS reaches keep the Stream <id> fallback", () => {
    const d = reachDataFromStore("geoglows", "620569308",
      docs([["geoglowsForecast", "CMS", GEOGLOWS_PAYLOAD]]));
    assert.equal(d?.riverName, "Stream 620569308");
  });

  test("a document with no points is refused", () => {
    assert.equal(
      reachDataFromStore("geoglows", "620569308",
        docs([["geoglowsForecast", "CMS", {points: []}]])),
      null);
    assert.equal(reachDataFromStore("geoglows", "620569308", docs([])), null);
  });
});

describe("end to end: a stored reach evaluates the way it should", () => {
  test("a stored NWM flood produces the category the app would show", () => {
    // 6000 CMS is above the 25-year threshold (5884.4 CMS) and below the
    // 50-year. The app calls everything at or above the 25-year level Extreme.
    const cfs = 6000 / 0.0283168;
    const data = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([["2026-08-30T02:00:00Z", cfs]])],
      ["returnPeriods", "CMS", NWM_RETURN_PERIODS],
      ["reachMetadata", "CFS", {riverName: "White River"}],
    ]))!;

    const alert = evaluateAlert("18471070", data, "cfs");
    assert.equal(alert?.category, "Extreme");
    assert.equal(alert?.riverName, "White River");
    assert.equal(alert?.peakAt, "2026-08-30T02:00:00Z");
  });

  test("a stored GEOGLOWS flood evaluates on the CONVERTED flow", () => {
    // Median 6 CMS against a 25-year threshold of 5 CMS. Only correct if the
    // mapper converted to CFS: evaluateAlert converts back, and passing CMS
    // through would compare 6 * 0.0283 = 0.17 against 5 and report nothing.
    const payload = {
      points: [{t: "2026-08-30T00:00:00Z", median: 6.0}],
      returnPeriods: {2: 2.0, 5: 3.0, 10: 4.0, 25: 5.0},
    };
    const data = reachDataFromStore("geoglows", "620569308",
      docs([["geoglowsForecast", "CMS", payload]]))!;

    const alert = evaluateAlert("620569308", data, "cms");
    assert.notEqual(alert, null,
      "a GEOGLOWS flood evaluated to nothing — the CMS/CFS conversion is the " +
      "only way this silently returns null");
    assert.equal(alert?.category, "Extreme");
  });

  test("a quiet stored reach produces no alert", () => {
    const data = reachDataFromStore("nwm", "18471070", docs([
      ["shortRange", "CFS", nwmShort([["2026-08-30T02:00:00Z", 500]])],
      ["returnPeriods", "CMS", NWM_RETURN_PERIODS],
    ]))!;
    assert.equal(evaluateAlert("18471070", data, "cfs"), null);
  });
});
