// functions/src/store-health-wiring.test.ts
//
// ADR 0011 Phase 7 — a guard on the WIRING, not on the logic.
//
// `assessProductFreshness` is thoroughly tested as a pure function in
// store-trigger.test.ts. None of that proves `checkStoreHealth` actually
// FEEDS it anything: change `sampleStoredWindows(FORECAST_PRODUCTS, usage)` to
// `[]` and every one of those tests still passes, the endpoint still returns
// 200 `{"status":"healthy"}`, and production silently loses per-product health
// on the phase whose whole premise is that a silent failure must be visible.
//
// This is exactly the gap that was found twice on 2026-08-29 in the app half:
// the favourites card's badge logic was tested while the double unit
// conversion feeding it was not, and the offline banner's behaviour was tested
// while the fact that the forecast page MOUNTS it was not. Deleting the mount
// passed the entire suite. Same shape, same fix.
//
// **This is a source-level guard and therefore weaker than a behavioural
// one.** It cannot tell whether the query returns the right documents, only
// that the call is still there and still asks for every product. A real test
// needs `checkStoreHealth` to take its Firestore reads as injected
// dependencies the way `runStoreRefresh` takes `io`; that refactor is worth
// doing and is not done here. Recorded so the next person knows this is a
// tripwire, not coverage.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import {windowSampleFrom} from "./store-firestore.js";

const SOURCE = readFileSync(
  resolve(__dirname, "..", "src", "store-service.ts"), "utf8");
const FIRESTORE_SOURCE = readFileSync(
  resolve(__dirname, "..", "src", "store-firestore.ts"), "utf8");

/** The body of checkStoreHealth, which is what these assertions are about. */
function checkStoreHealthBody(): string {
  const start = SOURCE.indexOf("export async function checkStoreHealth");
  assert.notEqual(start, -1,
    "checkStoreHealth is gone or renamed — storeHealth and storeHeartbeat " +
    "both call it, so this is not a rename to make quietly");
  // NOT indexOf("\n}"): the signature's inline return type ends with `}>`, so
  // that matched inside the declaration and handed every assertion below an
  // empty body. Caught by the tests failing on correct code, which is the way
  // round you want it.
  const after = SOURCE.indexOf("\nexport ", start + 1);
  return SOURCE.slice(start, after === -1 ? SOURCE.length : after);
}

describe("Phase 7 — the health check is actually fed its per-product data",
  () => {
    test("it samples EVERY product, not a subset and not nothing", () => {
      const body = checkStoreHealthBody();

      assert.match(body, /sampleStoredWindows\(\s*FORECAST_PRODUCTS/,
        "checkStoreHealth must sample every product. Without this call the " +
        "per-product logic is dead code and the endpoint reports healthy on " +
        "a store where one product has stopped being written entirely.");
    });

    test("the samples reach assessStoreHealth rather than being dropped", () => {
      const body = checkStoreHealthBody();

      // The call is useless if its result never reaches the assessment. Both
      // halves have to be present for the feature to exist at all.
      const call = body.match(/assessStoreHealth\(([^;]*)\)/);
      assert.notEqual(call, null, "assessStoreHealth is not called");

      // `/samples/` alone was not enough, and a mutation proved it: replacing
      // the argument with `samples.slice(0, 0)` — which compiles, still
      // mentions `samples`, and passes an EMPTY list — sailed through all 360
      // tests. Requiring it to be the final argument verbatim closes that.
      assert.match(call![1].trim(), /,\s*samples$/,
        "the samples must be passed through unmodified as the last argument " +
        "to assessStoreHealth. Anything that narrows or empties them falls " +
        "back to the collection-wide check this phase exists to replace, " +
        "while still reporting a healthy store.");
    });

    test("the per-product ages are logged, so 'healthy' is checkable", () => {
      // Verifying the deploy meant reading this log line: an empty products
      // list would report healthy too, and only the log distinguishes "every
      // product is inside its cap" from "nothing was read".
      const body = checkStoreHealthBody();
      assert.match(body, /products:/,
        "the healthy log must list what was actually checked, or a healthy " +
        "verdict cannot be told apart from a check that read nothing");
    });
  });

describe("Phase 7 — the samples actually carry a run identity", () => {
  // Found by mutation: removing `runId` from the projection left all 369
  // tests green. `assessRunCurrency` is tested exhaustively as a pure
  // function, but every one of those tests builds its own samples, so none of
  // them notices that the real ones arrive with no run at all — in which case
  // the function skips every document and reports a spotless store.
  //
  // That is the failure mode this whole check exists to prevent, arriving by
  // the back door: a monitor that is silent because it was fed nothing.
  test("sampleStoredWindows projects runId from Firestore", () => {
    const start = FIRESTORE_SOURCE.indexOf(
      "export async function sampleStoredWindows");
    assert.notEqual(start, -1, "sampleStoredWindows is gone or renamed");
    const after = FIRESTORE_SOURCE.indexOf("\nexport ", start + 1);
    const body = FIRESTORE_SOURCE.slice(
      start, after === -1 ? FIRESTORE_SOURCE.length : after);

    assert.match(body, /\.select\([^)]*"runId"/,
      "the query must SELECT runId — a projection that omits it returns " +
      "documents with no run, and run-currency checking silently becomes a " +
      "no-op that reports every store healthy");

    // The mapping itself is no longer greppable here, and that is an
    // improvement rather than a loss: Phase 9's review found that dropping
    // `reachId` in this same inline block passed all 442 tests, because the
    // block needed a Firestore emulator to exercise. It was extracted to
    // `windowSampleFrom`, which is pure — so the "is it carried onto the
    // sample?" half is now a real behavioural test below instead of a regex.
    //
    // The `.select()` half stays source-level, because a Firestore projection
    // genuinely cannot be checked any other way without an emulator.
  });

  test("the mapping carries runId AND reachId onto the sample", () => {
    // Replaces a regex with the behaviour it was approximating. Both fields
    // are silent when lost: no runId makes run-currency checking a no-op that
    // reports every store healthy, and no reachId makes every island document
    // fall back to CONUS caps and expire between runs.
    const sample = windowSampleFrom("nwm__800000010__shortRange", {
      source: "nwm",
      reachId: "800000010",
      product: "shortRange",
      window: {
        fetchedAt: "2026-08-30T04:20:00.000Z",
        validUntil: "2026-08-30T16:30:00.000Z",
      },
      runId: "2026-08-30T00:00:00Z",
    });

    assert.equal(sample.runId, "2026-08-30T00:00:00Z",
      "reading runId from Firestore and then dropping it is a monitor that " +
      "is silent because it was fed nothing");
    assert.equal(sample.reachId, "800000010",
      "and an empty reachId is silently CONUS");
  });
});
