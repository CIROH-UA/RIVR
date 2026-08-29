// functions/src/alert-triggers.test.ts
//
// ADR 0011 decision 19. The behaviour under test is the one Jerson asked for
// after seeing his own notification history: reach 620569308 alerted him four
// times a day for three consecutive days about a category that never moved.
//
// The failure this file guards against has two opposite halves, and both are
// real:
//
//   Too many — a sustained event re-notifying on every evaluation. That is
//   today's behaviour, and it gets four times worse when evaluation becomes
//   run-driven.
//
//   Too few — an escalation swallowed by a user's frequency setting. This is
//   the one that matters: Action to Extreme at 3am must wake someone
//   regardless of what they chose.

import {test, describe} from "node:test";
import assert from "node:assert/strict";

import {
  AlertFrequency,
  DEFAULT_FREQUENCY,
  FREQUENCY_INTERVAL_MS,
  decideTrigger,
  frequencyFrom,
} from "./alert-triggers.js";
import {FloodCategory} from "./flow-classification.js";

const NOW = new Date("2026-08-29T12:00:00Z");

/** Minutes before NOW, as a Date. */
function minutesAgo(m: number): Date {
  return new Date(NOW.getTime() - m * 60_000);
}

/**
 * Shorthand for one decision.
 * @param {Partial<Parameters<typeof decideTrigger>[0]>} over - Overrides.
 * @return {string} The trigger.
 */
function decide(over: {
  category?: FloodCategory;
  previous?: FloodCategory | null;
  lastSentAt?: Date | null;
  frequency?: AlertFrequency;
}) {
  return decideTrigger({
    category: over.category ?? "Major",
    previous: over.previous === undefined ? null : over.previous,
    lastSentAt: over.lastSentAt === undefined ? null : over.lastSentAt,
    frequency: over.frequency ?? DEFAULT_FREQUENCY,
    now: NOW,
  });
}

describe("entry — the event begins", () => {
  test("Normal to any elevated category is entry", () => {
    for (const c of ["Action", "Moderate", "Major", "Extreme"] as const) {
      assert.equal(decide({category: c, previous: "Normal"}), "entry");
    }
  });

  test("a reach never notified before is entry", () => {
    assert.equal(decide({category: "Action", previous: null}), "entry");
  });

  test("entry fires under every frequency except off", () => {
    for (const f of ["hourly", "6h", "daily", "change-only"] as const) {
      assert.equal(decide({category: "Major", previous: "Normal", frequency: f}),
        "entry", `entry was suppressed by frequency "${f}"`);
    }
  });

  test("a muted stream stays silent when an event BEGINS", () => {
    // Decision 19 first read "always sent", which meant a muted river still
    // spoke twice. Jerson's call: off is truly silent except escalation.
    assert.equal(
      decide({category: "Major", previous: "Normal", frequency: "off"}),
      "none");
    assert.equal(
      decide({category: "Extreme", previous: null, frequency: "off"}),
      "none");
  });
});

describe("escalation — never suppressible", () => {
  test("a rise in category is escalation", () => {
    assert.equal(decide({category: "Major", previous: "Action"}),
      "escalation");
    assert.equal(decide({category: "Extreme", previous: "Major"}),
      "escalation");
  });

  test("escalation fires under EVERY frequency, seconds after the last send",
    () => {
      // The guard that matters. A user who set a river to daily, or muted it
      // entirely, must still be woken when it gets worse.
      for (const f of ["hourly", "6h", "daily", "change-only", "off"] as const) {
        assert.equal(
          decide({
            category: "Extreme",
            previous: "Action",
            lastSentAt: minutesAgo(1),
            frequency: f,
          }),
          "escalation",
          `an escalation was suppressed by frequency "${f}" — this is the ` +
          "one thing a user setting must never be able to do");
      }
    });

  test("a rise of several steps is still one escalation", () => {
    assert.equal(decide({category: "Extreme", previous: "Action"}),
      "escalation");
  });
});

describe("persistence — the same event, still going", () => {
  test("nothing while inside the interval", () => {
    assert.equal(
      decide({
        category: "Major", previous: "Major",
        lastSentAt: minutesAgo(60), frequency: "6h",
      }),
      "none");
  });

  test("a reminder once the interval has passed", () => {
    assert.equal(
      decide({
        category: "Major", previous: "Major",
        lastSentAt: minutesAgo(361), frequency: "6h",
      }),
      "persistence");
  });

  test("exactly on the interval reminds", () => {
    assert.equal(
      decide({
        category: "Major", previous: "Major",
        lastSentAt: minutesAgo(360), frequency: "6h",
      }),
      "persistence");
  });

  test("each frequency waits its own interval", () => {
    const cases: Array<[AlertFrequency, number, string]> = [
      ["hourly", 59, "none"],
      ["hourly", 61, "persistence"],
      ["daily", 60 * 23, "none"],
      ["daily", 60 * 25, "persistence"],
    ];
    for (const [frequency, mins, expected] of cases) {
      assert.equal(
        decide({
          category: "Major", previous: "Major",
          lastSentAt: minutesAgo(mins), frequency,
        }),
        expected, `${frequency} at ${mins} minutes`);
    }
  });

  test("change-only and off never remind, however long it runs", () => {
    // Infinity rather than a large number, so a multi-week event cannot
    // eventually exceed the interval and start speaking.
    for (const f of ["change-only", "off"] as const) {
      assert.equal(
        decide({
          category: "Major", previous: "Major",
          lastSentAt: minutesAgo(60 * 24 * 400), frequency: f,
        }),
        "none", `"${f}" reminded after long enough`);
    }
  });

  test("a DROP that is still elevated is persistence, not all-clear", () => {
    // Extreme -> Major. The event has not ended, so it is not an all-clear;
    // it has not worsened, so it is not an escalation.
    assert.equal(
      decide({
        category: "Major", previous: "Extreme",
        lastSentAt: minutesAgo(400), frequency: "6h",
      }),
      "persistence");
    assert.equal(
      decide({
        category: "Major", previous: "Extreme",
        lastSentAt: minutesAgo(10), frequency: "6h",
      }),
      "none");
  });
});

describe("all-clear — the event ends", () => {
  test("elevated to Normal is an all-clear", () => {
    assert.equal(decide({category: "Normal", previous: "Major"}), "all-clear");
  });

  test("no all-clear for an event the user never heard about", () => {
    // Sending "it is over" to someone who was never told it started is noise.
    assert.equal(decide({category: "Normal", previous: null}), "none");
    assert.equal(decide({category: "Normal", previous: "Normal"}), "none");
  });

  test("a muted stream says nothing at all except to escalate", () => {
    assert.equal(
      decide({category: "Normal", previous: "Major", frequency: "off"}),
      "none");
  });

  test("change-only DOES send the all-clear", () => {
    // The end of an event is a change, which is exactly what that option asks
    // for. Only "off" silences it.
    assert.equal(
      decide({category: "Normal", previous: "Major", frequency: "change-only"}),
      "all-clear");
  });
});

describe("Unknown — an incomplete ladder", () => {
  test("Unknown never triggers anything", () => {
    // Not a category any user has been shown, so it can neither begin nor end
    // an event. Reachable whenever a reach lacks the full 2/5/10/25 set.
    assert.equal(decide({category: "Unknown", previous: null}), "none");
    assert.equal(decide({category: "Unknown", previous: "Major"}), "none");
  });

  test("an event is not ended by the thresholds going missing", () => {
    // The important half: losing the thresholds must not read as "back to
    // Normal" and fire a false all-clear while the river is still high.
    assert.notEqual(decide({category: "Unknown", previous: "Extreme"}),
      "all-clear");
  });
});

describe("frequency parsing", () => {
  test("known values pass through", () => {
    for (const f of Object.keys(FREQUENCY_INTERVAL_MS) as AlertFrequency[]) {
      assert.equal(frequencyFrom(f), f);
    }
  });

  test("anything unrecognised falls back rather than throwing", () => {
    // A preference written by a newer client must not stop a flood alert from
    // being evaluated.
    assert.equal(frequencyFrom(undefined), DEFAULT_FREQUENCY);
    assert.equal(frequencyFrom(null), DEFAULT_FREQUENCY);
    assert.equal(frequencyFrom(""), DEFAULT_FREQUENCY);
    assert.equal(frequencyFrom("weekly"), DEFAULT_FREQUENCY);
    assert.equal(frequencyFrom(42), DEFAULT_FREQUENCY);
  });

  test("the default is 6-hourly", () => {
    assert.equal(DEFAULT_FREQUENCY, "6h");
  });
});

describe("the three-day event that started all this", () => {
  test("hourly evaluation of an unchanging Major sends 4 in 24h, not 24", () => {
    // Reach 620569308's real shape: elevated and unmoving. Evaluated every
    // hour for a day on the default 6-hourly setting.
    let previous: FloodCategory | null = "Normal";
    let lastSentAt: Date | null = null;
    const sent: string[] = [];

    for (let hour = 0; hour < 24; hour++) {
      const now = new Date(NOW.getTime() + hour * 3600_000);
      const trigger = decideTrigger({
        category: "Major",
        previous,
        lastSentAt,
        frequency: "6h",
        now,
      });
      if (trigger !== "none") {
        sent.push(trigger);
        previous = "Major";
        lastSentAt = now;
      }
    }

    assert.deepEqual(sent,
      ["entry", "persistence", "persistence", "persistence"],
      "a day of hourly evaluation on an unchanging category should be one " +
      "entry plus a reminder every six hours");
  });

  test("an escalation mid-event lands immediately, between reminders", () => {
    const trigger = decideTrigger({
      category: "Extreme",
      previous: "Major",
      lastSentAt: minutesAgo(5),
      frequency: "daily",
      now: NOW,
    });
    assert.equal(trigger, "escalation");
  });
});
