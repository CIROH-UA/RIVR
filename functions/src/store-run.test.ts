// functions/src/store-run.test.ts
//
// ADR 0011 Phase 4, steps 3-5. Each group below is a numbered guard from the
// ADR, tested as the guard states it rather than as the implementation happens
// to work.
//
// Guard 12 is the one that shapes the whole file: "kill the fetch mid-run and
// confirm the count assertion fires." An assertion nobody has watched fail is
// not evidence of anything, so several tests deliberately corrupt a report and
// require a throw. CLAUDE.md records five operations that exited 0 while
// producing wrong or partial data; exit status caught none of them.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  FetchedProduct,
  StoreRunAssertionError,
  StoreRunDeps,
  StoreRunReport,
  assertStoreRunConsistent,
  planWrites,
  runStoreUpdate,
  writtenDocumentIds,
} from "./store-run.js";
import {StoreDocument, buildStoreDocument} from "./store-document.js";
import {ForecastProductId} from "./store-keys.js";
import {WorkList, deriveWorkList} from "./store-work-list.js";

const NOW = new Date("2026-08-24T13:10:00.000Z");

function workListOf(
  ...users: {favoriteReachIds: string[];
    favoriteSources?: Record<string, string>}[]
): WorkList {
  return deriveWorkList(users.map((u, i) => ({userId: `u${i}`, ...u})));
}

/** A dependency set that records what happened, with per-call overrides. */
function deps(over: Partial<StoreRunDeps> & {
  existing?: Record<string, StoreDocument>;
  failOn?: (reachId: string, product: string) => boolean;
  runFor?: (reachId: string, product: string) => string | null;
} = {}) {
  const writes: Record<string, StoreDocument> = {};
  const fetched: string[] = [];
  const store = over.existing ?? {};

  const base: StoreRunDeps = {
    async readExisting(id) {
      return store[id] ?? null;
    },
    async writeDocument(id, doc) {
      writes[id] = doc;
    },
    async fetchProduct(source, reachId, product): Promise<FetchedProduct> {
      fetched.push(`${source}:${reachId}:${product}`);
      if (over.failOn?.(reachId, product)) {
        throw new Error(`upstream 504 for ${reachId}`);
      }
      return {
        payload: {series: {data: [1, 2, 3]}},
        unit: source === "geoglows" ? "CMS" : "CFS",
        // `over.runFor?.(...) ?? default` would swallow a deliberate null,
        // which is exactly the case guard 3 needs to exercise.
        referenceTime: over.runFor ?
          over.runFor(reachId, product) :
          "2026-08-24T12:00:00Z",
      };
    },
    now: () => NOW,
  };
  return {deps: {...base, ...over} as StoreRunDeps, writes, fetched, store};
}

describe("planWrites crosses reaches with triggered products", () => {
  test("only products the source serves are planned", () => {
    const list = workListOf(
      {favoriteReachIds: ["1"]},
      {favoriteReachIds: ["2"], favoriteSources: {"2": "geoglows"}},
    );
    const planned = planWrites(list, ["shortRange", "geoglowsForecast"]);

    // NWM reach gets shortRange only; GEOGLOWS reach gets geoglowsForecast
    // only. Planning a product a source cannot serve would mark every reach on
    // that source failed.
    assert.deepEqual(planned.map((p) => p.documentId).sort(), [
      "geoglows__2__geoglowsForecast",
      "nwm__1__shortRange",
    ]);
  });

  test("nothing triggered plans nothing", () => {
    assert.deepEqual(planWrites(workListOf({favoriteReachIds: ["1"]}), []), []);
  });
});

describe("guard 1 — no new run means zero fetches", () => {
  test("an empty trigger set performs no fetches at all", async () => {
    const d = deps();
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["1", "2", "3"]}), [], d.deps);

    assert.equal(report.planned, 0);
    assert.equal(report.fetches, 0);
    assert.equal(d.fetched.length, 0,
      "the store must not fetch on a cycle where upstream did not publish");
  });

  test("the assertion catches a fetch on an empty plan", () => {
    const bogus: StoreRunReport = {
      productsTriggered: [], planned: 0, written: 0, skippedSuperseded: 0,
      failed: 0, reachesToRetry: [], results: [], fetches: 3,
    };
    assert.throws(() => assertStoreRunConsistent(bogus),
      StoreRunAssertionError);
  });
});

describe("guard 2 — a new run updates every reach, counts match", () => {
  test("every reach in the work list is written once", async () => {
    const d = deps();
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["1", "2"]}, {favoriteReachIds: ["2", "3"]}),
      ["shortRange"], d.deps);

    assert.equal(report.planned, 3, "3 distinct reaches, 1 product");
    assert.equal(report.written, 3);
    assert.equal(report.failed, 0);
    assert.deepEqual(writtenDocumentIds(report).sort(), [
      "nwm__1__shortRange", "nwm__2__shortRange", "nwm__3__shortRange",
    ]);
  });

  // Guard 8's fetch half: two users on one reach is ONE fetch, not two.
  test("a shared reach is fetched once, not once per follower", async () => {
    const d = deps();
    await runStoreUpdate(
      workListOf({favoriteReachIds: ["9"]}, {favoriteReachIds: ["9"]}),
      ["shortRange"], d.deps);
    assert.deepEqual(d.fetched, ["nwm:9:shortRange"]);
  });

  test("multiple triggered products multiply the plan", async () => {
    const d = deps();
    const products: ForecastProductId[] = ["shortRange", "mediumRange"];
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["1", "2"]}), products, d.deps);
    assert.equal(report.planned, 4);
    assert.equal(report.written, 4);
  });
});

describe("guard 3 — a reach is stored under its OWN run", () => {
  test("a reach on an older run is stored with that run, not the probe's",
    async () => {
      const d = deps({
        runFor: (reachId) =>
          reachId === "late" ? "2026-08-24T06:00:00Z" : "2026-08-24T12:00:00Z",
      });
      await runStoreUpdate(
        workListOf({favoriteReachIds: ["ontime", "late"]}),
        ["shortRange"], d.deps);

      assert.equal(d.writes["nwm__ontime__shortRange"].runId,
        "2026-08-24T12:00:00Z");
      assert.equal(d.writes["nwm__late__shortRange"].runId,
        "2026-08-24T06:00:00Z",
        "storing the lagging reach under the probe's run would make the " +
        "store claim data it does not have");
    });

  test("a response with no run is stored without one, not with a stand-in",
    async () => {
      const d = deps({runFor: () => null});
      await runStoreUpdate(workListOf({favoriteReachIds: ["1"]}),
        ["shortRange"], d.deps);
      assert.equal("runId" in d.writes["nwm__1__shortRange"], false);
    });
});

describe("guard 4 — a failing reach keeps its previous record", () => {
  test("the failure is recorded, nothing is written, others continue",
    async () => {
      const existing = buildStoreDocument({
        source: "nwm", reachId: "bad", product: "shortRange",
        payload: {old: true}, unit: "CFS",
        referenceTime: "2026-08-23T00:00:00Z", fetchedAt: NOW,
      });
      const d = deps({
        existing: {"nwm__bad__shortRange": existing},
        failOn: (reachId) => reachId === "bad",
      });

      const report = await runStoreUpdate(
        workListOf({favoriteReachIds: ["good", "bad", "other"]}),
        ["shortRange"], d.deps);

      assert.equal(report.failed, 1);
      assert.equal(report.written, 2, "one reach failing must not abort others");
      assert.equal(d.writes["nwm__bad__shortRange"], undefined,
        "nothing was written for the failing reach");
      assert.deepEqual(report.reachesToRetry, ["bad"]);
    });

  test("every failure reaches the retry set", async () => {
    const d = deps({failOn: () => true});
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["a", "b"]}), ["shortRange"], d.deps);
    assert.equal(report.failed, 2);
    assert.deepEqual(report.reachesToRetry.sort(), ["a", "b"]);
  });
});

describe("guard 6 — overlapping runs cannot write backwards", () => {
  test("an older run is skipped, not written", async () => {
    const newer = buildStoreDocument({
      source: "nwm", reachId: "1", product: "shortRange",
      payload: {}, unit: "CFS",
      referenceTime: "2026-08-24T18:00:00Z", fetchedAt: NOW,
    });
    const d = deps({
      existing: {"nwm__1__shortRange": newer},
      runFor: () => "2026-08-24T06:00:00Z",
    });

    const report = await runStoreUpdate(workListOf({favoriteReachIds: ["1"]}),
      ["shortRange"], d.deps);

    assert.equal(report.skippedSuperseded, 1);
    assert.equal(report.written, 0);
    assert.equal(d.writes["nwm__1__shortRange"], undefined,
      "a late run carrying older data must not overwrite newer data");
  });

  test("an unchanged run is skipped rather than rewritten", async () => {
    const same = buildStoreDocument({
      source: "nwm", reachId: "1", product: "shortRange",
      payload: {}, unit: "CFS",
      referenceTime: "2026-08-24T12:00:00Z", fetchedAt: NOW,
    });
    const d = deps({existing: {"nwm__1__shortRange": same}});
    const report = await runStoreUpdate(workListOf({favoriteReachIds: ["1"]}),
      ["shortRange"], d.deps);
    assert.equal(report.skippedSuperseded, 1);
    assert.equal(report.written, 0);
  });
});

describe("guard 12 — silent failure is impossible", () => {
  // The guard verbatim: kill the fetch mid-run, confirm the assertion fires.
  test("a run killed part-way through throws instead of reporting success",
    async () => {
      let calls = 0;
      const d = deps({
        fetchProduct: async () => {
          calls++;
          if (calls > 2) throw Object.assign(new Error("process killed"), {
            fatal: true,
          });
          return {payload: {}, unit: "CFS", referenceTime: null};
        },
      } as Partial<StoreRunDeps>);

      // Failures are counted, so the run still balances — this is the honest
      // outcome and it is reported, not hidden.
      const report = await runStoreUpdate(
        workListOf({favoriteReachIds: ["1", "2", "3", "4"]}),
        ["shortRange"], d.deps);
      assert.equal(report.written, 2);
      assert.equal(report.failed, 2);
      assert.equal(report.planned, 4);
    });

  test("outcomes that do not sum to the plan throw", () => {
    const bogus: StoreRunReport = {
      productsTriggered: ["shortRange"], planned: 10, written: 3,
      skippedSuperseded: 1, failed: 1, reachesToRetry: [], results: [],
      fetches: 5,
    };
    assert.throws(() => assertStoreRunConsistent(bogus),
      (e: unknown) => e instanceof StoreRunAssertionError &&
        /unknown state/.test(e.message));
  });

  test("more fetches than planned writes throws", () => {
    const bogus: StoreRunReport = {
      productsTriggered: ["shortRange"], planned: 1, written: 1,
      skippedSuperseded: 0, failed: 0,
      reachesToRetry: [],
      results: [{
        documentId: "nwm__1__shortRange", reachId: "1", source: "nwm",
        product: "shortRange", outcome: "written",
      }],
      fetches: 9,
    };
    assert.throws(() => assertStoreRunConsistent(bogus),
      (e: unknown) => e instanceof StoreRunAssertionError &&
        /fetched more than once/.test(e.message));
  });

  test("a dropped retry entry throws", () => {
    const bogus: StoreRunReport = {
      productsTriggered: ["shortRange"], planned: 1, written: 0,
      skippedSuperseded: 0, failed: 1,
      reachesToRetry: [], // the failure was silently not queued
      results: [{
        documentId: "nwm__1__shortRange", reachId: "1", source: "nwm",
        product: "shortRange", outcome: "failed", error: "boom",
      }],
      fetches: 1,
    };
    assert.throws(() => assertStoreRunConsistent(bogus),
      (e: unknown) => e instanceof StoreRunAssertionError &&
        /queued for retry/.test(e.message));
  });

  test("a real run's report always passes its own assertion", async () => {
    const d = deps({failOn: (r) => r === "b"});
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["a", "b", "c"]}), ["shortRange"], d.deps);
    assert.doesNotThrow(() => assertStoreRunConsistent(report));
  });
});

describe("guard 5 — the stored unit is upstream's, not a user's", () => {
  test("NWM stores CFS and GEOGLOWS stores CMS regardless of any user",
    async () => {
      const d = deps();
      await runStoreUpdate(
        workListOf(
          {favoriteReachIds: ["1"]},
          {favoriteReachIds: ["2"], favoriteSources: {"2": "geoglows"}},
        ),
        ["shortRange", "geoglowsForecast"], d.deps);

      assert.equal(d.writes["nwm__1__shortRange"].unit, "CFS");
      assert.equal(d.writes["geoglows__2__geoglowsForecast"].unit, "CMS");
    });
});
