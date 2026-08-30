// functions/src/digest-trend-parity.test.ts
//
// The weekly digest and the app must classify the same river the same way.
//
// **This is not hypothetical, and the comment claiming parity was the problem.**
// `trendOf` in weekly-digest.ts carries the note "identical rule to the
// client's computeFlowTrend", and it is — the threshold, the peak-anchoring
// and the ordering all match. The INPUTS did not: the client windows to points
// still ahead before computing anything, and the server used the whole stored
// series.
//
// Measured on 2026-08-30 across all seven of a real user's favourites: exactly
// one disagreed — White River (18471070), which the server called rising and
// the app called falling. That single river is the difference between the push
// notification saying "7 rivers, 6 rising" and the page it opens saying
// "5 rising · 2 steady/receding".
//
// The peak had the same flaw and it is the worse half: over the whole series
// the digest can announce a crest that has already happened.
//
// So this file pins the WINDOW, not the arithmetic. A rule can be identical on
// both sides and still disagree if it is fed different data — which is the
// shape of nearly every defect found in this project this week.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {upcomingFrom, buildRows} from "./weekly-digest.js";
import {reachKey} from "./notification-service.js";

const NOW = new Date("2026-08-30T12:00:00Z");

/**
 * A point at an hour offset from NOW.
 * @param {number} h - Hours from NOW (negative is past).
 * @param {number} v - Flow value.
 * @return {{value: number, validTime: string}} The point.
 */
function p(h: number, v: number) {
  return {
    value: v,
    validTime: new Date(NOW.getTime() + h * 3600_000).toISOString(),
  };
}

describe("the digest windows from the current reading, as the app does", () => {
  // ANCHOR semantics, not a `t >= now` filter. The third Phase 8 review caught
  // the first attempt at this: it dropped every past point, while
  // `ForecastPeak.upcomingPoints` anchors on the point NEAREST now — normally
  // the most recent past reading, i.e. the current value — and keeps
  // everything from there. On a 3-hourly series the two windows start one
  // point apart, enough to flip a river between rising and falling and to
  // change which crest is reported.
  test("the anchor is the nearest point, even when it is in the past", () => {
    // -1h is nearer to now than +2h, so it anchors and is KEPT.
    const out = upcomingFrom([p(-6, 500), p(-1, 400), p(2, 100)], NOW);
    assert.deepEqual(out.map((x) => x.value), [400, 100]);
  });

  test("points before the anchor are dropped", () => {
    const out = upcomingFrom([p(-9, 1), p(-6, 2), p(-1, 3), p(4, 4)], NOW);
    assert.deepEqual(out.map((x) => x.value), [3, 4]);
  });

  test("a point exactly at now anchors", () => {
    const out = upcomingFrom([p(-1, 9), p(0, 5), p(1, 6)], NOW);
    assert.deepEqual(out.map((x) => x.value), [5, 6]);
  });

  test("a future point can be the nearest one", () => {
    // -8h vs +1h: the future point is nearer, so it anchors.
    const out = upcomingFrom([p(-8, 7), p(1, 8), p(5, 9)], NOW);
    assert.deepEqual(out.map((x) => x.value), [8, 9]);
  });

  // Mirrors the client's `upcoming.isNotEmpty ? upcoming : points`. A reach
  // whose forecast has entirely lapsed must still produce a row rather than
  // disappear from the digest.
  test("an entirely lapsed series keeps its last reading", () => {
    // -4h is the nearest point, so it anchors; nothing precedes it in the
    // window. The row still exists rather than vanishing from the digest.
    const all = [p(-8, 3), p(-4, 2)];
    assert.deepEqual(upcomingFrom(all, NOW).map((x) => x.value), [2]);
  });

  test("an unparseable validTime is treated as not-ahead", () => {
    const out = upcomingFrom(
      [{value: 1, validTime: "not-a-date"}, p(3, 7)], NOW);
    assert.deepEqual(out.map((x) => x.value), [7]);
  });

  // THE regression, in the shape that produced it. A river that crested in the
  // recent past and is now easing: including the past makes the peak tower
  // over the first point and reads RISING; windowing forward reads FALLING.
  test("a river that already crested reads the same on both sides", () => {
    const series = [p(-6, 100), p(-3, 900), p(1, 300), p(6, 200), p(12, 150)];

    const wholeSeriesPeakBeatsFirst =
      Math.max(...series.map((x) => x.value)) > series[0].value * 1.05;
    assert.equal(wholeSeriesPeakBeatsFirst, true,
      "fixture must reproduce the bug: unwindowed, this reads rising");

    const ahead = upcomingFrom(series, NOW);
    const peak = Math.max(...ahead.map((x) => x.value));
    assert.equal(peak > ahead[0].value * 1.05, false,
      "windowed from the current reading it is not rising — the White River "
      + "case");
    assert.equal(ahead[ahead.length - 1].value < ahead[0].value * 0.95, true,
      "and it correctly reads falling");
  });

  // The worse half. The digest announces a peak and a day; over the whole
  // series both can be in the past.
  test("a crest well behind the current reading is not reported", () => {
    // +2h is nearer to now than -5h, so the 5000 crest is before the anchor.
    const ahead = upcomingFrom(
      [p(-5, 5000), p(2, 120), p(8, 300)], NOW);
    const peak = ahead.reduce((a, b) => (b.value > a.value ? b : a));
    assert.equal(peak.value, 300,
      "the 5000 crest is behind the anchor; announcing it would be wrong");
  });
});

// ── The WIRING, which the tests above cannot see ─────────────────────────────
//
// Mutation-checked and it mattered: reverting `buildRows` to feed the whole
// series left every test above green, because they exercise `upcomingFrom` in
// isolation and nothing proved the digest CALLS it. That is the same gap that
// produced every other defect found in this project this week — a correct
// function with a broken connection to it.
describe("buildRows actually windows before deriving", () => {
  const user = {
    userId: "u1",
    preferredFlowUnit: "cfs" as const,
    favoriteReachIds: ["18471070"],
    favoriteSources: {"18471070": "nwm"},
    favoriteLabels: {},
  };

  /** A reach whose crest is behind it — the White River shape. */
  function crestedReach() {
    return {
      riverName: "White River",
      returnPeriods: [],
      forecast: {
        mediumRange: {
          values: [
            p(-6, 100), p(-3, 900), p(1, 300), p(6, 200), p(12, 150),
          ].map((x) => ({value: x.value, validTime: x.validTime})),
        },
      },
    } as never;
  }

  test("a crested river is NOT reported as rising", () => {
    const map = new Map([[reachKey("nwm", "18471070"), crestedReach()]]);
    const rows = buildRows(user as never, map, NOW);

    assert.equal(rows.length, 1);
    assert.notEqual(rows[0].trend, "rising",
      "the crest is behind us; over the whole series this reads rising, " +
      "which is exactly why the notification said 6 rising while the page " +
      "said 5");
  });

  test("the peak reported has not already happened", () => {
    const map = new Map([[reachKey("nwm", "18471070"), crestedReach()]]);
    const rows = buildRows(user as never, map, NOW);

    assert.notEqual(rows[0].peakCfs, 900,
      "900 is the crest that already passed; announcing it as this week's " +
      "peak is the worse half of the same bug");
    assert.equal(rows[0].peakCfs, 300);
  });
});
