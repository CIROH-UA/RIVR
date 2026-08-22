// functions/src/publish-cadence-probe.test.ts
//
// Guards for ADR 0011 Phase 0's instrumentation.
//
// The defect these exist for: NOAA returns HTTP 200 with `mediumRange: {}`
// during partial outages — observed live on 2026-08-22. The first version of
// this probe set `ok = true` whenever the body parsed, so a run missing the
// series the ADR cares most about would have been logged as healthy and
// silently undercounted the failure rate.
//
// The tests marked "REGRESSION" fail against that earlier version and pass
// against this one. That distinction is the whole point — a guard that also
// passes against the broken code proves nothing, and this repo has shipped two
// of those.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {buildSample, referenceTimeOf, SERIES} from "./publish-cadence-probe.js";

/** Mirrors the real payload shape: referenceTime nests differently per series. */
function healthyBody(): string {
  return JSON.stringify({
    analysisAssimilation: {series: {referenceTime: "2026-08-22T05:00:00Z"}},
    shortRange: {series: {referenceTime: "2026-08-22T07:00:00Z"}},
    mediumRange: {
      mean: {referenceTime: "2026-08-22T00:00:00Z", data: []},
      member1: {referenceTime: "2026-08-22T00:00:00Z", data: []},
    },
    longRange: {mean: {referenceTime: "2026-08-22T00:00:00Z", data: []}},
    mediumRangeBlend: {series: {referenceTime: "2026-08-22T06:00:00Z"}},
  });
}

describe("referenceTimeOf", () => {
  test("finds it however deeply the series nests it", () => {
    const j = JSON.parse(healthyBody());
    assert.equal(referenceTimeOf(j.shortRange), "2026-08-22T07:00:00Z");
    assert.equal(referenceTimeOf(j.mediumRange), "2026-08-22T00:00:00Z");
  });

  test("an absent or empty series is null, not a throw", () => {
    assert.equal(referenceTimeOf(undefined), null);
    assert.equal(referenceTimeOf({}), null);
    assert.equal(referenceTimeOf(null), null);
  });

  // An internally inconsistent series is a real signal about upstream, so it
  // must survive into the data rather than being collapsed to the first value.
  test("distinct values are preserved, not silently reduced", () => {
    const mixed = {a: {referenceTime: "B"}, b: {referenceTime: "A"}};
    assert.equal(referenceTimeOf(mixed), "A|B");
  });
});

describe("buildSample — REGRESSION: healthy vs empty must be distinguishable", () => {
  // This is the defect. The old code set ok=true here and logged "cadence ok".
  test("HTTP 200 with an empty mediumRange is NOT complete", () => {
    const body = JSON.parse(healthyBody());
    body.mediumRange = {};
    const s = buildSample({
      httpStatus: 200,
      body: JSON.stringify(body),
      elapsedMs: 900,
      error: null,
    });

    assert.equal(s.ok, true, "it did parse — ok reflects that");
    assert.equal(s.complete, false, "but it is NOT complete");
    assert.equal(s.seriesPresent, SERIES.length - 1);
    assert.equal(s.referenceTimes.mediumRange, null);
    assert.match(s.error ?? "", /missing series: mediumRange/);
  });

  test("a fully healthy response is complete", () => {
    const s = buildSample({
      httpStatus: 200,
      body: healthyBody(),
      elapsedMs: 1200,
      error: null,
    });
    assert.equal(s.complete, true);
    assert.equal(s.seriesPresent, SERIES.length);
    assert.equal(s.error, null);
    assert.equal(s.referenceTimes.mediumRange, "2026-08-22T00:00:00Z");
  });

  test("every expected series is accounted for, including the blend", () => {
    const s = buildSample({
      httpStatus: 200,
      body: healthyBody(),
      elapsedMs: 10,
      error: null,
    });
    assert.deepEqual(Object.keys(s.referenceTimes).sort(), [...SERIES].sort());
  });
});

describe("buildSample — failures are data points, never throws", () => {
  test("a 504 is recorded, not thrown", () => {
    const s = buildSample({
      httpStatus: 504,
      body: "<html>gateway timeout</html>",
      elapsedMs: 60367,
      error: null,
    });
    assert.equal(s.ok, false);
    assert.equal(s.complete, false);
    assert.equal(s.error, "HTTP 504");
    assert.equal(s.elapsedMs, 60367);
  });

  // A proxy returning 200 with an HTML error page must not look like success.
  test("HTML on a 200 is a parse failure, distinguishable from a 5xx", () => {
    const s = buildSample({
      httpStatus: 200,
      body: "<html>nope</html>",
      elapsedMs: 500,
      error: null,
    });
    assert.equal(s.ok, false);
    assert.equal(s.httpStatus, 200, "status is retained for diagnosis");
    assert.ok((s.error ?? "").length > 0);
    assert.doesNotMatch(s.error ?? "", /^HTTP /);
  });

  test("a transport error (abort/timeout) is recorded with no status", () => {
    const s = buildSample({
      httpStatus: null,
      body: null,
      elapsedMs: 120000,
      error: "The operation was aborted",
    });
    assert.equal(s.ok, false);
    assert.equal(s.httpStatus, null);
    assert.equal(s.bytes, null);
    assert.equal(s.error, "The operation was aborted");
  });

  test("every branch yields all SERIES keys, so analysis never sees undefined", () => {
    for (const s of [
      buildSample({httpStatus: 504, body: "x", elapsedMs: 1, error: null}),
      buildSample({httpStatus: null, body: null, elapsedMs: 1, error: "boom"}),
      buildSample({httpStatus: 200, body: "{}", elapsedMs: 1, error: null}),
    ]) {
      assert.deepEqual(Object.keys(s.referenceTimes).sort(), [...SERIES].sort());
    }
  });
});
