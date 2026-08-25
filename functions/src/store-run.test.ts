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
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  FatalRunError,
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
import {PRODUCTS_BY_SOURCE} from "./store-run.js";
import {STORE_COLLECTION} from "./store-keys.js";

const REPO = resolve(__dirname, "..", "..") + "/";

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
      productsTriggered: [], planned: 0, written: 0,
      failed: 0, skippedSameRun: 0, skippedLagging: 0,
      reachesToRetry: [], results: [], fetches: 3,
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

    assert.equal(report.skippedSameRun, 1);
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
    assert.equal(report.skippedSameRun, 1);
    assert.equal(report.written, 0);
    assert.deepEqual(report.reachesToRetry, [],
      "upstream having nothing newer is not a reason to retry");
  });
});

describe("guard 12 — silent failure is impossible", () => {
  // Round 1 caught this test asserting the OPPOSITE of its own title: it was
  // called "a run killed part-way through throws" while asserting the run did
  // not throw. Both behaviours are real and different, so they are now two
  // tests, each named for what it actually checks.

  // Per-reach failures are caught and counted, so the run balances. That is
  // the honest outcome and it is reported, not hidden.
  test("upstream failures are counted, and the run still balances",
    async () => {
      let calls = 0;
      const d = deps({
        fetchProduct: async () => {
          calls++;
          if (calls > 2) throw new Error("upstream 504");
          return {payload: {}, unit: "CFS", referenceTime: null};
        },
      } as Partial<StoreRunDeps>);

      const report = await runStoreUpdate(
        workListOf({favoriteReachIds: ["1", "2", "3", "4"]}),
        ["shortRange"], d.deps);
      assert.equal(report.written, 2);
      assert.equal(report.failed, 2);
      assert.equal(report.planned, 4);
      assert.doesNotThrow(() => assertStoreRunConsistent(report));
    });

  // The guard verbatim: kill the run mid-flight, confirm the count assertion
  // FIRES. A fatal escape is not a per-reach failure — it kills the iteration
  // itself, leaving outcomes short of the plan. The raw error must not be
  // allowed to propagate alone, because nothing in it says the store is now in
  // a partial state.
  test("a run killed mid-flight fires the count assertion, not the raw error",
    async () => {
      let calls = 0;
      const d = deps({
        fetchProduct: async () => {
          calls++;
          // FatalRunError escapes the per-reach handler by design.
          if (calls > 2) throw new FatalRunError("credentials expired mid-run");
          return {payload: {}, unit: "CFS", referenceTime: null};
        },
      } as Partial<StoreRunDeps>);

      await assert.rejects(
        () => runStoreUpdate(
          workListOf({favoriteReachIds: ["1", "2", "3", "4"]}),
          ["shortRange"], d.deps),
        (e: unknown) => e instanceof StoreRunAssertionError &&
          /unknown state/.test(e.message),
        "the assertion must fire and name the partial state; a run that died " +
        "half way must never return a report that looks like success"
      );
    });

  test("outcomes that do not sum to the plan throw", () => {
    const bogus: StoreRunReport = {
      productsTriggered: ["shortRange"], planned: 10, written: 3,
      skippedSameRun: 1, skippedLagging: 0, failed: 1, reachesToRetry: [],
      results: [], fetches: 5,
    };
    assert.throws(() => assertStoreRunConsistent(bogus),
      (e: unknown) => e instanceof StoreRunAssertionError &&
        /unknown state/.test(e.message));
  });

  test("more fetches than planned writes throws", () => {
    const bogus: StoreRunReport = {
      productsTriggered: ["shortRange"], planned: 1, written: 1,
      skippedSameRun: 0, skippedLagging: 0, failed: 0,
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
      skippedSameRun: 0, skippedLagging: 0, failed: 1,
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

describe("the Dart contract has not drifted", () => {
  /** Enum member names from a Dart `Set<ForecastProduct> get supportedProducts`. */
  function supportedProducts(file: string): string[] {
    const src = readFileSync(
      REPO + "lib/services/4_infrastructure/river_data/" + file, "utf8");
    const start = src.indexOf("get supportedProducts");
    assert.notEqual(start, -1, `supportedProducts not found in ${file}`);
    const body = src.slice(start, src.indexOf("}", start));
    return [...body.matchAll(/ForecastProduct\.([A-Za-z0-9]+)/g)]
      .map((m) => m[1]);
  }

  // Round 1 flagged this as the one cross-language contract with no drift
  // test. A product added to a Dart source but not here would simply never be
  // stored — the app would fetch upstream for it forever, with no error.
  test("PRODUCTS_BY_SOURCE matches supportedProducts on both sources", () => {
    assert.deepEqual([...PRODUCTS_BY_SOURCE.nwm].sort(),
      supportedProducts("nwm_data_source.dart").sort());
    assert.deepEqual([...PRODUCTS_BY_SOURCE.geoglows].sort(),
      supportedProducts("geoglows_data_source.dart").sort());
  });

  // The collection name lives in two files that cannot see each other. A
  // mismatch denies every client read, silently, forever.
  test("STORE_COLLECTION is the collection firestore.rules grants", () => {
    const rules = readFileSync(REPO + "firestore.rules", "utf8");
    assert.ok(
      rules.includes(`match /${STORE_COLLECTION}/{documentId}`),
      `firestore.rules has no rule for "${STORE_COLLECTION}" — the client ` +
      "would be denied on every read"
    );
  });
});

describe("guard 3 — lagging is measured against the PROBE, not the store", () => {
  // Round 2, F1. The guard's wording is "a reach returning an older
  // referenceTime THAN THE PROBE". Measuring against the stored document
  // answers a different question and misses the real case entirely: a reach
  // still serving the run the store already holds, while upstream has moved
  // on, is indistinguishable from "nothing to do".
  const PROBE = {shortRange: "2026-08-24T12:00:00Z"};

  test("a reach behind the probe is retried even when nothing is written",
    async () => {
      const stored = buildStoreDocument({
        source: "nwm", reachId: "1", product: "shortRange",
        payload: {}, unit: "CFS",
        referenceTime: "2026-08-24T06:00:00Z", fetchedAt: NOW,
      });
      // Upstream still serves 06Z; the store already holds 06Z; the probe says
      // 12Z. Nothing to write, but this reach is stale and must come back.
      const d = deps({
        existing: {"nwm__1__shortRange": stored},
        runFor: () => "2026-08-24T06:00:00Z",
      });

      const report = await runStoreUpdate(
        workListOf({favoriteReachIds: ["1"]}), ["shortRange"], d.deps, PROBE);

      assert.equal(report.written, 0);
      assert.equal(report.skippedLagging, 1);
      assert.deepEqual(report.reachesToRetry, ["1"],
        "without this the reach sits on the previous run for a whole cycle " +
        "with no failure, no retry and no log");
    });

  test("a reach WRITTEN but still behind the probe is also retried",
    async () => {
      const d = deps({runFor: () => "2026-08-24T06:00:00Z"});
      const report = await runStoreUpdate(
        workListOf({favoriteReachIds: ["1"]}), ["shortRange"], d.deps, PROBE);

      assert.equal(report.written, 1, "its own value is stored, as guard 3 says");
      assert.equal(d.writes["nwm__1__shortRange"].runId, "2026-08-24T06:00:00Z",
        "stored under its OWN run, never the probe's");
      assert.deepEqual(report.reachesToRetry, ["1"],
        "written and lagging are not alternatives");
    });

  test("a reach level with the probe is not retried", async () => {
    const d = deps({runFor: () => "2026-08-24T12:00:00Z"});
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["1"]}), ["shortRange"], d.deps, PROBE);
    assert.equal(report.skippedLagging, 0);
    assert.deepEqual(report.reachesToRetry, []);
  });

  // Guessing would queue every reach forever on any product the probe could
  // not sample.
  test("an unknown probe run means 'cannot tell', not 'lagging'", async () => {
    const d = deps({runFor: () => "2026-08-24T06:00:00Z"});
    const report = await runStoreUpdate(
      workListOf({favoriteReachIds: ["1"]}), ["shortRange"], d.deps,
      {shortRange: null});
    assert.equal(report.skippedLagging, 0);
    assert.deepEqual(report.reachesToRetry, []);
  });
});
