// functions/src/store-payload.test.ts
//
// ADR 0011 Phase 4 Build: "Store the trimmed payload."
//
// Trimming is the one operation here that can destroy data on the way IN, and
// it fails silently in both directions:
//   - too aggressive: the client's ForecastResponseDto returns null and the
//     app shows "no value" for a river the store holds perfectly good data for
//   - too timid: a 156 KB medium-range body per reach, and documents drifting
//     toward Firestore's 1 MiB hard limit
//
// So these tests assert what SURVIVES as carefully as what is dropped.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  PAYLOAD_WARN_BYTES,
  PayloadTooLargeError,
  assertPayloadFits,
  payloadBytes,
  trimPayload,
} from "./store-payload.js";

/** A medium-range body shaped as NOAA returns it: mean plus many members. */
function mediumBody() {
  const members: Record<string, unknown> = {};
  for (let i = 1; i <= 20; i++) {
    members[`member${i}`] = {
      referenceTime: "2026-08-24T06:00:00Z",
      units: "ft3/s",
      data: Array.from({length: 80}, (_, k) => ({
        validTime: `2026-08-2${k % 9}T00:00:00Z`, flow: 100 + k,
      })),
    };
  }
  return {
    reach: {reachId: "123", name: "Test River"},
    mediumRange: {
      mean: {
        referenceTime: "2026-08-24T06:00:00Z",
        units: "ft3/s",
        data: [{validTime: "2026-08-25T00:00:00Z", flow: 700}],
      },
      ...members,
    },
  };
}

describe("what trimming keeps", () => {
  test("the reach identity survives — the DTO needs it to parse", () => {
    const out = trimPayload("mediumRange", mediumBody());
    assert.deepEqual(out.reach, {reachId: "123", name: "Test River"});
  });

  test("the mean series survives intact, values and all", () => {
    const out = trimPayload("mediumRange", mediumBody());
    const mean = (out.mediumRange as Record<string, unknown>).mean as
      Record<string, unknown>;
    assert.equal(mean.referenceTime, "2026-08-24T06:00:00Z");
    assert.equal(mean.units, "ft3/s");
    assert.equal((mean.data as unknown[]).length, 1);
  });

  test("short range keeps its series — it has no members to drop", () => {
    const body = {
      reach: {reachId: "1"},
      shortRange: {series: {units: "ft3/s", data: [{flow: 1}]}},
    };
    assert.deepEqual(trimPayload("shortRange", body), body);
  });

  test("returnPeriods keeps the array the client reads verbatim", () => {
    const body = {returnPeriods: [{feature_id: "1", return_period_2: 5}]};
    assert.deepEqual(trimPayload("returnPeriods", body), body);
  });

  test("reachMetadata keeps exactly the four fields Dart decodes", () => {
    const body = {
      riverName: "Test River", formattedLocation: "Provo, UT",
      latitude: 40.0, longitude: -111.0,
      somethingElse: "dropped", route: {big: "object"},
    };
    assert.deepEqual(trimPayload("reachMetadata", body), {
      riverName: "Test River", formattedLocation: "Provo, UT",
      latitude: 40.0, longitude: -111.0,
    });
  });
});

describe("what trimming drops", () => {
  // This test used to assert the OPPOSITE — that members are dropped and the
  // payload shrinks 10x — and it was pinning a user-visible defect in place.
  // HydrographPage gates its ensemble-spread toggle on
  // `ForecastValues.hasMultipleEnsembleMembers`, which counts `member*` keys
  // and needs more than one. With the members trimmed away, favouriting a
  // reach made that toggle vanish from its medium and long-range hydrograph
  // and unfavouriting it brought the toggle back. Review round 6.
  test("ensemble members are KEPT — the app renders them", () => {
    const raw = mediumBody();
    const out = trimPayload("mediumRange", raw);
    const section = out.mediumRange as Record<string, unknown>;

    assert.ok("member1" in section,
      "dropping members removes the ensemble toggle for favourites only, " +
      "which is guard 7 failing where a user can see it");
    assert.ok("mean" in section);

    const members = Object.keys(section).filter((k) => k.startsWith("member"));
    assert.ok(members.length > 1,
      `hasMultipleEnsembleMembers needs >1, got ${members.length}`);
  });

  test("the kept ensemble still fits well inside the size guard", () => {
    // Measured on reach 10092062 (2026-08-25): medium range full is ~100 KB,
    // long range ~41 KB, against a 700 KB refusal threshold.
    const out = trimPayload("mediumRange", mediumBody());
    assert.ok(payloadBytes(out) < PAYLOAD_WARN_BYTES,
      `payload ${payloadBytes(out)} must stay under ${PAYLOAD_WARN_BYTES}`);
  });

  test("sections other than the product's own are dropped", () => {
    const body = {
      reach: {reachId: "1"},
      shortRange: {series: {units: "ft3/s", data: []}},
      mediumRange: {mean: {units: "ft3/s", data: []}},
      longRange: {mean: {units: "ft3/s", data: []}},
    };
    const out = trimPayload("mediumRange", body);
    assert.deepEqual(Object.keys(out).sort(), ["mediumRange", "reach"]);
  });
});

describe("trimming refuses to guess", () => {
  // Dropping data because this file has not been taught about a product is the
  // silent-partial-data failure the project keeps hitting. Pass through.
  test("an unrecognised product passes through untouched", () => {
    const body = {geoglows: {something: [1, 2, 3]}, extra: true};
    assert.deepEqual(trimPayload("geoglowsForecast", body), body);
  });

  test("a body missing the expected section passes through untouched", () => {
    const body = {reach: {reachId: "1"}, unexpectedShape: true};
    assert.deepEqual(trimPayload("mediumRange", body), body);
  });

  test("a metadata body with none of the known fields passes through", () => {
    const body = {totallyDifferent: 1};
    assert.deepEqual(trimPayload("reachMetadata", body), body);
  });

  test("an ensemble section with no mean keeps the section as-is", () => {
    const body = {reach: {}, mediumRange: {member1: {data: []}}};
    const out = trimPayload("mediumRange", body);
    assert.deepEqual(out.mediumRange, {member1: {data: []}});
  });
});

describe("the size ceiling refuses before the write", () => {
  test("a normal payload passes", () => {
    assert.doesNotThrow(
      () => assertPayloadFits("nwm__1__mediumRange", trimPayload(
        "mediumRange", mediumBody())));
  });

  // A document just under Firestore's hard limit is worse than one over it: it
  // writes, costs, and drags every client read.
  test("an oversized payload throws rather than being written", () => {
    const huge = {blob: "x".repeat(PAYLOAD_WARN_BYTES + 1)};
    assert.throws(() => assertPayloadFits("nwm__1__mediumRange", huge),
      PayloadTooLargeError);
  });

  test("the ceiling sits under Firestore's hard limit, not at it", () => {
    assert.ok(PAYLOAD_WARN_BYTES < 1024 * 1024,
      "the encoded size Firestore counts exceeds JSON byte length, so the " +
      "ceiling needs headroom");
  });
});

describe("a REAL NOAA body, with its empty sibling sections", () => {
  // NOAA returns ALL five section keys in every response, with the ones you
  // did not request as `{}`. Every fixture above is a hand-made two-key body,
  // which is why B2 was invisible: `section in raw` passed on an EMPTY section
  // and the trim threw the real data away. Round 3, B2.
  function realNoaaShortRangeBody() {
    return {
      reach: {reachId: "10376596", name: "Test River"},
      analysisAssimilation: {},
      shortRange: {
        series: {
          referenceTime: "2026-08-24T23:00:00Z",
          units: "ft³/s",
          data: [{validTime: "2026-08-25T00:00:00Z", flow: 640}],
        },
      },
      mediumRange: {},
      longRange: {},
      mediumRangeBlend: {},
    };
  }

  test("analysisAssimilation keeps the shortRange series, not the empty one",
    () => {
      const out = trimPayload("analysisAssimilation",
        realNoaaShortRangeBody());

      assert.ok("shortRange" in out,
        "the client derives current flow from short range; without this " +
        "section the document has a valid runId and NO flow data at all");
      const sr = out.shortRange as Record<string, unknown>;
      assert.ok("series" in sr);
      assert.equal("analysisAssimilation" in out, false,
        "the empty sibling section must not be stored as the payload");
    });

  test("shortRange itself is unaffected by the empty siblings", () => {
    const out = trimPayload("shortRange", realNoaaShortRangeBody());
    assert.deepEqual(Object.keys(out).sort(), ["reach", "shortRange"]);
  });

  // The failure mode B2 actually produced: a document that writes cleanly,
  // carries a correct runId, and contains nothing the client can read.
  //
  // Scoped to the products this body genuinely carries data for. A body whose
  // requested section is empty passes through untrimmed by design (next test),
  // so asserting over every product would flag correct behaviour.
  test("a product with real data is never trimmed to an empty section", () => {
    const body = realNoaaShortRangeBody();
    for (const p of ["analysisAssimilation", "shortRange"] as const) {
      const out = trimPayload(p, body);
      const dataKeys = Object.keys(out).filter((k) => k !== "reach");
      assert.ok(dataKeys.length > 0, `${p} kept no data section at all`);

      for (const k of dataKeys) {
        const v = out[k];
        const empty = v !== null && typeof v === "object" &&
          Object.keys(v as Record<string, unknown>).length === 0;
        assert.equal(empty, false,
          `${p} was trimmed to an empty ${k} section — a document that ` +
          "writes cleanly and delivers nothing");
      }
    }
  });

  test("a body whose requested section is empty passes through untrimmed",
    () => {
      // Better to store the whole body than a confidently-empty section.
      const body = {reach: {reachId: "1"}, mediumRange: {}, shortRange: {}};
      assert.deepEqual(trimPayload("mediumRange", body), body);
    });
});
