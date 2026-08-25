// functions/src/store-geoglows.test.ts
//
// ADR 0011 Phase 4: "GEOGLOWS on its own daily schedule, keyed on
// forecast_date."
//
// The uncertainty band is the reason this file exists. An earlier pass
// excluded GEOGLOWS from the store on the belief that the proxy returned only
// the median — it does not; functions_geoglows/main.py returns
// flow_uncertainty_lower and flow_uncertainty_upper alongside it. The band
// reaching the stored document is therefore the first thing asserted, and it
// is pinned against the Python source so the belief cannot silently become
// true later.
//
// The second thing these tests defend is subtler: the client decodes with
// `conv(p['median'] as num)` on all three values. A null in ANY of them throws
// inside GeoglowsForecastPayload.decode and loses the WHOLE forecast, not just
// that step — so an incomplete step must be dropped, never emitted with nulls.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  GEOGLOWS_NATIVE_UNIT,
  buildGeoglowsPayload,
  normaliseForecastDate,
} from "./store-geoglows.js";
import {CAN_FETCH, canFetch} from "./store-upstream.js";

const REPO = resolve(__dirname, "..", "..") + "/";

/** A proxy response shaped as functions_geoglows/main.py builds it. */
function proxyBody(over: Record<string, unknown> = {}) {
  return {
    river_id: 760021642,
    forecast_date: "2026-08-24",
    units: "m3/s",
    source: "GEOGLOWS RFS v2",
    forecast: {
      datetime: ["2026-08-24T00:00:00Z", "2026-08-25T00:00:00Z"],
      flow_median: [10.5, 11.5],
      flow_uncertainty_lower: [8.0, 9.0],
      flow_uncertainty_upper: [13.0, 14.0],
    },
    return_periods: {"2": 100.0, "5": 200.0, "25": 400.0},
    ...over,
  };
}

describe("the uncertainty band reaches the stored document", () => {
  test("every step carries median, lower AND upper", () => {
    const p = buildGeoglowsPayload(proxyBody(), "760021642");

    assert.equal(p.points.length, 2);
    assert.deepEqual(p.points[0],
      {t: "2026-08-24T00:00:00Z", median: 10.5, lower: 8.0, upper: 13.0});
    assert.deepEqual(p.points[1],
      {t: "2026-08-25T00:00:00Z", median: 11.5, lower: 9.0, upper: 14.0});
  });

  test("the band is not collapsed onto the median", () => {
    const p = buildGeoglowsPayload(proxyBody(), "760021642");
    for (const pt of p.points) {
      assert.ok(pt.lower < pt.median && pt.median < pt.upper,
        "lower/upper must be the real band, not copies of the median");
    }
  });

  test("the payload matches what the client's encode() writes", () => {
    const p = buildGeoglowsPayload(proxyBody(), "760021642");
    assert.deepEqual(Object.keys(p).sort(),
      ["generatedAt", "points", "returnPeriods", "riverId"]);
    assert.deepEqual(Object.keys(p.points[0]).sort(),
      ["lower", "median", "t", "upper"]);
  });

  test("riverId is a string — the client casts it as one", () => {
    const p = buildGeoglowsPayload(proxyBody(), "760021642");
    assert.equal(typeof p.riverId, "string");
    assert.equal(p.riverId, "760021642");
  });

  test("return periods keep string keys and numeric values", () => {
    const p = buildGeoglowsPayload(proxyBody(), "760021642");
    assert.deepEqual(p.returnPeriods, {"2": 100.0, "5": 200.0, "25": 400.0});
  });

  test("absent return periods are null, not an empty object", () => {
    // decode() treats null as "none published"; {} would parse to an empty map
    // and claim thresholds exist.
    const p = buildGeoglowsPayload(
      proxyBody({return_periods: {}}), "760021642");
    assert.equal(p.returnPeriods, null);
  });
});

describe("an incomplete step is dropped, never nulled", () => {
  // The client does conv(p['median'] as num) on all three. A null throws and
  // loses the entire forecast — so one bad step must not cost the series.
  test("a step missing its lower band is skipped, the rest survive", () => {
    const p = buildGeoglowsPayload(proxyBody({
      forecast: {
        datetime: ["2026-08-24T00:00:00Z", "2026-08-25T00:00:00Z"],
        flow_median: [10.5, 11.5],
        flow_uncertainty_lower: [null, 9.0],
        flow_uncertainty_upper: [13.0, 14.0],
      },
    }), "760021642");

    assert.equal(p.points.length, 1);
    assert.equal(p.points[0].t, "2026-08-25T00:00:00Z");
  });

  test("no emitted point ever carries a null or NaN", () => {
    const p = buildGeoglowsPayload(proxyBody({
      forecast: {
        datetime: ["a", "b", "c"],
        flow_median: [1, null, NaN],
        flow_uncertainty_lower: [0.5, 1, 1],
        flow_uncertainty_upper: [2, 2, 2],
      },
    }), "760021642");

    for (const pt of p.points) {
      for (const v of [pt.median, pt.lower, pt.upper]) {
        assert.equal(typeof v, "number");
        assert.ok(Number.isFinite(v));
      }
    }
    assert.equal(p.points.length, 1);
  });

  // A 200 with nothing usable is a failure, not an empty forecast to store
  // over good data — the same rule the NWM fetcher applies.
  test("a response with no complete step throws rather than storing empty",
    () => {
      assert.throws(() => buildGeoglowsPayload(proxyBody({
        forecast: {
          datetime: ["2026-08-24T00:00:00Z"],
          flow_median: [null],
          flow_uncertainty_lower: [null],
          flow_uncertainty_upper: [null],
        },
      }), "760021642"), /no complete forecast steps/);
    });

  test("a missing forecast object throws", () => {
    assert.throws(() => buildGeoglowsPayload({}, "760021642"));
  });
});

describe("the run identity is the forecast date, never invented", () => {
  test("a date-only forecast_date widens to that day's 00Z", () => {
    assert.equal(normaliseForecastDate("2026-08-24"),
      "2026-08-24T00:00:00.000Z");
  });

  test("a full timestamp is preserved as an instant", () => {
    assert.equal(normaliseForecastDate("2026-08-24T06:30:00Z"),
      "2026-08-24T06:30:00.000Z");
  });

  // GeoglowsDataSource refuses to mint a run from wall-clock time, because
  // every refetch would then look like a new run for identical data. The
  // server must refuse for the same reason.
  test("an absent or unparseable date throws instead of using wall-clock",
    () => {
      for (const bad of [undefined, null, "", "   ", "not-a-date"]) {
        assert.throws(() => normaliseForecastDate(bad),
          `${String(bad)} should not yield a run identity`);
      }
    });

  test("the run identity IS the forecast date", () => {
    const p = buildGeoglowsPayload(proxyBody(), "760021642");
    assert.equal(p.generatedAt, "2026-08-24T00:00:00.000Z");
  });
});

describe("GEOGLOWS is wired into the store, not excluded", () => {
  test("geoglowsForecast is fetchable", () => {
    assert.deepEqual(CAN_FETCH.geoglows, ["geoglowsForecast"]);
    assert.equal(canFetch("geoglows", "geoglowsForecast"), true);
  });

  test("the stored unit is GEOGLOWS' native m3/s, not a user preference", () => {
    assert.equal(GEOGLOWS_NATIVE_UNIT, "CMS");
  });
});

describe("the Python contract has not drifted", () => {
  // The belief that the proxy returned only the median is what nearly dropped
  // the band. Pinned here so it cannot quietly become true.
  test("the proxy still returns both uncertainty columns", () => {
    const src = readFileSync(REPO + "functions_geoglows/main.py", "utf8");
    for (const col of
      ["flow_median", "flow_uncertainty_lower", "flow_uncertainty_upper"]) {
      assert.ok(src.includes(`"${col}"`),
        `functions_geoglows/main.py no longer returns ${col} — the stored ` +
        "GEOGLOWS chart would lose its band");
    }
  });

  test("the proxy still publishes m3/s and a forecast_date", () => {
    const src = readFileSync(REPO + "functions_geoglows/main.py", "utf8");
    assert.match(src, /UNITS = "m3\/s"/,
      "the native unit changed; GEOGLOWS_NATIVE_UNIT must follow");
    assert.ok(src.includes("\"forecast_date\""),
      "forecast_date is the run identity; without it nothing can be stored");
  });

  test("the client still decodes t/median/lower/upper", () => {
    const src = readFileSync(
      REPO +
      "lib/services/4_infrastructure/river_data/geoglows_forecast_payload.dart",
      "utf8");
    for (const field of ["'t'", "'median'", "'lower'", "'upper'",
      "'riverId'", "'generatedAt'", "'points'", "'returnPeriods'"]) {
      assert.ok(src.includes(field),
        `GeoglowsForecastPayload no longer uses ${field}`);
    }
  });
});
