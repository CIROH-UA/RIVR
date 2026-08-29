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
  FLAP_GUARD_MS,
  DEFAULT_FREQUENCY,
  FREQUENCY_INTERVAL_MS,
  decideTrigger,
  frequencyFrom,
} from "./alert-triggers.js";
import {FloodCategory} from "./flow-classification.js";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

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
  observed?: FloodCategory | null;
  previous?: FloodCategory | null;
  lastSentAt?: Date | null;
  frequency?: AlertFrequency;
}) {
  const previous = over.previous === undefined ? null : over.previous;
  return decideTrigger({
    category: over.category ?? "Major",
    // Defaults to `previous`: an unmuted river that was notified is also a
    // river that was observed, which is the state these cases describe.
    observed: over.observed === undefined ? previous : over.observed,
    previous,
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
        observed: "Major",
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
      observed: "Major",
      previous: "Major",
      lastSentAt: minutesAgo(5),
      frequency: "daily",
      now: NOW,
    });
    assert.equal(trigger, "escalation");
  });
});

describe("the frequency values are a cross-language contract", () => {
  // The app WRITES these strings into `alertFrequencies` on the user document
  // and this file READS them back. A rename on either side that is not matched
  // on the other does not throw — `frequencyFrom` falls back — so every user
  // who had chosen a setting would silently revert to the default and nobody
  // would see an error anywhere.
  const DART = resolve(__dirname, "..", "..",
    "lib/models/1_domain/shared/alert_frequency.dart");

  test("every wire value in the Dart enum exists here", () => {
    const dart = readFileSync(DART, "utf8");
    const wire = [...dart.matchAll(/^\s*\w+\('([^']+)'\)[,;]?$/gm)]
      .map((m) => m[1]);

    assert.ok(wire.length >= 5,
      `expected the five frequencies in the Dart enum, found ${wire.length}`);
    for (const value of wire) {
      assert.ok(value in FREQUENCY_INTERVAL_MS,
        `the app can write "${value}" but the server does not know it, so ` +
        "that river would silently revert to the default");
    }
  });

  test("and every value here exists in the Dart enum", () => {
    const dart = readFileSync(DART, "utf8");
    for (const value of Object.keys(FREQUENCY_INTERVAL_MS)) {
      assert.ok(dart.includes(`'${value}'`),
        `the server honours "${value}" but no app build can write it`);
    }
  });

  test("the two sides agree on the rule for an UNSET river", () => {
    // This is the one that bit. `DEFAULT_FREQUENCY` is NOT what an unset river
    // gets — `defaultFrequencyFor(notificationFrequency)` is — and until
    // 2026-08-29 the app had no copy of that rule at all, so every row in the
    // settings screen read "Every 6 hours" while the server used "daily" for
    // the default-configured user. The screen stated a frequency nobody would
    // receive.
    const dart = readFileSync(DART, "utf8");
    assert.match(dart,
      /legacyFrequency == 1 \? AlertFrequency\.daily : AlertFrequency\.sixHourly/,
      "the app's defaultFor rule no longer matches defaultFrequencyFor in " +
      "notification-service.ts");
  });

  test("the two sides agree on which value is the default", () => {
    const dart = readFileSync(DART, "utf8");
    assert.match(dart,
      /defaultFrequency = AlertFrequency\.sixHourly/,
      "the Dart default changed; DEFAULT_FREQUENCY here must match");
    assert.equal(DEFAULT_FREQUENCY, "6h");
  });
});

describe("REGRESSION: a muted river must still escalate", () => {
  // Found by independent review 2026-08-30, and it defeated the one guarantee
  // the system makes.
  //
  // `previous` comes from the last notification SENT. A muted river never
  // sends one, so `previous` stays null forever and every evaluation takes the
  // entry branch — which returns "none" because the stream is off. The river
  // can climb Action -> Moderate -> Major -> Extreme and the user hears
  // nothing, while three separate lines of UI copy promise they will.
  //
  // The existing escalation tests all hand `previous` in directly, so they
  // pass on a state production can never produce. That is why this reproduces
  // the state machine as the CALLER drives it, rather than testing the pure
  // function in isolation.

  /**
   * Drive decideTrigger the way checkUserRivers does, including the crucial
   * detail: state only advances when something is actually sent.
   * @param {string[]} categories - The category observed at each evaluation.
   * @param {AlertFrequency} frequency - The user's setting for this reach.
   * @return {string[]} The triggers that fired.
   */
  function run(
    categories: FloodCategory[],
    frequency: AlertFrequency
  ): string[] {
    let observed: FloodCategory | null = null;
    let previous: FloodCategory | null = null;
    let lastSentAt: Date | null = null;
    const fired: string[] = [];

    categories.forEach((category, i) => {
      const now = new Date(NOW.getTime() + i * 3600_000);
      const trigger = decideTrigger({
        category, observed, previous, lastSentAt, frequency, now,
      });
      // The caller records what it SAW on every evaluation, including ones
      // that said nothing — that is the fix this test exists for.
      observed = category;
      if (trigger === "none") return;
      fired.push(trigger);
      previous = category;
      lastSentAt = now;
    });
    return fired;
  }

  test("a river muted while calm still escalates", () => {
    const fired = run(
      ["Normal", "Action", "Moderate", "Major", "Extreme"],
      "off",
    );
    assert.ok(fired.includes("escalation"),
      "a muted river climbed Action -> Extreme and never notified. The UI " +
      "promises an escalation always gets through; it cannot, because " +
      "`previous` is only written when something is SENT.");
  });

  test("an unmuted river escalates as expected — the control", () => {
    const fired = run(
      ["Normal", "Action", "Moderate", "Major", "Extreme"],
      "6h",
    );
    assert.deepEqual(fired,
      ["entry", "escalation", "escalation", "escalation"]);
  });
});

describe("REGRESSION: a river flapping on its threshold cannot spam", () => {
  // Independent review 2026-08-30. A reach whose forecast peak sits near its
  // 2-year threshold alternates Action/Normal as each hourly run shifts the
  // peak. Entry and all-clear consulted no interval at all, so that was one
  // notification per hour, alternating "Action Event" and "back to Normal" —
  // twenty-four a day, against the four a day this phase set out to fix, and
  // unstoppable even on "change-only".

  /**
   * Drive a full day of hourly evaluations, the way the caller does.
   * @param {FloodCategory[]} categories - Category observed each hour.
   * @param {AlertFrequency} frequency - The user's setting.
   * @return {string[]} Triggers that fired.
   */
  function day(
    categories: FloodCategory[],
    frequency: AlertFrequency
  ): string[] {
    let observed: FloodCategory | null = null;
    let previous: FloodCategory | null = null;
    let lastSentAt: Date | null = null;
    const fired: string[] = [];

    categories.forEach((category, i) => {
      const now = new Date(NOW.getTime() + i * 3600_000);
      const trigger = decideTrigger({
        category, observed, previous, lastSentAt, frequency, now,
      });
      observed = category;
      if (trigger === "none") return;
      fired.push(trigger);
      previous = category;
      lastSentAt = now;
    });
    return fired;
  }

  /** 24 hours alternating Action / Normal, one flip per hour. */
  const FLAPPING: FloodCategory[] = Array.from(
    {length: 24},
    (_, i) => (i % 2 === 0 ? "Action" : "Normal") as FloodCategory,
  );

  test("a full day of flapping stays in single figures", () => {
    const fired = day(FLAPPING, "6h");
    assert.ok(fired.length <= 12,
      `a flapping river produced ${fired.length} notifications in a day: ` +
      fired.join(", "));
  });

  test("change-only is not defeated by flapping", () => {
    // The option a user picks precisely to stop this.
    const fired = day(FLAPPING, "change-only");
    assert.ok(fired.length <= 12,
      `"change-only" produced ${fired.length} notifications: ` +
      fired.join(", "));
  });

  test("an all-clear still lands once the river genuinely settles", () => {
    // Six hours of Action, then Normal for the rest of the day. The event
    // ended, and the user must be told.
    const settles: FloodCategory[] = [
      ...Array<FloodCategory>(6).fill("Action"),
      ...Array<FloodCategory>(18).fill("Normal"),
    ];
    assert.ok(day(settles, "6h").includes("all-clear"),
      "a river that genuinely returned to Normal never sent an all-clear");
  });

  test("the guard NEVER delays an escalation", () => {
    // A rise to a worse category is decided before the guard is consulted.
    assert.equal(
      decideTrigger({
        category: "Extreme",
        observed: "Action",
        previous: "Action",
        lastSentAt: new Date(NOW.getTime() - 60_000),
        frequency: "off",
        now: NOW,
      }),
      "escalation");
  });

  test("the guard is shorter than the shortest reminder interval", () => {
    // Otherwise it would silently override a user who chose hourly reminders.
    assert.ok(FLAP_GUARD_MS >= 3600_000);
  });
});
