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
  staticRefreshDue,
} from "./store-service.js";
import {StoreDocument, validUntil} from "./store-document.js";
import {trimPayload} from "./store-payload.js";
import {CAN_FETCH} from "./store-upstream.js";

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

  test("both carry a 30-day window, matching NwmDataSource.validUntil", () => {
    // The client refetches upstream the moment it considers a document stale, so
    // a shorter window here silently reintroduces the device-side call.
    for (const p of STATIC_PRODUCTS) {
      const until = validUntil("nwm", p, NOW);
      const days = (until.getTime() - NOW.getTime()) / (24 * 3600_000);
      assert.equal(days, 30, `${p} should be valid for 30 days`);
    }
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

  test("thresholds are stored in CMS, which is what the client converts from",
    () => {
      const dart = readFileSync(
        REPO +
        "lib/services/4_infrastructure/river_data/narrow_nwm_payloads.dart",
        "utf8");
      const decode = dart.slice(dart.indexOf("class ReturnPeriodPayload"));
      // The client converts FROM the literal 'CMS', ignoring entry.unit,
      // because the API serves native units regardless of preference. Storing
      // anything else silently misclassifies every flood category.
      assert.ok(decode.includes("'CMS'"),
        "the client no longer converts from CMS; the stored unit must follow");
    });
});
