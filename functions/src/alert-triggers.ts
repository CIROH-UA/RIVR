// functions/src/alert-triggers.ts
//
// ADR 0011 decision 19 — what deserves a notification.
//
// **The unit of news is a change, not a tick.** A river sitting at Major for
// three days is one event, not seventy-two. Until 2026-08-29 the alert path had
// no concept of this at all: it evaluated on four fixed clock slots and sent on
// every one where a threshold was exceeded. `checkRecentAlert` existed and read
// like a cooldown, but its answer only changed the wording to "still" — nothing
// ever skipped a send. Reach 620569308 alerted Jerson four times a day for
// three consecutive days about a category that never moved.
//
// That matters more once alerts become run-driven: evaluation goes from four
// times a day to hourly, and without this file that would be twenty-four
// notifications a day instead of four.
//
// Four triggers, in priority order:
//
//   entry        Normal -> any alert category. Sent unless the stream is off.
//   escalation   the category RISES. Always sent, and not suppressible by
//                anything at all — the only true override in the system.
//   persistence  still elevated, not risen — at the user's per-stream interval.
//   all-clear    back to Normal. Sent by nothing today.
//
// **Escalation deliberately overrides a user's stated preference.** Action to
// Extreme at 3am must wake someone regardless of what they chose for that
// stream. It is the one place in the system where we do that, and it was
// confirmed explicitly rather than assumed.

import {FLOOD_CATEGORIES, FloodCategory} from "./flow-classification.js";

/** What, if anything, to send. */
export type AlertTrigger =
  | "entry"
  | "escalation"
  | "persistence"
  | "all-clear"
  | "none";

/**
 * A user's notification preference for ONE reach.
 *
 * Per stream, not global: the point is that a river which misbehaves can be
 * quietened without quietening the ones that matter. Stored on the user
 * document beside `favoriteSources` — never on `river_data`, which every
 * signed-in user can read and must stay free of anything user-specific.
 */
export type AlertFrequency = "hourly" | "6h" | "daily" | "change-only" | "off";

/**
 * Minimum quiet time between an entry and its all-clear, and vice versa.
 *
 * Entry and all-clear are event boundaries, not reminders, so they are not
 * governed by the user's reminder interval — but they still need a floor, or a
 * reach hovering on a threshold flips between them on every evaluation.
 *
 * Two hours: long enough that an hourly run cannot alternate, short enough
 * that a genuine flood beginning two hours after one ended is still announced.
 * A rise to a WORSE category is unaffected — escalation is decided before this
 * is ever consulted.
 */
export const FLAP_GUARD_MS = 2 * 3600_000;

/** The default when a user has expressed no preference for a reach. */
export const DEFAULT_FREQUENCY: AlertFrequency = "6h";

/**
 * How long a persistence reminder must wait, per frequency.
 *
 * `change-only` and `off` are Infinity rather than a large number so that "no
 * reminder, ever" cannot be defeated by a long-running event eventually
 * exceeding the interval.
 */
export const FREQUENCY_INTERVAL_MS: Readonly<Record<AlertFrequency, number>> = {
  "hourly": 3600_000,
  "6h": 6 * 3600_000,
  "daily": 24 * 3600_000,
  "change-only": Infinity,
  "off": Infinity,
};

/**
 * Parse a stored preference, falling back to the default.
 *
 * Unrecognised values fall back rather than throwing: a preference written by a
 * newer client must not stop a flood alert from being evaluated.
 *
 * @param {unknown} raw - The stored value.
 * @return {AlertFrequency} A usable frequency.
 */
export function frequencyFrom(raw: unknown): AlertFrequency {
  if (typeof raw !== "string") return DEFAULT_FREQUENCY;
  return raw in FREQUENCY_INTERVAL_MS ?
    raw as AlertFrequency :
    DEFAULT_FREQUENCY;
}

/** Rank on the flood ladder; -1 for Unknown. */
function rank(category: FloodCategory): number {
  return (FLOOD_CATEGORIES as readonly string[]).indexOf(category);
}

/** Whether a category is an alert-worthy level (Action and above). */
function isElevated(category: FloodCategory): boolean {
  return rank(category) >= rank("Action");
}

/** Everything the decision needs. All of it, so the function stays pure. */
export interface TriggerInput {
  /** The category this evaluation produced. */
  category: FloodCategory;
  /**
   * The category we last SAW for this reach, whether or not we told the user.
   *
   * **Distinct from [previous], and the distinction is a safety property.**
   * Independent review 2026-08-30 found that using the last NOTIFIED category
   * for escalation made escalation unreachable for a muted river: nothing is
   * ever sent, so nothing is ever recorded, so every evaluation reads as the
   * start of an event and returns silence. A river muted while calm could
   * climb Action -> Extreme without a word, while three lines of UI copy
   * promised otherwise.
   *
   * Null only before the first evaluation.
   */
  observed: FloodCategory | null;
  /**
   * The category of the last notification actually SENT for this user and
   * reach, or null when none was ever sent — or when the last send predates
   * this file and carried no category.
   *
   * Used for the all-clear rule: "it is over" only goes to someone who was
   * told it started.
   */
  previous: FloodCategory | null;
  /** When that last notification was sent, or null. */
  lastSentAt: Date | null;
  /** This user's preference for THIS reach. */
  frequency: AlertFrequency;
  now: Date;
}

/**
 * Decide what to send, if anything.
 *
 * Pure, so every branch is testable without Firestore, FCM or a clock — the
 * same reason evaluateAlert and the work list are pure.
 *
 * @param {TriggerInput} input - Current state and the user's preference.
 * @return {AlertTrigger} What to send.
 */
export function decideTrigger(input: TriggerInput): AlertTrigger {
  const {category, observed, previous, lastSentAt, frequency, now} = input;

  // Unknown means the ladder was incomplete — no thresholds, or a partial set.
  // It is not a category a user has ever been shown, so it can neither start
  // nor end an event. Staying silent is the honest answer.
  if (category === "Unknown") return "none";

  const wasElevated = previous !== null && isElevated(previous);
  const sawElevated = observed !== null && isElevated(observed);

  if (!isElevated(category)) {
    // Back to Normal. Worth saying — "it is over" is news, and nothing sends
    // it today. Only when the user was actually told about the event: an
    // all-clear for something they never heard about is noise.
    //
    // Suppressed by "off", because a muted stream should not speak at all
    // except to escalate.
    if (!wasElevated || frequency === "off") return "none";

    // Dwell. An all-clear must not follow its own entry inside the user's
    // interval.
    //
    // Independent review 2026-08-30: a reach whose forecast peak sits near its
    // 2-year threshold alternates Action/Normal as each hourly run shifts the
    // peak, and NEITHER entry nor all-clear consulted the interval. That is one
    // notification an hour, alternating "Action Event" and "back to Normal" —
    // twenty-four a day, six times the behaviour this phase set out to fix, and
    // unstoppable even on "change-only", the option a user would pick to avoid
    // exactly this.
    if (lastSentAt !== null &&
        now.getTime() - lastSentAt.getTime() < FLAP_GUARD_MS) {
      return "none";
    }
    return "all-clear";
  }

  // Elevated from here down.

  // Escalation FIRST, and against what we SAW.
  //
  // Ordering matters as much as the field. Entry used to come first and
  // swallowed every rise on a muted river, because `previous` was null and the
  // entry branch returns "none" when the stream is off. Escalation is the one
  // thing no setting may suppress, so nothing may shadow it.
  // Escalation FIRST, and against what we SAW.
  //
  // Ordering matters as much as the field. Entry used to come first and
  // swallowed every rise on a muted river, because `previous` was null and the
  // entry branch returns "none" when the stream is off. Escalation is the one
  // thing no setting may suppress, so nothing may shadow it.
  if (sawElevated && rank(category) > rank(observed as FloodCategory)) {
    return "escalation";
  }

  if (previous === null || !wasElevated) {
    // Entry. Always sent EXCEPT on a muted stream.
    //
    // Decision 19 originally read "always sent", which taken literally meant a
    // stream set to "off" still spoke twice — once when the event began and
    // again if it worsened. Jerson's call 2026-08-29 when that was put to him:
    // off should be truly silent except escalation. A user who mutes a river is
    // saying "stop telling me about this one", and only the safety override
    // outranks that.
    if (frequency === "off") return "none";

    // Same dwell on the way in: a re-entry must not follow an all-clear inside
    // the guard, or the pair simply alternates.
    if (lastSentAt !== null &&
        now.getTime() - lastSentAt.getTime() < FLAP_GUARD_MS) {
      return "none";
    }
    return "entry";
  }

  if (rank(category) > rank(previous)) {
    // Reachable when `observed` is behind `previous` — a device that sent a
    // notification but whose observation write did not land. Kept so the
    // notified state alone can still surface a rise.
    return "escalation";
  }

  // Still elevated and not risen. This includes a DROP that is still elevated
  // (Extreme -> Major): the event has not ended, so it is not an all-clear, and
  // it has not worsened, so it is not an escalation. It reminds on the normal
  // interval like any other continuation.
  const interval = FREQUENCY_INTERVAL_MS[frequency];
  if (!Number.isFinite(interval)) return "none";
  if (lastSentAt === null) return "persistence";
  return now.getTime() - lastSentAt.getTime() >= interval ?
    "persistence" :
    "none";
}
