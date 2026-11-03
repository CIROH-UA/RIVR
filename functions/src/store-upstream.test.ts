// functions/src/store-upstream.test.ts
//
// Round 2 found this module untested, and F2 in it: the server fetched NOAA's
// `analysis_assimilation` series and stored it under the currentFlow
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
  EMPTY_SECTION_ATTEMPTS,
  SERIES_BY_PRODUCT,
  canFetch,
  canonicalUnit,
  fetchProductFromUpstream,
} from "./store-upstream.js";
import {SECTION_BY_PRODUCT} from "./store-keys.js";
import {PRODUCTS_BY_SOURCE} from "./store-run.js";
import {MANAGED_PRODUCTS, STATIC_PRODUCTS} from "./store-service.js";

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
    assert.equal(canFetch("geoglows", "geoglowsForecast", "23021904"), true);
  });

  test("the NWM fetcher refuses GEOGLOWS rather than half-serving it", () => {
    // Routing is fetchForStore's job; store-upstream must not quietly try.
    assert.equal(canFetch("nwm", "geoglowsForecast", "23021904"), false);
  });

  // This test previously asserted these two were NOT fetchable at all, which
  // pinned the defect Phase 5 review round 1 found (B3): with them missing
  // from the store, guard 1 — "a favourite renders with ZERO upstream calls
  // from the device" — was unreachable, because every surface that renders a
  // favourite reads the river's name and its flood thresholds. They are now
  // fetchable. What must stay true is the part the old test's NAME described:
  // they do not belong on the HOURLY cycle.
  test("the near-static products are fetchable", () => {
    assert.equal(canFetch("nwm", "returnPeriods", "23021904"), true);
    assert.equal(canFetch("nwm", "reachMetadata", "23021904"), true);
  });

  test("the near-static products are NOT on the hourly cycle", () => {
    // They carry no run identity, so the probe has nothing to compare and
    // decideTriggers could never fire them; and they hold a 30-day window, so
    // hourly refetching would re-read an unchanging river name 24x a day per
    // favourite. The daily static pass owns them instead.
    for (const p of ["returnPeriods", "reachMetadata"] as const) {
      assert.ok(!MANAGED_PRODUCTS.includes(p),
        `${p} must not be on the hourly cycle`);
      assert.ok(STATIC_PRODUCTS.includes(p),
        `${p} must be owned by the daily static pass`);
    }
  });

  // Guard 1 holds only if the app subscribes to exactly what the server
  // writes. Drift either way fails silently: a listener that can never fire,
  // or a document written and never delivered.
  test("CAN_FETCH.nwm matches the app's kStoredProducts", () => {
    const src = readFileSync(
      REPO +
      "lib/services/4_infrastructure/river_data/store_subscription_service.dart",
      "utf8");
    const block = src.slice(
      src.indexOf("ForecastSource.nwm: ["),
      src.indexOf("ForecastSource.geoglows: ["));
    assert.ok(block.length > 0, "could not locate the NWM block");

    const watched = new Set(
      [...block.matchAll(/ForecastProduct\.(\w+)/g)].map((m) => m[1]));
    assert.deepEqual([...watched].sort(), [...CAN_FETCH.nwm].sort(),
      "the app watches a different NWM product set than the server writes");
  });

  test("the four hourly NWM products are fetchable for a CONUS reach", () => {
    for (const p of
      ["currentFlow", "shortRange", "mediumRange", "longRange"] as
      const) {
      assert.equal(canFetch("nwm", p, "23021904"), true);
    }
  });

  // Phase 9 review, finding 6. The phase MEASURED that NWPS reports only
  // `["analysis_assimilation", "short_range"]` for Oahu reach 800000010, and
  // that NOMADS has no medium_range_hawaii or long_range_puertorico directory
  // at all — then acted on it only by omitting island entries from the
  // hold-cap tables. Every other part of the system still believed these
  // products exist everywhere.
  //
  // Untreated, the first Honolulu or San Juan favourite puts two products per
  // reach into permanent per-cycle fetch failure: `reachesToRetry` never
  // empties, and the app offers forecast ranges NOAA cannot serve. Round 2's
  // F3 was this same defect for a whole source — planning work that cannot be
  // served guarantees a failure per reach per run.
  test("islands have NO medium or long range", () => {
    for (const p of ["mediumRange", "longRange"] as const) {
      assert.equal(canFetch("nwm", p, "800000010"), false,
        `${p} does not exist for Hawaii or Puerto Rico; planning it is a ` +
        "guaranteed failure every cycle, forever");
    }
  });

  test("islands DO have current flow, short range and the static pair", () => {
    // The other direction, and the one that would break a real user: an
    // over-broad exclusion leaves an island favourite with nothing at all.
    for (const p of
      ["currentFlow", "shortRange", "returnPeriods", "reachMetadata"] as
      const) {
      assert.equal(canFetch("nwm", p, "800000010"), true, `${p}`);
    }
  });

  test("the exclusion is by DOMAIN, not by product", () => {
    // Stated as a difference so a blanket removal of mediumRange cannot pass.
    assert.notEqual(
      canFetch("nwm", "mediumRange", "23021904"),
      canFetch("nwm", "mediumRange", "800000010"),
      "medium range exists for CONUS and not for the islands; one answer " +
      "for both is wrong whichever answer it is");
  });
});

describe("the Dart contract has not drifted", () => {
  // THE F2 PIN. The three tests below prove Dart still behaves a certain way;
  // this one proves THIS FILE matches it. Without it, reverting the mapping to
  // "analysis_assimilation" passed every test — the mutation survived when
  // this file was first written, which is exactly the fake-guard shape the
  // review gate hunts.
  test("currentFlow is fetched as short_range, like the client", () => {
    assert.equal(SERIES_BY_PRODUCT.currentFlow, "short_range",
      "the client stores a short_range body under this key; fetching " +
      "analysis_assimilation stores something ForecastValues.currentFlow " +
      "never reads, so every surface shows no flow");
    assert.equal(SECTION_BY_PRODUCT.currentFlow, "shortRange",
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
  test("the client still derives currentFlow from short_range", () => {
    const src = readFileSync(
      REPO + "lib/services/4_infrastructure/river_data/nwm_data_source.dart",
      "utf8");
    // lastIndexOf, not indexOf: the FIRST occurrence is in validUntil's
    // switch, which says nothing about which series is fetched. Getting this
    // wrong made the test read the wrong branch entirely.
    const idx = src.lastIndexOf("case ForecastProduct.currentFlow:");
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

// ─────────────────────────────────────────────────────────────────────────────
// The empty-section retry, added 2026-11-03 (ADR 0017 audit).
//
// CLAUDE.md says the store's fetchers never retry, and that rule still holds
// everywhere else in this file. This is the one measured exception: NOAA
// answers 200 for `medium_range` and `long_range` with the section simply
// absent, roughly nine times in ten, and "retried next cycle" never arrives
// because the cycle is an hour and the window is narrower. Six weeks of
// expired documents came out of that.
//
// `globalThis.fetch` is stubbed rather than the module faked, so these
// exercise the real loop in fetchProductFromUpstream.
// ─────────────────────────────────────────────────────────────────────────────

describe("an empty NOAA section is retried, and only that", () => {
  const realFetch = globalThis.fetch;

  /** A NOAA body with every section present, the named one filled or not. */
  function body(section: string, filled: boolean): string {
    const sections: Record<string, unknown> = {
      analysisAssimilation: {}, shortRange: {}, mediumRange: {},
      longRange: {}, mediumRangeBlend: {},
    };
    sections[section] = filled ?
      {
        series: {
          units: "ft3/s",
          referenceTime: "2026-11-03T06:00:00Z",
          data: [{validTime: "2026-11-03T07:00:00Z", flow: 12.5}],
        },
      } :
      {};
    return JSON.stringify(sections);
  }

  /** Replaces fetch with one that answers empty N times, then full. */
  function stubFetch(emptyTimes: number, section: string): () => number {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      const filled = calls > emptyTimes;
      return new Response(body(section, filled), {status: 200});
    }) as typeof fetch;
    return () => calls;
  }

  test("it succeeds on a later attempt instead of giving up at the first",
    async () => {
      const calls = stubFetch(3, "mediumRange");
      try {
        const got = await fetchProductFromUpstream(
          "nwm", "10092062", "mediumRange");
        assert.equal(calls(), 4,
          "three empties then a full one: the old code stopped at the first " +
          "and wrote nothing for six weeks");
        assert.equal(got.referenceTime, "2026-11-03T06:00:00Z");
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  test("it gives up after the budget and says how many times it asked",
    async () => {
      const calls = stubFetch(Number.MAX_SAFE_INTEGER, "longRange");
      try {
        await assert.rejects(
          () => fetchProductFromUpstream("nwm", "10092062", "longRange"),
          (e: Error) => {
            assert.equal(e.name, "EmptySectionError",
              "the run's circuit breaker matches on this name; rename it " +
              "and the breaker silently stops working");
            assert.match(e.message, /after 6 attempts/);
            return true;
          },
        );
        assert.equal(calls(), EMPTY_SECTION_ATTEMPTS);
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  test("a section that is there first time costs exactly one request",
    async () => {
      const calls = stubFetch(0, "shortRange");
      try {
        await fetchProductFromUpstream("nwm", "10092062", "shortRange");
        assert.equal(calls(), 1,
          "the retry must not cost anything when upstream is behaving");
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  test("an HTTP error is NOT retried — the old rule still holds there",
    async () => {
      let calls = 0;
      globalThis.fetch = (async () => {
        calls++;
        return new Response("nope", {status: 504});
      }) as typeof fetch;
      try {
        await assert.rejects(
          () => fetchProductFromUpstream("nwm", "10092062", "mediumRange"));
        assert.equal(calls, 1,
          "hammering something already failing is what CLAUDE.md forbids, " +
          "and this change does not relax it");
      } finally {
        globalThis.fetch = realFetch;
      }
    });
});
