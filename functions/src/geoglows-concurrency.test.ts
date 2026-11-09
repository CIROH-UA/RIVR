// functions/src/geoglows-concurrency.test.ts
//
// Backlog item 16: `geoglows_forecast` was still being killed for running out
// of memory, three times on 2026-11-03 at 2056, 2071 and 2075 MiB against a
// 2048 limit. It had been "documented as fixed in August"; it was not.
//
// The August change raised the limit from 1 GiB to 2 GiB, which fixed the
// single-request peak and left the real cause alone. **Cloud Run packs
// concurrent requests onto one instance, and the default for a Firebase
// function is EIGHTY.** One in-flight request holds ~1.03 GB of xarray/zarr
// machinery, so two cannot fit in 2 GiB and the second kills the instance
// serving the first. Every overshoot was 8 to 27 MiB, which is what a second
// request arriving part-way through a first one looks like rather than a leak.
//
// WHY THIS TEST LIVES IN THE TYPESCRIPT SUITE. `functions_geoglows/` is
// Python and has no test infrastructure at all, so there is nowhere else to
// put it that anything runs. Reading another language's source off disk is
// already how this project pins cross-language contracts: see
// `hold-policy-drift.test.ts`, which reads the Dart freshness tables. The
// alternative was no guard.
//
// Source-level and therefore weaker than a behavioural one, which is said
// out loud rather than implied: it checks the DECLARATION, not the deployed
// service. The deployed `containerConcurrency` was 80 when this was written
// and only a deploy changes that. What this prevents is the declaration
// drifting back, or a new memory-hungry endpoint being added without it.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

const MAIN_PY = resolve(__dirname, "..", "..", "functions_geoglows", "main.py");
const SOURCE = readFileSync(MAIN_PY, "utf8");

/** One `@https_fn.on_request(...)` decorator and the function it decorates. */
interface Endpoint {
  name: string;
  memory: string | null;
  concurrency: number | null;
}

/**
 * Every HTTP endpoint declared in main.py.
 *
 * Only `https_fn.on_request`: a scheduled function receives one invocation
 * per tick and a Pub/Sub consumer's concurrency is a different question with
 * its own reasoning at the call site.
 */
function httpEndpoints(): Endpoint[] {
  const out: Endpoint[] = [];
  const decorator = /@https_fn\.on_request\(([\s\S]*?)\)\ndef (\w+)/g;
  for (const m of SOURCE.matchAll(decorator)) {
    const body = m[1];
    const memory = /memory=options\.MemoryOption\.(\w+)/.exec(body);
    const concurrency = /concurrency=(\d+)/.exec(body);
    out.push({
      name: m[2],
      memory: memory ? memory[1] : null,
      concurrency: concurrency ? Number(concurrency[1]) : null,
    });
  }
  return out;
}

describe("GEOGLOWS HTTP endpoints declare a safe concurrency", () => {
  test("the parser finds the endpoints at all", () => {
    const names = httpEndpoints().map((e) => e.name);
    assert.ok(names.includes("geoglows_forecast"),
      "geoglows_forecast is gone, renamed, or the decorator shape changed " +
      "and this guard is now reading nothing. A guard matching nothing is " +
      "how a test stops testing.");
    assert.ok(names.length >= 4,
      `expected several HTTP endpoints, found ${names.length}`);
  });

  test("every GB-scale endpoint sets concurrency explicitly", () => {
    // The rule, and why it is drawn at GB rather than per function: a
    // request on any of these holds hundreds of megabytes to over a
    // gigabyte, so the number that can share 2 or 4 GiB is one or two, never
    // the default eighty. The MB_512 endpoints serve a cached blob and are
    // genuinely fine sharing an instance.
    const offenders = httpEndpoints()
      .filter((e) => e.memory?.startsWith("GB_"))
      .filter((e) => e.concurrency === null)
      .map((e) => `${e.name} (${e.memory})`);

    assert.deepEqual(offenders, [],
      "these declare GB-scale memory and inherit Cloud Run's default " +
      "concurrency of 80, so two simultaneous requests can exceed the " +
      "limit and kill the instance. That is item 16: geoglows_forecast was " +
      "killed three times on 2026-11-03 this way, after being recorded as " +
      "fixed in August by a change that only raised the ceiling.");
  });

  test("geoglows_forecast serves one request per instance", () => {
    const fn = httpEndpoints().find((e) => e.name === "geoglows_forecast");
    assert.ok(fn, "geoglows_forecast is missing");
    assert.equal(fn!.memory, "GB_2");
    assert.equal(fn!.concurrency, 1,
      "~1.03 GB per in-flight request against a 2 GiB limit leaves room " +
      "for exactly one");
  });

  test("geoglows_reach_coords does too", () => {
    // Never observed OOMing, across 60 days of logs. Its own comment
    // documents a ~1.1 GB transient parse peak against the same 2 GiB
    // limit, so two concurrent cold parses cannot both fit; what has been
    // protecting it is low traffic, because the app resolves a reach's
    // coordinates once and persists them.
    const fn = httpEndpoints().find((e) => e.name === "geoglows_reach_coords");
    assert.ok(fn, "geoglows_reach_coords is missing");
    assert.equal(fn!.concurrency, 1);
  });

  test("the light endpoints are left alone", () => {
    // The positive control. Without it, "everything declares concurrency"
    // could be satisfied by pinning every function to one instance per
    // request, which would make the cheap cached-blob endpoints needlessly
    // slow and expensive to scale.
    const light = httpEndpoints().filter((e) => e.memory?.startsWith("MB_"));
    assert.ok(light.length > 0, "expected some MB-scale endpoints");
    for (const e of light) {
      assert.equal(e.concurrency, null,
        `${e.name} serves a cached blob at ${e.memory} and can share an ` +
        "instance; pinning it to one request would cost scaling for nothing");
    }
  });
});
