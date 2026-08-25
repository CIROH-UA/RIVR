// functions/src/store-upstream.test.ts
//
// Round 2 found this module untested, and F2 in it: the server fetched NOAA's
// `analysis_assimilation` series and stored it under the analysisAssimilation
// key, while the CLIENT stores a `short_range` body under that same key and
// reads it with ForecastValues.currentFlow — which only ever looks at
// short/medium/long range. Every stored AA document would have decoded to a
// null flow on all three surfaces that read it. The store present, running,
// and delivering nothing.
//
// So the series mapping is now pinned against the Dart source, not just
// asserted here.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  CAN_FETCH,
  SECTION_BY_PRODUCT,
  SERIES_BY_PRODUCT,
  canFetch,
  canonicalUnit,
} from "./store-upstream.js";
import {PRODUCTS_BY_SOURCE} from "./store-run.js";

const REPO = resolve(__dirname, "..", "..") + "/";

describe("units are canonicalised, never guessed", () => {
  test("NOAA's cubic-feet spellings all become CFS", () => {
    for (const u of ["ft3/s", "ft³/s", "CFS", "cfs", " ft3/s "]) {
      assert.equal(canonicalUnit(u), "CFS", `${u} should be CFS`);
    }
  });

  test("cubic-metre spellings become CMS", () => {
    for (const u of ["m3/s", "m³/s", "CMS", "cms"]) {
      assert.equal(canonicalUnit(u), "CMS", `${u} should be CMS`);
    }
  });

  // buildStoreDocument refuses a document with no unit, which fails the reach
  // and retries it. Defaulting would store a number whose meaning nobody knows
  // and the client would convert it wrongly, silently.
  test("an absent or unrecognised unit is null, not a default", () => {
    for (const u of [undefined, null, "", "   ", "furlongs/fortnight", 42]) {
      assert.equal(canonicalUnit(u), null, `${String(u)} should be null`);
    }
  });
});

describe("only fetchable work is advertised as fetchable", () => {
  // Round 2, F3: planning work upstream cannot serve guaranteed a failure per
  // reach per run — two per NWM favourite, and every GEOGLOWS favourite
  // produced nothing at all while reporting a failure.
  test("CAN_FETCH is a subset of PRODUCTS_BY_SOURCE", () => {
    for (const source of ["nwm", "geoglows"] as const) {
      for (const p of CAN_FETCH[source]) {
        assert.ok(PRODUCTS_BY_SOURCE[source].includes(p),
          `${source}/${p} is fetchable but not a product of that source`);
      }
    }
  });

  // This test previously asserted GEOGLOWS was UNfetchable, on the belief that
  // the proxy returned only the median. That belief was wrong —
  // functions_geoglows/main.py returns flow_uncertainty_lower and
  // flow_uncertainty_upper too — and the test was pinning the mistake in
  // place. GEOGLOWS is fetched by store-geoglows.ts on its own daily schedule.
  test("GEOGLOWS is fetchable, on its own daily path", () => {
    assert.deepEqual(CAN_FETCH.geoglows, ["geoglowsForecast"]);
    assert.equal(canFetch("geoglows", "geoglowsForecast"), true);
  });

  test("the NWM fetcher refuses GEOGLOWS rather than half-serving it", () => {
    // Routing is fetchForStore's job; store-upstream must not quietly try.
    assert.equal(canFetch("nwm", "geoglowsForecast"), false);
  });

  test("the near-static products are not on the hourly cycle", () => {
    assert.equal(canFetch("nwm", "returnPeriods"), false);
    assert.equal(canFetch("nwm", "reachMetadata"), false);
  });

  test("the four hourly NWM products are fetchable", () => {
    for (const p of
      ["analysisAssimilation", "shortRange", "mediumRange", "longRange"] as
      const) {
      assert.equal(canFetch("nwm", p), true);
    }
  });
});

describe("the Dart contract has not drifted", () => {
  // THE F2 PIN. The three tests below prove Dart still behaves a certain way;
  // this one proves THIS FILE matches it. Without it, reverting the mapping to
  // "analysis_assimilation" passed every test — the mutation survived when
  // this file was first written, which is exactly the fake-guard shape the
  // review gate hunts.
  test("analysisAssimilation is fetched as short_range, like the client", () => {
    assert.equal(SERIES_BY_PRODUCT.analysisAssimilation, "short_range",
      "the client stores a short_range body under this key; fetching " +
      "analysis_assimilation stores something ForecastValues.currentFlow " +
      "never reads, so every surface shows no flow");
    assert.equal(SECTION_BY_PRODUCT.analysisAssimilation, "shortRange",
      "the run identity must come from the shortRange section, as " +
      "NwmDataSource does");
  });

  test("every other product maps to its own series and section", () => {
    for (const p of ["shortRange", "mediumRange", "longRange"] as const) {
      assert.equal(SECTION_BY_PRODUCT[p], p);
    }
    assert.equal(SERIES_BY_PRODUCT.shortRange, "short_range");
    assert.equal(SERIES_BY_PRODUCT.mediumRange, "medium_range");
    assert.equal(SERIES_BY_PRODUCT.longRange, "long_range");
  });

  // F2, pinned. If the client ever stops deriving current flow from the short
  // range series, this file's mapping becomes wrong again — and the symptom is
  // a null flow on screen, with nothing wrong server-side.
  test("the client still derives analysisAssimilation from short_range", () => {
    const src = readFileSync(
      REPO + "lib/services/4_infrastructure/river_data/nwm_data_source.dart",
      "utf8");
    // lastIndexOf, not indexOf: the FIRST occurrence is in validUntil's
    // switch, which says nothing about which series is fetched. Getting this
    // wrong made the test read the wrong branch entirely.
    const idx = src.lastIndexOf("case ForecastProduct.analysisAssimilation:");
    assert.notEqual(idx, -1, "the AA branch is gone from NwmDataSource");
    const branch = src.slice(idx, idx + 700);

    assert.match(branch, /fetchCurrentFlowOnly/,
      "AA no longer goes through fetchCurrentFlowOnly");
    assert.match(branch, /_runIdOf\(aaPayload, 'shortRange'\)/,
      "AA's run identity no longer comes from the shortRange section — the " +
      "server's SECTION_BY_PRODUCT mapping must follow");
  });

  test("fetchCurrentFlowOnly still means short_range", () => {
    const src = readFileSync(
      REPO + "lib/services/4_infrastructure/api/noaa_api_service.dart", "utf8");
    const idx = src.indexOf("fetchCurrentFlowOnly");
    assert.notEqual(idx, -1);
    assert.match(src.slice(idx, idx + 500), /'short_range'/,
      "fetchCurrentFlowOnly no longer fetches short_range; the server would " +
      "store a body the client cannot decode");
  });

  // Scoped to currentFlow's own series list. The file mentions
  // 'analysis_assimilation' elsewhere (an availability list), so a whole-file
  // match would have been a false positive — and was, first time round.
  test("ForecastValues.currentFlow still ignores analysis_assimilation", () => {
    const src = readFileSync(
      REPO + "lib/services/4_infrastructure/forecast/forecast_values.dart",
      "utf8");
    const idx = src.indexOf("static double? currentFlow(");
    assert.notEqual(idx, -1, "currentFlow is gone from ForecastValues");
    // Fixed window rather than a closing-brace sentinel: "\n  }" matches the
    // end of the PARAMETER block first, truncating the slice before the series
    // list it is supposed to inspect.
    const body = src.slice(idx, idx + 600);

    assert.match(body, /'short_range'/);
    assert.doesNotMatch(body, /'analysis_assimilation'/,
      "if currentFlow learns to read analysis_assimilation, the server may " +
      "store that series again — until then it must not");
  });
});
