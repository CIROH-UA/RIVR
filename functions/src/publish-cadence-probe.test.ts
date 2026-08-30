// functions/src/publish-cadence-probe.test.ts
//
// Guards for ADR 0011 Phase 0's instrumentation.
//
// Two defects these exist for, both found by review rather than by writing:
//
//  1. NOAA returns HTTP 200 with an empty series during partial outages —
//     observed live on 2026-08-22. v1 counted that as healthy, which would have
//     undercounted the failure rate on exactly the series the ADR cares about.
//
//  2. v1 sampled only the unfiltered response, the heaviest thing the API
//     returns, so it measured the worst case rather than what the app depends
//     on. It also read `referenceTime` only from that response — the one with
//     the worst observed success rate.
//
// Tests marked REGRESSION fail against the version that shipped before them.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {
  PROBE_RETENTION_MS,
  buildEndpointResult,
  buildSample,
  referenceTimeOf,
  ENDPOINTS,
  SERIES,
  PROBE_SCHEMA_VERSION,
  EndpointResult,
} from "./publish-cadence-probe.js";
import {FORECAST_PRODUCTS} from "./store-keys.js";
import {PROBE_KEY_BY_PRODUCT} from "./store-trigger.js";

function filteredBody(series: string, ref: string): string {
  return JSON.stringify({[series]: {series: {referenceTime: ref}}});
}

function unfilteredBody(): string {
  return JSON.stringify({
    currentFlow: {series: {referenceTime: "2026-08-22T14:00:00Z"}},
    shortRange: {series: {referenceTime: "2026-08-22T13:00:00Z"}},
    mediumRange: {mean: {referenceTime: "2026-08-22T12:00:00Z"}},
    longRange: {mean: {referenceTime: "2026-08-22T06:00:00Z"}},
    mediumRangeBlend: {series: {referenceTime: "2026-08-22T12:00:00Z"}},
  });
}

function ok(seriesKey: string | null, body: string): EndpointResult {
  return buildEndpointResult({
    seriesKey,
    httpStatus: 200,
    body,
    elapsedMs: 100,
    error: null,
  });
}

describe("referenceTimeOf", () => {
  test("finds it however deeply the series nests it", () => {
    const j = JSON.parse(unfilteredBody());
    assert.equal(referenceTimeOf(j.shortRange), "2026-08-22T13:00:00Z");
    assert.equal(referenceTimeOf(j.mediumRange), "2026-08-22T12:00:00Z");
  });

  test("absent or empty is null, not a throw", () => {
    assert.equal(referenceTimeOf(undefined), null);
    assert.equal(referenceTimeOf({}), null);
  });

  test("distinct values are preserved, not silently reduced", () => {
    assert.equal(referenceTimeOf({a: {referenceTime: "B"}, b: {referenceTime: "A"}}), "A|B");
  });
});

describe("buildEndpointResult — REGRESSION: 200-but-empty is not healthy", () => {
  test("a filtered 200 with no referenceTime is a failure", () => {
    const r = ok("shortRange", JSON.stringify({shortRange: {}}));
    assert.equal(r.ok, false, "empty series must not read as healthy");
    assert.equal(r.httpStatus, 200, "status retained for diagnosis");
    assert.match(r.error ?? "", /series empty/);
  });

  test("a filtered 200 with data is healthy and carries the run", () => {
    const r = ok("shortRange", filteredBody("shortRange", "2026-08-22T13:00:00Z"));
    assert.equal(r.ok, true);
    assert.equal(r.referenceTime, "2026-08-22T13:00:00Z");
    assert.equal(r.error, null);
  });
});

describe("buildEndpointResult — failures are data points, never throws", () => {
  test("504 recorded, not thrown", () => {
    const r = buildEndpointResult({
      seriesKey: "shortRange",
      httpStatus: 504,
      body: "<html>gateway timeout</html>",
      elapsedMs: 60367,
      error: null,
    });
    assert.equal(r.ok, false);
    assert.equal(r.error, "HTTP 504");
    assert.equal(r.elapsedMs, 60367);
  });

  test("HTML on a 200 is a parse failure, distinguishable from a 5xx", () => {
    const r = ok("shortRange", "<html>nope</html>");
    assert.equal(r.ok, false);
    assert.equal(r.httpStatus, 200);
    assert.doesNotMatch(r.error ?? "", /^HTTP /);
  });

  test("a transport error is recorded with no status", () => {
    const r = buildEndpointResult({
      seriesKey: "shortRange",
      httpStatus: null,
      body: null,
      elapsedMs: 120000,
      error: "The operation was aborted",
    });
    assert.equal(r.ok, false);
    assert.equal(r.httpStatus, null);
    assert.equal(r.bytes, null);
  });
});

describe("buildSample — REGRESSION: freshness survives an unfiltered failure", () => {
  // v1 read referenceTime only from the unfiltered response, which measured
  // 8/10 against 10/10 for the small filtered calls. A failure there lost the
  // freshness signal entirely.
  test("referenceTimes come from the filtered calls, not from unfiltered", () => {
    const endpoints: Record<string, EndpointResult> = {
      analysis_assimilation: ok("currentFlow",
        filteredBody("currentFlow", "2026-08-22T14:00:00Z")),
      short_range: ok("shortRange", filteredBody("shortRange", "2026-08-22T13:00:00Z")),
      medium_range: ok("mediumRange", filteredBody("mediumRange", "2026-08-22T12:00:00Z")),
      long_range: ok("longRange", filteredBody("longRange", "2026-08-22T06:00:00Z")),
      // The heavy one dies, as it did in 2 of 10 measured rounds.
      unfiltered: buildEndpointResult({
        seriesKey: null, httpStatus: 504, body: "x", elapsedMs: 60000, error: null,
      }),
    };
    const s = buildSample(endpoints);

    assert.equal(s.okCount, 4);
    assert.equal(s.referenceTimes.shortRange, "2026-08-22T13:00:00Z",
      "the freshness signal must survive the unfiltered failure");
    assert.equal(s.referenceTimes.mediumRange, "2026-08-22T12:00:00Z");
    assert.equal(s.unfilteredAgrees, null,
      "nothing to compare against — null, not false");
  });

  test("every configured endpoint appears in the sample", () => {
    const endpoints: Record<string, EndpointResult> = {};
    for (const e of ENDPOINTS) {
      endpoints[e.name] = ok(e.key, e.key === null ? unfilteredBody() :
        filteredBody(e.key, "2026-08-22T12:00:00Z"));
    }
    const s = buildSample(endpoints);
    assert.deepEqual(
      Object.keys(s.endpoints).sort(),
      ENDPOINTS.map((e) => e.name).sort()
    );
    assert.equal(s.okCount, ENDPOINTS.length);
  });

  test("the document is schema-versioned so analysis cannot mix v1 and v2", () => {
    const s = buildSample({});
    assert.equal(s.schemaVersion, PROBE_SCHEMA_VERSION);
    assert.ok(PROBE_SCHEMA_VERSION >= 2);
  });
});

describe("buildSample — the unfiltered cross-check", () => {
  test("agreement is reported when both sources match", () => {
    const endpoints: Record<string, EndpointResult> = {
      analysis_assimilation: ok("currentFlow",
        filteredBody("currentFlow", "2026-08-22T14:00:00Z")),
      short_range: ok("shortRange", filteredBody("shortRange", "2026-08-22T13:00:00Z")),
      medium_range: ok("mediumRange", filteredBody("mediumRange", "2026-08-22T12:00:00Z")),
      long_range: ok("longRange", filteredBody("longRange", "2026-08-22T06:00:00Z")),
      unfiltered: ok(null, unfilteredBody()),
    };
    assert.equal(buildSample(endpoints).unfilteredAgrees, true);
  });

  // An API that reports two different runs for one series is a real signal
  // about upstream, and must be visible rather than averaged away.
  test("disagreement is reported, not hidden", () => {
    const endpoints: Record<string, EndpointResult> = {
      analysis_assimilation: ok("currentFlow",
        filteredBody("currentFlow", "2026-08-22T14:00:00Z")),
      short_range: ok("shortRange",
        filteredBody("shortRange", "2026-08-22T99:00:00Z")), // differs
      medium_range: ok("mediumRange", filteredBody("mediumRange", "2026-08-22T12:00:00Z")),
      long_range: ok("longRange", filteredBody("longRange", "2026-08-22T06:00:00Z")),
      unfiltered: ok(null, unfilteredBody()),
    };
    assert.equal(buildSample(endpoints).unfilteredAgrees, false);
  });
});

// The probe log was the only collection in this project that grew without
// bound — one document an hour, never overwritten, never swept — until a TTL
// was put on it 2026-08-29. A TTL policy deletes when its field is in the past,
// so pointing one at `sampledAt` would have deleted every sample the moment it
// was written. That mistake is silent and total, hence these.

describe("probe samples carry their own expiry", () => {
  test("expiresAt is in the FUTURE, unlike sampledAt", () => {
    const sample = buildSample({});
    assert.ok(sample.expiresAt.toMillis() > Date.now(),
      "expiresAt must be ahead of now or the TTL deletes on write");
    assert.ok(sample.sampledAt.toMillis() <= Date.now());
  });

  test("expiry is exactly the retention window past the sample", () => {
    const sample = buildSample({});
    assert.equal(
      sample.expiresAt.toMillis() - sample.sampledAt.toMillis(),
      PROBE_RETENTION_MS);
  });

  test("retention comfortably clears the seven days guard 1 needs", () => {
    assert.ok(PROBE_RETENTION_MS > 7 * 24 * 3600_000);
    assert.equal(PROBE_RETENTION_MS, 90 * 24 * 3600_000);
  });
});

describe("NOAA's section names are not our product ids", () => {
  // Phase 9 renamed the store product `analysisAssimilation` to `currentFlow`,
  // because it fetches the short-range series and the old name had caused
  // three separate defects. The rename was done with a blanket
  // search-and-replace across `functions/src`, which also rewrote THIS file —
  // where `analysisAssimilation` is NOAA'S OWN section name, verified against
  // a live response on 2026-08-30:
  //
  //   ["reach", "analysisAssimilation", "shortRange", "mediumRange",
  //    "longRange", "mediumRangeBlend"]
  //
  // The probe would then have looked for a section NOAA never sends and
  // recorded nothing for that endpoint, silently, in the very component whose
  // job is measuring publication cadence. Caught by reading the diff.
  //
  // These assertions exist so the next rename cannot do it quietly.
  test("the probe reads NOAA's analysisAssimilation section", () => {
    const aa = ENDPOINTS.find((e) => e.series === "analysis_assimilation");
    assert.notEqual(aa, undefined);
    assert.equal(aa!.key, "analysisAssimilation",
      "this is NOAA's section name for its REAL analysis-assimilation " +
      "series, not our product id. Renaming it makes the probe look for a " +
      "key that is never sent.");
    assert.ok((SERIES as readonly string[]).includes("analysisAssimilation"),
      "the unfiltered cross-check reads the same NOAA section names");
  });

  test("no product id is called analysisAssimilation any more", () => {
    // The other half: if the product name ever comes back, the collision that
    // caused rounds 2 and 3 and the 2026-08-30 island regression comes back
    // with it.
    //
    // **Honest note: this assertion is belt-and-braces, not load-bearing.**
    // Mutation-checked by renaming the union member back, which produces 24
    // TypeScript errors — the type system refuses it before any test runs. A
    // mutation that does not compile proves nothing about the test, so a
    // later reader should not treat this as the thing holding the line. It is
    // kept because it states the INTENT, which the compiler cannot.
    assert.ok(!(FORECAST_PRODUCTS as readonly string[])
      .includes("analysisAssimilation"),
    "the store product was renamed to `currentFlow` because it fetches the " +
      "short-range series while NOAA uses this name for a genuinely " +
      "different one");
    assert.ok((FORECAST_PRODUCTS as readonly string[]).includes("currentFlow"));
  });

  test("the probe key and the product id are deliberately different", () => {
    // `probeRunFor` falls back to using the product id AS the probe key when
    // no mapping exists. That fallback is why the two names have to stay
    // distinguishable: with the old shared name, a missing mapping silently
    // compared a short-range document against an analysis-assimilation run —
    // round 3, B3, where the product stopped triggering after its first write.
    assert.equal(PROBE_KEY_BY_PRODUCT.currentFlow, "shortRange",
      "currentFlow holds a short-range body, so it must be compared against " +
      "the short-range probe run");
  });
});
