// functions/src/store-keys.test.ts
//
// ADR 0011 Phase 4 requires the stored document ID to BE the client's cache
// key. That makes this a cross-language contract with Dart, and a drifted
// contract fails silently: the write succeeds, the client's read finds nothing,
// and Phase 5 falls back to fetching upstream with no error anywhere.
//
// The last group reads the Dart enums off disk and compares them to the lists
// here. It is unusual for a unit test to read source files, and it is the point
// — nothing else can catch a Dart-side rename, because TypeScript cannot see
// Dart and neither language's compiler spans the gap.
//
// It also guards a mistake already made while writing this: regenerating the
// product list by pattern-matching `^  name,` silently drops the final entry,
// because the last Dart enum member terminates with `;` not `,`. That produced
// 9 products instead of 10, and every test here would still have passed.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  FORECAST_PRODUCTS,
  FORECAST_SOURCES,
  parseStorageKey,
  storageKey,
} from "./store-keys.js";

/**
 * Repo root. This file compiles to functions/lib/store-keys.test.js, so the
 * root is two levels up. Resolved from __dirname rather than cwd so the test
 * works however it is invoked.
 */
const REPO = resolve(__dirname, "..", "..") + "/";

/** Enum member names from a Dart `enum X { ... }` block. */
function dartEnumMembers(relPath: string, enumName: string): string[] {
  const src = readFileSync(REPO + relPath, "utf8");
  const start = src.indexOf(`enum ${enumName} {`);
  assert.notEqual(start, -1, `${enumName} not found in ${relPath}`);
  const body = src.slice(start + `enum ${enumName} {`.length);

  const members: string[] = [];
  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("//") || line.startsWith("/*") ||
        line.startsWith("*")) continue;
    // Members are bare identifiers ending in "," or ";". The ";" form
    // terminates the list — anything after it is methods and constants.
    const m = /^([a-zA-Z][A-Za-z0-9]*)\s*([,;])$/.exec(line);
    if (!m) break;
    members.push(m[1]);
    if (m[2] === ";") break;
  }
  return members;
}

describe("storageKey builds the document ID Dart expects", () => {
  test("the documented example round-trips", () => {
    assert.equal(
      storageKey("nwm", "23021904", "shortRange"),
      "nwm__23021904__shortRange"
    );
  });

  test("geoglows keys are distinct from nwm for the same reach id", () => {
    // An NWM comid and a GEOGLOWS linkno can be numerically identical. If the
    // source were dropped from the key, one network would overwrite the other.
    assert.notEqual(
      storageKey("nwm", "760021642", "reachMetadata"),
      storageKey("geoglows", "760021642", "reachMetadata")
    );
  });

  test("every product produces a distinct key for one reach", () => {
    const keys = new Set(
      FORECAST_PRODUCTS.map((p) => storageKey("nwm", "123", p))
    );
    assert.equal(keys.size, FORECAST_PRODUCTS.length,
      "two products collided onto one document");
  });

  test("an empty reach id is refused, not silently keyed", () => {
    assert.throws(() => storageKey("nwm", "", "shortRange"));
  });

  // A reach id containing the separator makes the key ambiguous to parse back,
  // and Phase 4's GC and monitoring both parse keys.
  test("a reach id containing the separator is refused", () => {
    assert.throws(() => storageKey("nwm", "12__34", "shortRange"));
  });
});

describe("parseStorageKey is the exact inverse", () => {
  test("round-trips every source and product", () => {
    for (const source of FORECAST_SOURCES) {
      for (const product of FORECAST_PRODUCTS) {
        const key = storageKey(source, "23021904", product);
        assert.deepEqual(parseStorageKey(key),
          {source, reachId: "23021904", product});
      }
    }
  });

  // Returns null rather than throwing: the caller iterates a collection that
  // may hold foreign documents, and one stray ID must not abort a whole run.
  test("foreign and malformed IDs are null, not throws", () => {
    for (const bad of [
      "",
      "users",
      "nwm__123",
      "nwm__123__shortRange__extra",
      "mars__123__shortRange",
      "nwm__123__notAProduct",
      "nwm____shortRange",
    ]) {
      assert.equal(parseStorageKey(bad), null, `"${bad}" should not parse`);
    }
  });
});

describe("the Dart contract has not drifted", () => {
  test("FORECAST_SOURCES matches ForecastSource exactly, in order", () => {
    const dart = dartEnumMembers(
      "lib/models/1_domain/shared/forecast_source.dart", "ForecastSource");
    assert.deepEqual([...FORECAST_SOURCES], dart);
  });

  test("FORECAST_PRODUCTS matches ForecastProduct exactly, in order", () => {
    const dart = dartEnumMembers(
      "lib/models/1_domain/shared/river_data/forecast_product.dart",
      "ForecastProduct");
    assert.deepEqual([...FORECAST_PRODUCTS], dart,
      "a product was added, removed or renamed in Dart — the store would " +
      "write document IDs the app never reads");
  });

  // The specific slip this file exists to prevent, pinned as a number so a
  // truncated regeneration fails loudly instead of looking plausible.
  test("there are exactly 10 products", () => {
    assert.equal(FORECAST_PRODUCTS.length, 10);
  });

  test("Dart still derives its id from the enum name", () => {
    // If `String get id => name` ever becomes a custom mapping, these literal
    // strings stop being the wire format and everything above is wrong.
    for (const [path, name] of [
      ["lib/models/1_domain/shared/forecast_source.dart", "ForecastSource"],
      ["lib/models/1_domain/shared/river_data/forecast_product.dart",
        "ForecastProduct"],
    ]) {
      const src = readFileSync(REPO + path, "utf8");
      assert.match(src, /String get id => name;/,
        `${name} no longer derives its wire id from the enum name`);
    }
  });

  test("Dart still builds storageKey the way this file does", () => {
    const src = readFileSync(
      REPO + "lib/models/1_domain/shared/river_data/river_data_key.dart",
      "utf8");
    assert.match(
      src,
      /\$\{source\.id\}__\$\{reachId\}__\$\{product\.id\}/,
      "RiverDataKey.storageKey changed shape — storageKey() must follow"
    );
  });
});
