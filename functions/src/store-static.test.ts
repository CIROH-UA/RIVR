// functions/src/store-static.test.ts
//
// ADR 0011 Phase 5, guard 1: "a favourite renders with ZERO upstream calls
// from the device."
//
// Review round 1 found that guard unreachable. The store held the four flow
// products, but every surface that renders a favourite also reads the river's
// NAME and its flood THRESHOLDS, and neither was stored — so each favourite
// still made two device-side calls just to draw itself. `CAN_FETCH` omitted
// both, and round 2's F3 fix had filtered them out of the write-through plan,
// which made the omission look deliberate rather than load-bearing.
//
// These tests pin the two halves of the repair:
//   - the payload shapes match what the Dart decoders read, BY NAME
//   - the refresh decision is freshness-driven, not a daily refetch
//
// The payload tests read the Dart source off disk on purpose. A renamed field
// is the failure mode this whole store keeps having: it decodes as null, the
// reach renders untitled or uncoloured, and NOTHING is wrong server-side.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  STATIC_PRODUCTS,
  STATIC_REFRESH_LEAD_MS,
  assertStaticAccounting,
  staticRefreshDue,
} from "./store-service.js";
import {assertStoreRunConsistent} from "./store-run.js";
import {StoreDocument, validUntil} from "./store-document.js";
import {trimPayload} from "./store-payload.js";
import {
  CAN_FETCH,
  STORE_NATIVE_UNIT,
  fetchReachMetadata,
  fetchReturnPeriods,
} from "./store-upstream.js";

const REPO = resolve(__dirname, "..", "..") + "/";
const NOW = new Date("2026-08-25T12:00:00Z");

/** A stored static document expiring at [expiry]. */
function doc(expiry: string | null | undefined): StoreDocument {
  return {
    schema: 1,
    source: "nwm",
    reachId: "1",
    product: "reachMetadata",
    window: {
      fetchedAt: "2026-08-01T00:00:00Z",
      validUntil: expiry as string,
    },
    unit: "CMS",
    payload: {riverName: "Provo River"},
  };
}

describe("the static products are actually reachable", () => {
  test("both are fetchable by the server", () => {
    for (const p of STATIC_PRODUCTS) {
      assert.ok(CAN_FETCH.nwm.includes(p),
        `${p} must be fetchable or guard 1 cannot hold`);
    }
  });

  // Round 2, non-blocking 5: this test's NAME said "matching
  // NwmDataSource.validUntil" while it only asserted the server constant
  // against a literal. It now reads the Dart source, so the two genuinely
  // cannot drift.
  test("both carry a 30-day window, matching NwmDataSource.validUntil", () => {
    // The client refetches upstream the moment it considers a document stale,
    // so a shorter window here silently reintroduces the device-side call.
    for (const p of STATIC_PRODUCTS) {
      const until = validUntil("nwm", p, NOW, "23021904");
      const days = (until.getTime() - NOW.getTime()) / (24 * 3600_000);
      assert.equal(days, 30, `${p} should be valid for 30 days`);
    }

    const dart = readFileSync(
      REPO + "lib/services/4_infrastructure/river_data/nwm_data_source.dart",
      "utf8");
    const branch = dart.slice(
      dart.indexOf("case ForecastProduct.returnPeriods:"),
      dart.indexOf("case ForecastProduct.mediumRangeBlend:"));
    assert.ok(branch.includes("ForecastProduct.reachMetadata"),
      "the client no longer groups these two products together");
    assert.ok(/Duration\(days:\s*30\)/.test(branch),
      "the client's static window is no longer 30 days — the server's must " +
      "change with it, in this file and in store-document.ts");
  });
});

describe("the refresh decision is freshness-driven, not daily", () => {
  test("a missing document is due", () => {
    assert.equal(staticRefreshDue(null, NOW), true);
  });

  test("a document valid well beyond the lead is NOT due", () => {
    const far = new Date(
      NOW.getTime() + STATIC_REFRESH_LEAD_MS + 24 * 3600_000);
    assert.equal(staticRefreshDue(doc(far.toISOString()), NOW), false,
      "a current document must cost a read and no fetch");
  });

  test("a document inside the lead window IS due", () => {
    const soon = new Date(
      NOW.getTime() + STATIC_REFRESH_LEAD_MS - 3600_000);
    assert.equal(staticRefreshDue(doc(soon.toISOString()), NOW), true,
      "refreshing only once already stale leaves a window where every " +
      "device falls back to upstream — guard 1 undone, silently");
  });

  test("an already-expired document is due", () => {
    assert.equal(
      staticRefreshDue(doc("2026-08-01T00:00:00Z"), NOW), true);
  });

  test("an unparseable window refetches rather than being trusted", () => {
    // Trusting it would strand the document: never renewable, and every
    // device falls back to upstream forever with nothing in any log.
    assert.equal(staticRefreshDue(doc("not a date"), NOW), true);
    assert.equal(staticRefreshDue(doc(null), NOW), true);
    assert.equal(staticRefreshDue(doc(undefined), NOW), true);
  });

  test("the lead is non-zero", () => {
    assert.ok(STATIC_REFRESH_LEAD_MS > 0,
      "a zero lead means the refresh only ever fires once already stale");
  });
});

describe("payload shapes match the Dart decoders, field by field", () => {
  test("reachMetadata carries exactly the four fields Dart reads", () => {
    const dart = readFileSync(
      REPO +
      "lib/services/4_infrastructure/river_data/reach_metadata_payload.dart",
      "utf8");
    const decode = dart.slice(dart.indexOf("static ReachMetadata decode"));
    const read = [...decode.matchAll(/p\['(\w+)'\]/g)].map((m) => m[1]);
    assert.deepEqual(read.sort(),
      ["formattedLocation", "latitude", "longitude", "riverName"],
      "ReachMetadataPayload.decode reads a different field set");

    // What the server actually stores, after trimming.
    const stored = trimPayload("reachMetadata", {
      riverName: "Provo River",
      formattedLocation: null,
      latitude: 40.2,
      longitude: -111.6,
    });
    assert.deepEqual(Object.keys(stored).sort(), read.sort(),
      "the stored keys and the decoded keys must be the same set");
  });

  test("returnPeriods is stored as the raw upstream ARRAY", () => {
    // ReturnPeriodPayload.decode hands payload['returnPeriods'] straight to
    // ReachDataDto.fromReturnPeriodApi, which indexes jsonArray.first and
    // scans for `return_period_*` keys. Reshaping it server-side decodes to
    // no thresholds, and no thresholds costs the flood CATEGORY silently —
    // the number still renders, just never coloured.
    const dart = readFileSync(
      REPO + "lib/services/4_infrastructure/river_data/narrow_nwm_payloads.dart",
      "utf8");
    assert.ok(dart.includes("entry.payload['returnPeriods']"),
      "the client no longer reads payload['returnPeriods']");
    assert.ok(dart.includes("raw is! List"),
      "the client no longer expects a List — the stored shape must follow");

    const rows = [{feature_id: "1", return_period_2: 10, return_period_5: 20}];
    const stored = trimPayload("returnPeriods", {returnPeriods: rows});
    assert.deepEqual(Object.keys(stored), ["returnPeriods"]);
    assert.ok(Array.isArray(stored.returnPeriods),
      "trimming must not turn the array into an object");
    assert.deepEqual(stored.returnPeriods, rows);
  });

  // Round 2, non-blocking 6: this asserted only the CLIENT half, so changing
  // the SERVER's stored unit to "CFS" passed all 207 tests. Both halves now.
  test("thresholds are stored in CMS, which is what the client converts from",
    () => {
      assert.equal(STORE_NATIVE_UNIT, "CMS",
        "the server must store the API's native unit; anything else " +
        "silently misclassifies every flood category");

      const dart = readFileSync(
        REPO +
        "lib/services/4_infrastructure/river_data/narrow_nwm_payloads.dart",
        "utf8");
      const decode = dart.slice(dart.indexOf("class ReturnPeriodPayload"));
      // The client converts FROM the literal 'CMS', ignoring entry.unit,
      // because the API serves native units regardless of preference.
      assert.ok(decode.includes(`'${STORE_NATIVE_UNIT}'`),
        "the client no longer converts from the unit the server stores");
    });
});

// ── The WRITER, not just the trim table ─────────────────────────────────────
//
// Round 2, mutation 5: renaming `riverName` -> `river_name` inside
// fetchReachMetadata passed all 207 tests and `tsc` cleanly. trimPayload keeps
// whichever of the four names it finds and returns `found ? out : raw`, so
// with three names still correct it silently DROPPED the name and wrote a
// schema-valid document that ingests fine and renders every favourite
// untitled. The tests defended the trim table; nothing defended the producer.
//
// These stub global fetch so the real producer runs.

describe("the producers write the exact keys the client decodes", () => {
  const realFetch = globalThis.fetch;

  /** Install a stub. @param {unknown} body - JSON body. @param {object} o -
   * Options. @return {() => number} Call counter. */
  function stubFetch(body: unknown, o: {ok?: boolean} = {}): () => number {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      return {
        ok: o.ok ?? true,
        status: (o.ok ?? true) ? 200 : 500,
        statusText: "stub",
        json: async () => body,
      };
    }) as unknown as typeof fetch;
    return () => calls;
  }

  test("reachMetadata writes riverName/formattedLocation/latitude/longitude",
    async () => {
      stubFetch({name: "Provo River", latitude: 40.2, longitude: -111.6});
      try {
        const r = await fetchReachMetadata("123");
        assert.deepEqual(Object.keys(r.payload).sort(),
          ["formattedLocation", "latitude", "longitude", "riverName"],
          "a renamed key here decodes as null and renders blank, with " +
          "nothing wrong server-side");
        assert.equal(r.payload.riverName, "Provo River");
        assert.equal(r.payload.formattedLocation, null);
        assert.equal(r.unit, STORE_NATIVE_UNIT);
        assert.equal(r.referenceTime, null,
          "a river's name has no model run; inventing one defeats " +
          "supersession");
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  // Found on the first deployed run: 3 of 29 reaches came back with
  // `name: ""`. They are real reaches with valid coordinates that NOAA simply
  // has no name for. Rejecting them failed those reaches every day forever.
  // The live path accepts "" (`json['name'] as String`), so the store must.
  test("an EMPTY name is stored, exactly as the live path accepts it",
    async () => {
      stubFetch({name: "", latitude: 45.5679, longitude: -122.444});
      try {
        const r = await fetchReachMetadata("23735719");
        assert.equal(r.payload.riverName, "",
          "matching the live path is guard 7; failing daily is not an option");
        assert.equal(r.payload.latitude, 45.5679);
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  test("a response with NO name field still throws", async () => {
    // Absent is a shape we cannot read; empty is an answer.
    stubFetch({latitude: 40.2, longitude: -111.6});
    try {
      await assert.rejects(
        () => fetchReachMetadata("123"), /no name field/);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  test("returnPeriods writes the raw upstream ARRAY under 'returnPeriods'",
    async () => {
      const rows = [{feature_id: "123", return_period_2: 10}];
      stubFetch(rows);
      try {
        const r = await fetchReturnPeriods("123");
        assert.deepEqual(Object.keys(r.payload), ["returnPeriods"]);
        assert.ok(Array.isArray(r.payload.returnPeriods),
          "ReachDataDto.fromReturnPeriodApi indexes jsonArray.first");
        assert.deepEqual(r.payload.returnPeriods, rows);
        assert.equal(r.unit, STORE_NATIVE_UNIT);
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  // Round 4, non-blocking 1: this used to assert a blanket refusal, which
  // meant a reach that genuinely HAS no return periods failed every single
  // day, forever — permanently in reachesToRetry, inflating the failure rate
  // the Phase 0 probe exists to measure honestly. "Upstream has none" and
  // "the fetch failed" are different answers and now have different outcomes.
  test("a well-formed response with no thresholds stores an EMPTY set",
    async () => {
      stubFetch([{feature_id: "123"}]);
      try {
        const r = await fetchReturnPeriods("123");
        assert.deepEqual(r.payload.returnPeriods, [],
          "the client reads an empty list as 'no thresholds', which costs " +
          "this reach its flood category and nothing else");
      } finally {
        globalThis.fetch = realFetch;
      }
    });

  test("a response that is not an array still THROWS", async () => {
    // A shape we cannot read is a failure, not an answer. Storing from it
    // would put thresholds of unknown meaning behind a 30-day window.
    stubFetch({unexpected: "shape"});
    try {
      await assert.rejects(() => fetchReturnPeriods("123"), /not an array/);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  // CLAUDE.md states this absolutely: "Never add retries to the store's
  // fetchers." Round 2, B3 — the first version of both functions went through
  // noaa-client's fetchWithRetry, which retries 3x with backoff.
  test("neither producer retries a failed fetch", async () => {
    for (const [name, fn] of [
      ["reachMetadata", fetchReachMetadata],
      ["returnPeriods", fetchReturnPeriods],
    ] as const) {
      const calls = stubFetch({}, {ok: false});
      try {
        await assert.rejects(() => fn("123"));
        assert.equal(calls(), 1,
          `${name} retried; retrying inside the run hides the failure rate ` +
          "the Phase 0 probe exists to measure");
      } finally {
        globalThis.fetch = realFetch;
      }
    }
  });
});

// The reporting hole, not just the fetcher. The first deployed run of
// storeStaticDaily returned "ok" while failing 3 of 29 reaches; only reading
// the document counts back out of Firestore caught it. Round 6.
//
// The per-run assertion already existed; what was missing was that
// runStoreStaticRefresh runs the products in SEPARATE runs and merged their
// reports without re-checking the totals, and logged `failed` at INFO.
describe("assertStoreRunConsistent refuses a run whose outcomes do not add up",
  () => {
  /**
   * @param {number} written - Written records.
   * @param {number} failed - Failed records.
   * @return {object[]} Result records.
   */
    function results(written: number, failed: number): object[] {
      const out: object[] = [];
      for (let i = 0; i < written; i++) {
        out.push({
          documentId: `nwm__w${i}__reachMetadata`,
          reachId: `w${i}`,
          source: "nwm",
          product: "reachMetadata",
          outcome: "written",
          storedRun: null,
          laggingBehindProbe: false,
        });
      }
      for (let i = 0; i < failed; i++) {
        out.push({
          documentId: `nwm__f${i}__reachMetadata`,
          reachId: `f${i}`,
          source: "nwm",
          product: "reachMetadata",
          outcome: "failed",
          error: "reach info carried no name",
          storedRun: null,
          laggingBehindProbe: false,
        });
      }
      return out;
    }

    test("outcomes that do not add up to the plan are refused", () => {
      assert.throws(
        () => assertStoreRunConsistent({
          productsTriggered: ["reachMetadata"],
          planned: 29,
          written: 26,
          skippedSameRun: 0,
          skippedLagging: 0,
          failed: 0, // three reaches vanished without being counted
          reachesToRetry: [],
          results: results(26, 3),
          fetches: 29,
        } as never),
        /unknown state/,
        "a run whose totals do not add up must refuse to look clean"
      );
    });

    test("a fully accounted run passes", () => {
    // Exactly the shape of the first deployed run: 26 written, 3 failed on
    // reaches NOAA has no name for, all three queued for another attempt.
      assert.doesNotThrow(() => assertStoreRunConsistent({
        productsTriggered: ["reachMetadata"],
        planned: 29,
        written: 26,
        skippedSameRun: 0,
        skippedLagging: 0,
        failed: 3,
        reachesToRetry: ["f0", "f1", "f2"],
        results: results(26, 3),
        fetches: 29,
      } as never));
    });
  });

// Review round 7: the block above is named for a property the STATIC refresh
// relies on, but it exercises `assertStoreRunConsistent` — which
// `runStoreStaticRefresh` does not call. Its own accounting check could be
// deleted with the whole suite green, which is the same as not having it.
// `assertStaticAccounting` is that check, extracted so it can fail.

describe("the static refresh's own accounting can actually fail", () => {
  test("a plan fully accounted for passes", () => {
    assert.doesNotThrow(() => assertStaticAccounting(29, 26, 3));
    assert.doesNotThrow(() => assertStaticAccounting(0, 0, 0));
  });

  test("writes that vanished without being counted are refused", () => {
    // The shape of the first deployed run: reported ok, 3 of 29 reaches
    // failed, nothing in any log said so.
    assert.throws(
      () => assertStaticAccounting(29, 26, 0),
      /lost\s+work it never reported/,
      "a run that silently drops three reaches must not look clean");
  });

  test("over-counting is refused too, not just under-counting", () => {
    // Double-counting a write would hide a failure just as effectively.
    assert.throws(() => assertStaticAccounting(29, 29, 3), /planned 29/);
  });

  test("the error names the numbers, so a log line is diagnostic", () => {
    try {
      assertStaticAccounting(29, 26, 0);
      assert.fail("should have thrown");
    } catch (e) {
      const m = (e as Error).message;
      assert.match(m, /29/);
      assert.match(m, /26/);
      assert.equal((e as Error).name, "StoreRunAssertionError");
    }
  });
});
