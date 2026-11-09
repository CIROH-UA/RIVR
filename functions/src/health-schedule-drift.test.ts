// functions/src/health-schedule-drift.test.ts
//
// Backlog item 14. `healthCheck` serves a human-readable schedule so that
// someone asking "what does this system do and when" gets an answer without
// reading the source. It is hand-written prose next to machine-read cron
// strings, and it has now drifted TWICE:
//
//   * it announced a four-slot Mountain-Time schedule for four functions
//     deleted in ADR 0011 Phase 6, and
//   * after the refresh moved to :05 on 2026-11-03 it kept announcing :20 —
//     six lines below a comment warning against exactly that.
//
// Both were found by an audit reading the file, which is not a control. This
// test is the control: it reads the cron expressions out of `index.ts` and
// fails when the prose and the schedule disagree, so neither can move alone.
//
// It is a SOURCE-LEVEL guard and therefore weaker than a behavioural one, in
// the same way `store-health-wiring.test.ts` is. It cannot tell whether the
// cron is the right cron; it can only tell whether the sentence served to an
// operator still describes it. That is the failure that actually happened,
// twice, so that is what is pinned.

import {test, describe} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

const SOURCE = readFileSync(
  resolve(__dirname, "..", "src", "index.ts"), "utf8");

/**
 * The cron expression and timezone declared for an exported function.
 *
 * Deliberately anchored on `export const <name> = functions`, not on a bare
 * search for the name: the name also appears inside the prose this test is
 * checking, and matching that would let the test pass by comparing the
 * sentence with itself.
 */
function scheduleOf(name: string): {cron: string; zone: string} {
  const start = SOURCE.indexOf(`export const ${name} = functions`);
  assert.notEqual(start, -1,
    `${name} is gone or renamed — healthCheck names it to operators, so a ` +
    "rename has to be made in both places");
  const after = SOURCE.indexOf("\nexport ", start + 1);
  const body = SOURCE.slice(start, after === -1 ? SOURCE.length : after);

  const cron = /\.pubsub\.schedule\("([^"]+)"\)/.exec(body);
  const zone = /\.timeZone\("([^"]+)"\)/.exec(body);
  assert.ok(cron, `${name} declares no pubsub schedule`);
  assert.ok(zone, `${name} declares no timeZone — the prose states one, so ` +
    "an implicit default would make it unverifiable");
  return {cron: cron[1], zone: zone[1]};
}

/** `"30 11 * * *"` -> `{minute: 30, hour: 11}`. Hour is null when hourly. */
function cronFields(cron: string): {minute: number; hour: number | null} {
  const parts = cron.trim().split(/\s+/);
  assert.equal(parts.length, 5, `not a 5-field cron: ${cron}`);
  const minute = Number(parts[0]);
  assert.ok(Number.isInteger(minute), `non-literal minute in ${cron}`);
  const hour = /^\d+$/.test(parts[1]) ? Number(parts[1]) : null;
  return {minute, hour};
}

/** The object literal healthCheck serves as `schedule`. */
function healthScheduleProse(): string {
  const start = SOURCE.indexOf("export const healthCheck = functions");
  assert.notEqual(start, -1, "healthCheck is gone or renamed");
  const after = SOURCE.indexOf("\nexport ", start + 1);
  const body = SOURCE.slice(start, after === -1 ? SOURCE.length : after);
  const at = body.indexOf("schedule: {");
  assert.notEqual(at, -1,
    "healthCheck no longer serves a schedule. If that is deliberate, delete " +
    "this test with it; if it is an accident, operators just lost the only " +
    "answer to \"when does this run\" that does not require the source");
  return body.slice(at, body.indexOf("},", at));
}

describe("healthCheck's schedule prose matches the crons it describes", () => {
  test("the refresh minute it announces is the refresh minute", () => {
    const {minute} = cronFields(scheduleOf("storeRefreshHourly").cron);
    const prose = healthScheduleProse();
    const pad = String(minute).padStart(2, "0");
    assert.ok(prose.includes(`(:${pad})`),
      `storeRefreshHourly runs at :${pad} and the prose does not say so:\n` +
      prose);
  });

  test("the GEOGLOWS time it announces is the GEOGLOWS cron, in its own zone",
    () => {
      const {cron, zone} = scheduleOf("storeGeoglowsDaily");
      const {minute, hour} = cronFields(cron);
      assert.equal(zone, "UTC",
        "the prose says UTC; a zone change here silently shifts the hour " +
        "every operator reads");
      assert.notEqual(hour, null, "storeGeoglowsDaily is not hourly");
      const stamp =
        `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
      assert.ok(healthScheduleProse().includes(`${stamp} UTC`),
        `storeGeoglowsDaily runs at ${stamp} UTC and the prose does not ` +
        `say so:\n${healthScheduleProse()}`);
    });

  test("the weekly outlook day and hour it announces are the real ones", () => {
    const {cron, zone} = scheduleOf("sendWeeklyOutlook");
    const {minute, hour} = cronFields(cron);
    const dow = cron.trim().split(/\s+/)[4];
    assert.equal(dow, "5", "cron day-of-week 5 is Friday");
    assert.equal(zone, "America/Denver");
    assert.equal(minute, 0);

    const prose = healthScheduleProse();
    assert.ok(prose.includes("Fridays"), `prose does not say Fridays:\n${prose}`);
    const twelve = hour === null ? null : hour % 12 === 0 ? 12 : hour % 12;
    assert.ok(prose.includes(`${twelve}:00`),
      `sendWeeklyOutlook runs at ${hour}:00 (${twelve} on a 12-hour clock) ` +
      `and the prose does not say so:\n${prose}`);
    assert.ok(prose.includes("Mountain"),
      "America/Denver is Mountain Time; the prose must name the zone or the " +
      "hour is meaningless to a reader");
  });

  test("it names no function that no longer exists", () => {
    // The first drift: four deleted conditions functions kept being
    // advertised. Any `storeX`/`sendX` identifier appearing in the prose must
    // still be an export.
    const prose = healthScheduleProse();
    const named = prose.match(/\b(?:store|send)[A-Z]\w+/g) ?? [];
    assert.ok(named.length > 0,
      "the prose names no function at all, so this guard cannot work — it " +
      "is what caught the deleted-functions drift");
    for (const name of new Set(named)) {
      assert.ok(SOURCE.includes(`export const ${name} =`),
        `healthCheck advertises ${name}, which is not exported from ` +
        "index.ts any more");
    }
  });
});
