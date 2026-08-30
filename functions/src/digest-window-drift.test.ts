// functions/src/digest-window-drift.test.ts
//
// The digest's window and the app's must stay the same rule.
//
// **This file exists because a comment claiming they matched was wrong twice.**
// `weekly-digest.ts` first computed trend and peak over the WHOLE stored
// series; that was fixed to filter `t >= now` and described as "exactly as the
// client does". It was not. `ForecastPeak.upcomingPoints` ANCHORS on the point
// nearest now — normally the most recent past reading, the current value — and
// keeps everything from there. Filtering `t >= now` drops that anchor, so on a
// 3-hourly series the two windows start one point apart, which is enough to
// flip a river between rising and falling and to change which crest is
// reported as the peak.
//
// The other cross-language contracts in this project (the flood ladder, the
// hold caps) are pinned by reading the Dart source. This one was not, which is
// why the second version shipped with the same claim and a different bug.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

const REPO = resolve(__dirname, "..", "..") + "/";
const DART = REPO + "lib/utils/forecast_peak.dart";

/**
 * Strip Dart comments before matching.
 *
 * Round 4 defeated this guard with a stale comment: the anchoring code was
 * replaced by a plain `t >= now` filter while a leftover comment still said
 * `difference(ref).abs()`, and every assertion passed. A guard that reads
 * prose as though it were code is worse than none, because it reports
 * agreement that does not exist.
 *
 * @param {string} src - Dart source.
 * @return {string} The same source with comments removed.
 */
function stripDartComments(src: string): string {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "")
    .replace(/\/\/.*$/gm, "");
}

/** `upcomingPoints`, as it exists in the Dart source right now. */
function dartUpcomingPoints(): string {
  const src = readFileSync(DART, "utf8");
  const start = src.indexOf("static List<({double flow, DateTime time})> " +
    "upcomingPoints(");
  assert.notEqual(start, -1,
    "ForecastPeak.upcomingPoints is gone or renamed — the digest's window is " +
    "a port of it, so this test must follow it rather than quietly passing");
  // NOT indexOf("\n  }"): the parameter list ends with `\n  }) {`, so that
  // matched inside the signature and handed every assertion below just the
  // declaration — which is why this test failed against correct code the first
  // time it ran. The same trap caught store-health-wiring.test.ts.
  const after = src.indexOf("\n  ///", start);
  return stripDartComments(
    src.slice(start, after === -1 ? src.length : after));
}

describe("the digest's window is still a port of the app's", () => {
  test("the app still ANCHORS on the nearest point", () => {
    const dart = dartUpcomingPoints();

    assert.match(dart, /difference\(ref\)\.abs\(\)/,
      "the app no longer anchors by distance from now. Whatever it does " +
      "instead, `upcomingFrom` in weekly-digest.ts must be changed to match — " +
      "it is a hand port, and the last two times these drifted the digest " +
      "and the page it opens reported different numbers for the same river.");

    assert.match(dart, /if \(!p\.time\.isBefore\(anchor\)\)/,
      "the app no longer keeps everything from the anchor onward");
  });

  // Round 4 escaped this guard three ways. Two are pinned here; the third
  // (an inverted tie-break) needs a millisecond-exact tie and is unreachable
  // from a real forecast series, so it is recorded rather than guarded.
  test("the anchor is chosen from ALL points, not just future ones", () => {
    const dart = dartUpcomingPoints();

    // The whole point of anchoring is that the anchor is normally the most
    // recent PAST reading — the current value. Restricting the candidate set
    // to future points silently turns this back into the `t >= now` filter
    // that shipped as the second wrong version.
    assert.ok(!/for \(final p in list\)[\s\S]{0,120}?isAfter\(ref\)/.test(dart),
      "the anchor search appears to skip past points; that is the `t >= now` " +
      "filter wearing anchoring's clothes, and `upcomingFrom` would need the " +
      "same change");

    assert.match(dart, /for \(final p in list\)/,
      "the anchor is chosen by scanning every point");
  });

  test("the tie-break is still STRICTLY less-than", () => {
    const dart = dartUpcomingPoints();
    // Two points equidistant from now must keep the FIRST. `upcomingFrom`
    // relies on this: it seeds with Infinity and uses `<`, which is only
    // equivalent while Dart stays strict.
    assert.match(dart, /if \(d < anchorDiff\)/,
      "the tie-break changed; upcomingFrom's `<` no longer matches");
  });

  test("the app has NOT switched to a plain future-only filter", () => {
    const dart = dartUpcomingPoints();

    // If it ever does, `upcomingFrom` should become the same filter — and the
    // simpler rule the digest wrongly had the first time would become correct.
    assert.ok(!/isBefore\(ref\)/.test(dart),
      "the app appears to filter against `now` directly now; align " +
      "upcomingFrom and simplify it");
  });

  test("the digest names the file it was ported from", () => {
    // So the next person changing one finds the other.
    const digest = readFileSync(
      resolve(__dirname, "..", "src", "weekly-digest.ts"), "utf8");
    assert.match(digest, /forecast_peak\.dart/,
      "upcomingFrom must point at its source of truth by path");
  });
});
