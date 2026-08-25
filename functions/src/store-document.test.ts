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
  NWM_SKEW_MS,
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
    assert.equal(validUntil("nwm", "shortRange", AT).toISOString(),
      "2026-08-24T14:05:00.000Z");
  });

  test("6-hourly products round up to 00/06/12/18Z, plus the NWM skew", () => {
    // 13:10 -> 18:00.
    assert.equal(validUntil("nwm", "mediumRange", AT).toISOString(),
      "2026-08-24T18:05:00.000Z");
  });

  // GEOGLOWS skews by 15 minutes, not NWM's 5 — a different physical reason
  // (00Z proxy cold start). Sharing one constant made every GEOGLOWS document
  // expire 10 minutes before the client expected, so the client refetched
  // upstream on every read and the store did nothing.
  test("GEOGLOWS rounds up to the next UTC midnight, plus the GEOGLOWS skew",
    () => {
      assert.equal(validUntil("geoglows", "geoglowsForecast", AT).toISOString(),
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
        (validUntil("nwm", p, AT).getTime() - AT.getTime()) / 86400_000;
      assert.equal(days, 30);
    }
  });

  test("a product a source does not serve throws", () => {
    assert.throws(() => validUntil("nwm", "geoglowsForecast", AT));
    assert.throws(() => validUntil("geoglows", "shortRange", AT));
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
