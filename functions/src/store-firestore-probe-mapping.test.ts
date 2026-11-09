// functions/src/store-firestore-probe-mapping.test.ts
//
// The mapping from a `publish_cadence_log` document to the ProbeRuns the
// hourly run decides on.
//
// WHY IT IS ITS OWN FILE. A 2026-11-09 mutation sweep found three mutations
// of this mapping that the entire 488-test suite missed: marking every
// endpoint as answered, marking none of them, and dropping `answered` from
// the result altogether. Each one changes what the store decides to fetch,
// and none could be caught while the logic sat inside `readLatestProbe`,
// which talks to Firestore and therefore cannot be unit-driven.
//
// `answered` is what tells a lost section lottery from an upstream outage.
// Get it stuck on false and `mediumRange` goes back to freezing overnight
// (item 6). Get it stuck on true and every probe outage becomes an hourly
// fan-out across every reach, which is what the null-probe guard exists to
// prevent. Both failures are silent.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {probeRunsFromDocument} from "./store-firestore.js";

/** A Firestore-ish timestamp. */
const stamp = (iso: string) => ({toDate: () => new Date(iso)});

describe("probeRunsFromDocument", () => {
  test("a 200 carrying no run reads as ANSWERED", () => {
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {mediumRange: null},
      endpoints: {medium_range: {ok: false, httpStatus: 200}},
    });

    assert.equal(p?.answered?.mediumRange, true,
      "upstream was reachable and simply had nothing: this is the lottery, " +
      "and it is the case that must still be retried");
    assert.equal(p?.referenceTimes.mediumRange, null);
  });

  test("a timeout reads as NOT answered", () => {
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {mediumRange: null},
      endpoints: {medium_range: {ok: false, httpStatus: null}},
    });

    assert.equal(p?.answered?.mediumRange, false,
      "an outage must not be retried through: that is the fan-out the " +
      "null-probe guard was written to prevent");
  });

  test("a 503 reads as NOT answered", () => {
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {},
      endpoints: {medium_range: {ok: false, httpStatus: 503}},
    });

    assert.equal(p?.answered?.mediumRange, false);
  });

  test("the probe's own ok flag is enough on its own", () => {
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {shortRange: "2026-11-09T03:00:00Z"},
      endpoints: {short_range: {ok: true}},
    });

    assert.equal(p?.answered?.shortRange, true);
  });

  test("endpoint NAMES are crossed to section KEYS, not copied", () => {
    // The probe stores `medium_range`; the runs are keyed `mediumRange`.
    // Copying the keys across would leave every lookup undefined, which
    // defaults to "did not answer" and silently restores the defect.
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {},
      endpoints: {
        analysis_assimilation: {httpStatus: 200},
        short_range: {httpStatus: 200},
        medium_range: {httpStatus: 200},
        long_range: {httpStatus: 200},
      },
    });

    assert.deepEqual(p?.answered, {
      analysisAssimilation: true,
      shortRange: true,
      mediumRange: true,
      longRange: true,
    }, "section keys, and the unfiltered endpoint is not one of them");
  });

  test("a missing endpoints map reads as nothing answered", () => {
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {mediumRange: null},
    });

    assert.equal(p?.answered?.mediumRange, false,
      "ninety days of historical samples have no endpoints crossed in; " +
      "absent must stay conservative rather than enabling blind retries");
  });

  test("a document with no usable sampledAt is refused", () => {
    assert.equal(probeRunsFromDocument({referenceTimes: {}}), null);
    assert.equal(
      probeRunsFromDocument({sampledAt: "2026-11-09", referenceTimes: {}}),
      null,
      "a string where a Timestamp belongs is a schema change, not a date");
  });

  test("referenceTimes survive the mapping unchanged", () => {
    const p = probeRunsFromDocument({
      sampledAt: stamp("2026-11-09T04:00:00.000Z"),
      referenceTimes: {
        shortRange: "2026-11-09T03:00:00Z",
        mediumRange: null,
      },
    });

    assert.deepEqual(p?.referenceTimes, {
      shortRange: "2026-11-09T03:00:00Z",
      mediumRange: null,
    });
  });
});
