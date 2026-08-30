// functions/src/store-document.test.ts
//
// ADR 0011 Phase 4, step 2. Three things are under test here and they fail in
// different ways:
//
//  1. The envelope. Phase 5 reads these documents through
//     `RiverDataEntry.fromJson`, so a renamed field decodes as null inside the
//     app and nothing server-side notices.
//  2. The publish schedule. If the server's validUntil disagrees with the
//     client's, the client either treats a just-written document as already
//     stale (refetching upstream, defeating the store) or as fresh past its
//     run (showing yesterday's water).
//  3. Supersession (guard 6). Two runs overlap whenever one is slow, and the
//     late one may be carrying the OLDER run. Without the check the store
//     flaps and a user watches the forecast move backwards.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  GEOGLOWS_SKEW_MS,
  ISLAND_COMID_MAX,
  ISLAND_COMID_MIN,
  ISLAND_SHORT_RANGE_CYCLE_HOURS,
  NWM_SKEW_MS,
  isIslandReach,
  STORE_SCHEMA_VERSION,
  StoreDocument,
  buildStoreDocument,
  documentIdFor,
  isRunNewer,
  nextCycle,
  nextTopOfHour,
  nextUtcMidnight,
  shouldWrite,
  validUntil,
} from "./store-document.js";

const REPO = resolve(__dirname, "..", "..") + "/";

const AT = new Date("2026-08-24T13:10:00.000Z");

function doc(over: Partial<Parameters<typeof buildStoreDocument>[0]> = {}) {
  return buildStoreDocument({
    source: "nwm",
    reachId: "23021904",
    product: "shortRange",
    payload: {series: {data: []}},
    unit: "CFS",
    referenceTime: "2026-08-24T12:00:00Z",
    fetchedAt: AT,
    ...over,
  });
}

describe("the envelope matches RiverDataEntry.toJson", () => {
  test("carries exactly the fields the client decodes", () => {
    const d = doc();
    assert.deepEqual(Object.keys(d).sort(), [
      "payload", "product", "reachId", "runId", "schema", "source", "unit",
      "window",
    ]);
    assert.deepEqual(Object.keys(d.window).sort(), ["fetchedAt", "validUntil"]);
  });

  test("the document ID is the client's cache key", () => {
    assert.equal(documentIdFor(doc()), "nwm__23021904__shortRange");
  });

  // Guard 10.
  test("every document carries the schema version", () => {
    assert.equal(doc().schema, STORE_SCHEMA_VERSION);
  });

  // Dart writes `if (runId != null)`, so an absent run must be absent, not
  // present-and-null. A null would decode as a string cast failure.
  test("runId is omitted entirely when the response carried none", () => {
    const d = doc({referenceTime: null});
    assert.equal("runId" in d, false);
  });

  test("timestamps are ISO-8601 UTC", () => {
    const d = doc();
    assert.equal(d.window.fetchedAt, "2026-08-24T13:10:00.000Z");
    assert.match(d.window.validUntil, /^\d{4}-\d{2}-\d{2}T.*Z$/);
  });

  // Decision 12. Two users with opposite unit settings favouriting one reach
  // must produce a byte-identical document (guard 5), which is only possible
  // if the unit stored is the upstream one.
  test("the unit is whatever the caller fetched in, verbatim", () => {
    assert.equal(doc({unit: "CMS"}).unit, "CMS");
  });

  test("a missing unit is refused rather than defaulted", () => {
    assert.throws(() => doc({unit: ""}));
    assert.throws(() => doc({unit: "   "}));
  });

  test("a non-object payload is refused", () => {
    // @ts-expect-error deliberately wrong shape
    assert.throws(() => doc({payload: [1, 2, 3]}));
    // @ts-expect-error deliberately wrong shape
    assert.throws(() => doc({payload: null}));
  });

  test("a bad reach id is refused before anything is written", () => {
    assert.throws(() => doc({reachId: ""}));
    assert.throws(() => doc({reachId: "12__34"}));
  });
});

describe("the publish schedule mirrors the client's", () => {
  // Literal instants, not `... + NWM_SKEW_MS`. Asserting against the same
  // constant the implementation uses is tautological — it holds for any value,
  // which is how a wrong GEOGLOWS skew passed review-free until round 1.
  test("hourly products round up to the next hour, plus the NWM skew", () => {
    assert.equal(validUntil("nwm", "shortRange", AT, "23021904").toISOString(),
      "2026-08-24T14:05:00.000Z");
  });

  test("6-hourly products round up to 00/06/12/18Z, plus the NWM skew", () => {
    // 13:10 -> 18:00.
    assert.equal(validUntil("nwm", "mediumRange", AT, "23021904").toISOString(),
      "2026-08-24T18:05:00.000Z");
  });

  // GEOGLOWS skews by 15 minutes, not NWM's 5 — a different physical reason
  // (00Z proxy cold start). Sharing one constant made every GEOGLOWS document
  // expire 10 minutes before the client expected, so the client refetched
  // upstream on every read and the store did nothing.
  test("GEOGLOWS rounds up to the next UTC midnight, plus the GEOGLOWS skew",
    () => {
      assert.equal(validUntil("geoglows", "geoglowsForecast", AT, "23021904").toISOString(),
        "2026-08-25T00:15:00.000Z");
    });

  test("the two sources do NOT share a skew", () => {
    assert.notEqual(NWM_SKEW_MS, GEOGLOWS_SKEW_MS,
      "collapsing these is the defect round 1 found");
  });

  // "Next" is strictly after now — a value fetched exactly on a boundary is
  // valid until the FOLLOWING one, or it would be born stale.
  test("a value fetched exactly on a boundary lives to the next one", () => {
    const onHour = new Date("2026-08-24T12:00:00Z");
    assert.equal(nextTopOfHour(onHour).toISOString(),
      "2026-08-24T13:00:00.000Z");
    assert.equal(nextCycle(new Date("2026-08-24T18:00:00Z"), 6).toISOString(),
      "2026-08-25T00:00:00.000Z");
    assert.equal(
      nextUtcMidnight(new Date("2026-08-24T00:00:00Z")).toISOString(),
      "2026-08-25T00:00:00.000Z");
  });

  test("static products get a long window, not a publish boundary", () => {
    for (const p of ["returnPeriods", "reachMetadata"] as const) {
      const days =
        (validUntil("nwm", p, AT, "23021904").getTime() - AT.getTime()) / 86400_000;
      assert.equal(days, 30);
    }
  });

  test("a product a source does not serve throws", () => {
    assert.throws(() => validUntil("nwm", "geoglowsForecast", AT, "23021904"));
    assert.throws(() => validUntil("geoglows", "shortRange", AT, "23021904"));
  });

  test("nextCycle refuses a cycle that does not divide 24", () => {
    assert.throws(() => nextCycle(AT, 7));
    assert.throws(() => nextCycle(AT, 0));
  });
});

describe("supersession — overlapping runs cannot write backwards", () => {
  const base = doc({referenceTime: "2026-08-24T12:00:00Z"});
  const newer = doc({referenceTime: "2026-08-24T18:00:00Z"});
  const older = doc({referenceTime: "2026-08-24T06:00:00Z"});

  test("no existing document is always written", () => {
    assert.equal(shouldWrite(null, base), true);
    assert.equal(shouldWrite(undefined, base), true);
  });

  test("a newer run replaces an older one", () => {
    assert.equal(shouldWrite(base, newer), true);
  });

  // Guard 6, stated directly. This is what a slow run overlapping a fast one
  // produces, and it is why the check exists.
  test("an OLDER run does not replace a newer one", () => {
    assert.equal(shouldWrite(newer, older), false);
  });

  // Same run means same data refetched; rewriting burns a Firestore write to
  // change nothing but a timestamp.
  test("an identical run is not rewritten", () => {
    assert.equal(shouldWrite(base, doc({referenceTime: base.runId!})), false);
  });

  test("gaining run identity is progress; losing it is not", () => {
    const noRun = doc({referenceTime: null});
    assert.equal(shouldWrite(noRun, base), true, "none -> identified: write");
    assert.equal(shouldWrite(base, noRun), false, "identified -> none: refuse");
  });

  test("two documents with no run at all fall back to arrival order", () => {
    const a = doc({referenceTime: null});
    const b = doc({referenceTime: null});
    assert.equal(shouldWrite(a, b), true);
  });

  // A stranded document the reader would discard anyway must not be permanent.
  test("a schema change always writes", () => {
    const stale: StoreDocument = {...newer, schema: 0};
    assert.equal(shouldWrite(stale, older), true);
  });

  test("isRunNewer compares instants, not strings", () => {
    // Same instant, different notation — string comparison would call the
    // second one newer and rewrite on every run.
    assert.equal(isRunNewer("2026-08-24T12:00:00.000Z", "2026-08-24T12:00:00Z"),
      false);
    assert.equal(isRunNewer("2026-08-24T18:00:00Z", "2026-08-24T06:00:00Z"),
      true);
  });

  test("unparseable runs fall back to string order rather than always writing",
    () => {
      assert.equal(isRunNewer("run-b", "run-a"), true);
      assert.equal(isRunNewer("run-a", "run-b"), false);
    });
});

describe("island reaches keep their own short-range cycle", () => {
  // Measured 2026-08-30 from NOAA's production directory listing:
  // `short_range` hourly, `short_range_puertorico` t00z/t06z/t12z,
  // `short_range_hawaii` t00z/t12z. The NWPS reach 800000010 (Oahu) reported
  // a short-range referenceTime of 00:00Z at 15:16Z the same day.
  const ISLAND = "800000010";
  const CONUS = "23021904";

  test("short range expires on the 6-hour cycle, not the next hour", () => {
    const at = new Date("2026-07-10T12:30:00.000Z");
    assert.equal(
      validUntil("nwm", "shortRange", at, ISLAND).toISOString(),
      "2026-07-10T18:05:00.000Z");
  });

  test("the two domains genuinely disagree", () => {
    // Stated as a difference so a shared constant edited in one place cannot
    // make this pass by accident.
    const at = new Date("2026-07-10T12:30:00.000Z");
    assert.notEqual(
      validUntil("nwm", "shortRange", at, ISLAND).getTime(),
      validUntil("nwm", "shortRange", at, CONUS).getTime(),
      "an island short-range window computed as CONUS is the defect these " +
      "tests exist for");
  });

  test("currentFlow follows SHORT RANGE, because it is", () => {
    // This asserted the opposite first time round, and was wrong for a reason
    // worth keeping. `store-upstream` maps `currentFlow` to the
    // `"short_range"` series and the client's handler calls
    // `fetchForecast(reachId, 'short_range')` — the name is a misnomer.
    //
    // Real analysis assimilation IS hourly in every domain
    // (`analysis_assim_hawaii` ran t00z..t14z on 2026-08-30), which is what
    // the earlier version asserted: a correct argument about a product
    // neither side fetches, which put island documents back on the CONUS hour
    // within an hour of that hour being removed.
    const at = new Date("2026-07-10T12:30:00.000Z");
    assert.equal(
      validUntil("nwm", "currentFlow", at, ISLAND).toISOString(),
      "2026-07-10T18:05:00.000Z",
      "a misleading name is not a reason to give a product the wrong " +
      "publish schedule");

    // The property that would have caught the original split, in both
    // domains: two products fetching one series cannot expire differently.
    for (const reach of [ISLAND, CONUS]) {
      assert.equal(
        validUntil("nwm", "currentFlow", at, reach).getTime(),
        validUntil("nwm", "shortRange", at, reach).getTime(),
        `reach ${reach}`);
    }
  });

  test("isIslandReach: both band edges are inclusive", () => {
    assert.equal(isIslandReach(String(ISLAND_COMID_MIN)), true);
    assert.equal(isIslandReach(String(ISLAND_COMID_MAX)), true);
    assert.equal(isIslandReach(String(ISLAND_COMID_MIN - 1)), false);
    assert.equal(isIslandReach(String(ISLAND_COMID_MAX + 1)), false);
  });

  test("a non-numeric reach id is CONUS, the safe direction", () => {
    // CONUS has the shorter windows, so a misclassification costs a refetch
    // rather than serving a value past its run. `Number("")` is 0 and
    // `Number(" 800000010 ")` is 800000010, so this needs the regex guard and
    // not a bare cast — mutation-checked by replacing the test with
    // `Number.isFinite`, which lets both through.
    for (const id of ["", "abc", "12.5", " 800000010 "]) {
      assert.equal(isIslandReach(id), false, `id "${id}"`);
    }
  });
});

describe("the Dart contract has not drifted", () => {
  test("STORE_SCHEMA_VERSION matches RiverDataEntry.schemaVersion", () => {
    const src = readFileSync(
      REPO + "lib/models/1_domain/shared/river_data/river_data_entry.dart",
      "utf8");
    const m = /static const int schemaVersion = (\d+);/.exec(src);
    assert.notEqual(m, null, "schemaVersion not found in Dart");
    assert.equal(Number(m![1]), STORE_SCHEMA_VERSION,
      "the client discards versions it does not recognise — a mismatch means " +
      "every document written is silently dropped on read");
  });

  // Reads BOTH data sources. The original only read nwm_data_source.dart,
  // which is why the GEOGLOWS mismatch survived: the drift test was blind to
  // the source that had drifted.
  test("each client source still skews by the amount this file uses", () => {
    const cases: [string, number][] = [
      ["nwm_data_source.dart", NWM_SKEW_MS],
      ["geoglows_data_source.dart", GEOGLOWS_SKEW_MS],
    ];
    for (const [file, expected] of cases) {
      const src = readFileSync(
        REPO + "lib/services/4_infrastructure/river_data/" + file, "utf8");
      const m = /static const Duration _skew = Duration\(minutes: (\d+)\);/
        .exec(src);
      assert.notEqual(m, null, `_skew not found in ${file}`);
      assert.equal(Number(m![1]) * 60_000, expected,
        `${file} and this file must expire a document at the same instant; ` +
        "both constants are PROVISIONAL and must be re-derived from probe " +
        "data in all THREE places");
    }
  });

  // The gap this closes, found by exercising it on 2026-08-30: the block above
  // pins the SKEW constants and the envelope field names, and nothing pinned
  // the SCHEDULE. Phase 9 changed the client's island short-range cycle and the
  // whole 406-test server suite stayed green while the two sides would have
  // expired the same document six hours apart. A drift guard that compares
  // only the constants both sides happen to share is not a drift guard.
  test("the island band and cycle match the Dart source exactly", () => {
    const src = readFileSync(
      REPO + "lib/models/1_domain/shared/river_data/nwm_domain.dart", "utf8")
      .replace(/^\s*\/\/.*$/gm, "");
    const num = (name: string): number => {
      const m = new RegExp(`const int ${name} = (\\d+);`).exec(src);
      assert.notEqual(m, null, `${name} not found in nwm_domain.dart`);
      return Number(m![1]);
    };
    assert.equal(num("islandComidMin"), ISLAND_COMID_MIN);
    assert.equal(num("islandComidMax"), ISLAND_COMID_MAX);
    assert.equal(num("islandShortRangeCycleHours"),
      ISLAND_SHORT_RANGE_CYCLE_HOURS,
      "the client and the store would expire the same island document at " +
      "different instants");
  });

  test("the client still routes short range through the domain", () => {
    // Pins the WIRING, not just the numbers. The constants can agree while the
    // client stops consulting them — which is the state this whole change
    // started from, and which no numeric comparison can see.
    const src = readFileSync(
      REPO + "lib/services/4_infrastructure/river_data/nwm_data_source.dart",
      "utf8").replace(/^\s*\/\/.*$/gm, "");
    assert.match(src, /nwmDomainOf\(reachId\)/,
      "nwm_data_source.dart no longer resolves the NWM domain, so every " +
      "island document is back on the CONUS hour");
    assert.match(src, /islandShortRangeCycleHours/,
      "the island cycle constant is no longer used by the client");
  });

  test("the client still names the envelope fields this file writes", () => {
    const src = readFileSync(
      REPO + "lib/models/1_domain/shared/river_data/river_data_entry.dart",
      "utf8");
    for (const field of
      ["'schema'", "'source'", "'reachId'", "'product'", "'window'", "'unit'",
        "'runId'", "'payload'"]) {
      assert.ok(src.includes(field), `RiverDataEntry no longer uses ${field}`);
    }
  });

  test("FreshnessWindow still names fetchedAt and validUntil", () => {
    const src = readFileSync(
      REPO + "lib/models/1_domain/shared/river_data/freshness_window.dart",
      "utf8");
    assert.ok(src.includes("'fetchedAt'"));
    assert.ok(src.includes("'validUntil'"));
  });
});
