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
   * The category of the last notification actually SENT for this user and
   * reach, or null when none was ever sent — or when the last send predates
   * this file and carried no category.
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
  const {category, previous, lastSentAt, frequency, now} = input;

  // Unknown means the ladder was incomplete — no thresholds, or a partial set.
  // It is not a category a user has ever been shown, so it can neither start
  // nor end an event. Staying silent is the honest answer.
  if (category === "Unknown") return "none";

  const wasElevated = previous !== null && isElevated(previous);

  if (!isElevated(category)) {
    // Back to Normal. Worth saying — "it is over" is news, and nothing sends
    // it today. Only when the user was actually told about the event: an
    // all-clear for something they never heard about is noise.
    //
    // Suppressed by "off", because a muted stream should not speak at all
    // except to escalate.
    if (wasElevated && frequency !== "off") return "all-clear";
    return "none";
  }

  // Elevated from here down.

  if (previous === null || !wasElevated) {
    // Entry. Always sent EXCEPT on a muted stream.
    //
    // Decision 19 originally read "always sent", which taken literally meant a
    // stream set to "off" still spoke twice — once when the event began and
    // again if it worsened. Jerson's call 2026-08-29 when that was put to him:
    // off should be truly silent except escalation. A user who mutes a river is
    // saying "stop telling me about this one", and only the safety override
    // outranks that.
    return frequency === "off" ? "none" : "entry";
  }

  if (rank(category) > rank(previous)) {
    // Escalation. Never suppressed, by anything.
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
