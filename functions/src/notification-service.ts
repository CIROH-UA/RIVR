// functions/src/notification-service.ts

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";

// Initialize Firebase Admin if not already done
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const messaging = admin.messaging();

// Types for our data structures
interface UserSettings {
  userId: string;
  enableNotifications: boolean;
  notificationFrequency: number; // 1, 2, 3, or 4 times per day
  preferredFlowUnit: "cfs" | "cms";
  favoriteReachIds: string[];
  // Per-reach data source. Missing/unknown reach ⇒ "nwm" (all pre-GEOGLOWS
  // favorites are NWM). Only non-NWM entries are stored on the user doc.
  favoriteSources: Record<string, string>;
  /**
   * Per-reach notification preference (ADR 0011 decision 19). Only reaches the
   * user has changed appear; anything absent takes DEFAULT_FREQUENCY.
   *
   * Per stream rather than global so a river that misbehaves can be quietened
   * without quietening the ones that matter. Lives on the USER document, never
   * on `river_data`, which every signed-in user can read.
   */
  alertFrequencies: Record<string, string>;
  fcmTokens: string[];
  firstName: string;
  lastName: string;
}

import {FloodCategory, categoryFor} from "./flow-classification.js";
import {readAlertDataFromStore} from "./store-alert-source.js";
import {
  AlertFrequency,
  AlertTrigger,
  DEFAULT_FREQUENCY,
  decideTrigger,
  frequencyFrom,
} from "./alert-triggers.js";

export type ReachSource = "nwm" | "geoglows";

/**
 * Resolve a favorite's source from the per-reach map on a user document;
 * anything not "geoglows" is treated as NWM.
 *
 * Exported in this narrow shape so the ADR 0011 store work list applies the
 * SAME rule rather than restating it. Two implementations of "which network is
 * this reach on" is the drift decision 13 exists to prevent, and it would show
 * up as the store fetching a GEOGLOWS reach from NWM.
 *
 * @param {Record<string, string> | undefined} favoriteSources - The user
 *   document's per-reach source map; only non-NWM entries are stored.
 * @param {string} reachId - The reach to resolve.
 * @return {ReachSource} The resolved source.
 */
export function sourceOfFavourite(
  favoriteSources: Record<string, string> | undefined,
  reachId: string
): ReachSource {
  return favoriteSources?.[reachId] === "geoglows" ? "geoglows" : "nwm";
}

/** Resolve a favorite's source; anything not "geoglows" is treated as NWM. */
function sourceOf(user: UserSettings, reachId: string): ReachSource {
  return sourceOfFavourite(user.favoriteSources, reachId);
}

/**
 * Reach ids are only unique WITHIN a source (an NWM comid and a GEOGLOWS linkno
 * can collide numerically), so key pre-fetched data by source + id. Exported so
 * the weekly-digest reuses the exact same keying.
 */
export function reachKey(source: ReachSource, reachId: string): string {
  return `${source}:${reachId}`;
}

export interface ForecastData {
  values: Array<{
    value: number;
    validTime: string;
  }>;
}

interface AlertCheckResult {
  usersChecked: number;
  alertsSent: number;
  errors: number;
}

export interface AlertData {
  forecastFlow: number;
  threshold: number;
  returnPeriod: string;
  riverName: string;
  /**
   * The flood category the APP would show for this flow — Action, Moderate,
   * Major or Extreme.
   *
   * ADR 0011 Phase 6 guard 3. Until 2026-08-29 an alert carried only a raw
   * recurrence interval and a raw streamflow number, neither of which appears
   * anywhere in the app's vocabulary, so a notification said "Forecast: 147362
   * CFS (exceeds 25-year flood threshold)" while the card the user then opened
   * said "Extreme". Computed through flow-classification.ts, which is pinned
   * to the Dart ladder by test.
   */
  category: FloodCategory;
  /**
   * ISO instant the peak is forecast for, or null when the series carried no
   * usable time. Drives the "peaking in ~14 hours" line, which is the only
   * part of an alert a reader can act on.
   */
  peakAt: string | null;
}

/** Pre-fetched data for a single reach, shared across all users. */
export interface ReachData {
  forecast: {
    shortRange: ForecastData | null;
    mediumRange: ForecastData | null;
  } | null;
  returnPeriods: unknown[];
  riverName: string;
}

/**
 * Check alerts for a specific time slot.
 * Batch-fetches reach data once per unique reach, then evaluates per user.
 * @param {number} timeSlot - Time slot number (1-4)
 * @return {Promise<AlertCheckResult>} Summary of alert check results
 */
export async function runAlertEvaluation(
  reason: string
): Promise<AlertCheckResult> {
  logger.info("🔍 Starting alert evaluation", {reason});

  const result: AlertCheckResult = {
    usersChecked: 0,
    alertsSent: 0,
    errors: 0,
  };

  try {
    // Step 1: every user eligible for notifications. No slot: WHEN to
    // evaluate is decided by the upstream run now, not by a user preference.
    const users = await getNotificationUsers();
    logger.info(`📱 Found ${users.length} eligible users`);

    if (users.length === 0) {
      logger.info("🎯 No eligible users, done.");
      return result;
    }

    // Step 2: Collect all unique (source, reach) pairs across all users.
    // Keyed by source+id because an NWM comid and a GEOGLOWS linkno can collide.
    const uniqueReaches = new Map<string, {source: ReachSource; reachId: string}>();
    for (const user of users) {
      for (const reachId of user.favoriteReachIds) {
        const source = sourceOf(user, reachId);
        uniqueReaches.set(reachKey(source, reachId), {source, reachId});
      }
    }
    logger.info(
      `🏞️ ${uniqueReaches.size} unique reaches to check ` +
      `across ${users.length} users`
    );

    // Step 3: read every reach from the STORE. ADR 0011 Phase 6 guard 1 —
    // "alerts issue zero upstream fetches".
    //
    // This used to be batchFetchReachData, which called NOAA and GEOGLOWS once
    // per reach per slot, four times a day, for data the store already holds
    // for the app. Reading the same documents the app renders is also what
    // makes an alert and the screen agree by construction rather than by
    // coincidence.
    //
    // No live fallback: a missing document means the store has a hole for a
    // reach someone is following, and falling back would hide the failure the
    // store exists to remove. readAlertDataFromStore logs it at ERROR and the
    // reach is skipped.
    const reachDataMap = await readAlertDataFromStore(
      Array.from(uniqueReaches.values())
    );

    // Step 4: Evaluate alerts per user using pre-fetched data
    for (const user of users) {
      try {
        result.usersChecked++;
        const userAlerts = await checkUserRivers(user, reachDataMap);
        result.alertsSent += userAlerts;
      } catch (error) {
        result.errors++;
        logger.error(`❌ Error checking alerts for user ${user.userId}`, {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    // Step 5: Summary logging
    const reachesWithData = Array.from(reachDataMap.values())
      .filter((r) => r.forecast !== null).length;
    const reachesWithThresholds = Array.from(reachDataMap.values())
      .filter((r) => r.returnPeriods.length > 0).length;

    logger.info("🎯 Alert evaluation complete", {
      reason,
      ...result,
      uniqueReaches: uniqueReaches.size,
      reachesWithForecast: reachesWithData,
      reachesWithReturnPeriods: reachesWithThresholds,
    });

    return result;
  } catch (error) {
    logger.error("💥 Fatal error in alert evaluation", {
      reason,
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
}

/**
 * Batch-fetch forecast, return period, and river name data for a list of
 * reach IDs. Each reach is fetched exactly once using Promise.allSettled
 * so one failure doesn't block others.
 */
export async function batchFetchReachData(
  reaches: Array<{source: ReachSource; reachId: string}>
): Promise<Map<string, ReachData>> {
  const {getForecast, getReturnPeriods, getRiverName} =
    await import("./noaa-client.js");
  const {getGeoglowsReachData} = await import("./geoglows-client.js");

  const reachDataMap = new Map<string, ReachData>();

  // Process reaches in parallel batches of 10 to avoid overwhelming APIs
  const BATCH_SIZE = 10;
  for (let i = 0; i < reaches.length; i += BATCH_SIZE) {
    const batch = reaches.slice(i, i + BATCH_SIZE);

    const batchResults = await Promise.allSettled(
      batch.map(async ({source, reachId}) => {
        const key = reachKey(source, reachId);

        // GEOGLOWS: one proxy call returns forecast + return periods + name.
        if (source === "geoglows") {
          const data = await getGeoglowsReachData(reachId);
          return {key, ...data};
        }

        // NWM: fetch the three sources in parallel so a river-name failure
        // doesn't discard forecast data.
        const [forecastResult, returnPeriodsResult, riverNameResult] =
          await Promise.allSettled([
            getForecast(reachId),
            getReturnPeriods(reachId),
            getRiverName(reachId),
          ]);

        const forecast = forecastResult.status === "fulfilled"
          ? forecastResult.value
          : null;
        const returnPeriods = returnPeriodsResult.status === "fulfilled"
          ? returnPeriodsResult.value
          : [];
        const riverName = riverNameResult.status === "fulfilled"
          ? riverNameResult.value
          : `Reach ${reachId}`;

        if (forecastResult.status === "rejected") {
          logger.warn(`⚠️ Forecast fetch failed for reach ${reachId}`, {
            error: forecastResult.reason instanceof Error
              ? forecastResult.reason.message
              : String(forecastResult.reason),
          });
        }

        return {key, forecast, returnPeriods, riverName};
      })
    );

    // Store results in the map
    for (const result of batchResults) {
      if (result.status === "fulfilled") {
        const {key, forecast, returnPeriods, riverName} = result.value;
        reachDataMap.set(key, {forecast, returnPeriods, riverName});
      } else {
        logger.error("❌ Unexpected batch fetch error", {
          error: result.reason instanceof Error
            ? result.reason.message
            : String(result.reason),
        });
      }
    }
  }

  return reachDataMap;
}

/**
 * Every user eligible for notifications.
 *
 * Used to filter by time slot: evaluation ran on four fixed Mountain-Time
 * slots and `notificationFrequency` decided which of them a user appeared in.
 * ADR 0011 Phase 6 replaced the clock with the upstream run, so WHEN to
 * evaluate is no longer a user preference — how often to be *reminded* is, per
 * stream, via `alertFrequencies` (decision 19).
 *
 * @return {Promise<UserSettings[]>} Eligible users.
 */
async function getNotificationUsers(): Promise<UserSettings[]> {
  try {
    // A single equality filter — no composite index needed. The declared
    // users(enableNotifications, notificationFrequency) index is now unused by
    // this query; left in place rather than dropped, because removing an index
    // is not something to undo in a hurry.
    const usersSnapshot = await db.collection("users")
      .where("enableNotifications", "==", true)
      .get();

    logger.info(
      `📊 User query: ${usersSnapshot.size} docs matched, ` +
      "filtering for valid FCM + favorites..."
    );

    const users: UserSettings[] = [];
    let skippedNoToken = 0;
    let skippedNoFavorites = 0;

    for (const doc of usersSnapshot.docs) {
      const data = doc.data();

      // Build token list: prefer fcmTokens array, fall back to legacy fcmToken
      const tokens: string[] = [];
      if (Array.isArray(data.fcmTokens) && data.fcmTokens.length > 0) {
        tokens.push(...data.fcmTokens);
      } else if (data.fcmToken) {
        tokens.push(data.fcmToken);
      }

      // Only include users with valid FCM tokens and favorite rivers
      if (tokens.length === 0) {
        skippedNoToken++;
        logger.info(`👤 Skipped user ${doc.id}: missing FCM token`);
      } else if (!data.favoriteReachIds ||
          !Array.isArray(data.favoriteReachIds) ||
          data.favoriteReachIds.length === 0) {
        skippedNoFavorites++;
        logger.info(`👤 Skipped user ${doc.id}: no favorite rivers`);
      } else {
        users.push({
          userId: doc.id,
          enableNotifications: data.enableNotifications,
          notificationFrequency: data.notificationFrequency || 1,
          preferredFlowUnit: data.preferredFlowUnit || "cfs",
          favoriteReachIds: data.favoriteReachIds,
          favoriteSources: (data.favoriteSources &&
            typeof data.favoriteSources === "object") ?
            data.favoriteSources as Record<string, string> : {},
          alertFrequencies: (data.alertFrequencies &&
            typeof data.alertFrequencies === "object") ?
            data.alertFrequencies as Record<string, string> : {},
          fcmTokens: tokens,
          firstName: data.firstName || "User",
          lastName: data.lastName || "",
        });
      }
    }

    logger.info("📊 User filter results", {
      totalMatched: usersSnapshot.size,
      eligible: users.length,
      skippedNoToken,
      skippedNoFavorites,
    });

    return users;
  } catch (error) {
    logger.error("❌ Error fetching notification users", {error});
    throw error;
  }
}

/**
 * The reminder interval for a reach the user has not set explicitly.
 *
 * Their old global `notificationFrequency` (1-4 checks a day) is read as a
 * signal about how much they want to hear rather than discarded: someone who
 * chose once a day gets daily reminders, everyone else the standard 6-hourly.
 *
 * That setting no longer decides WHEN evaluation happens — the upstream run
 * does — so this is the only meaning it retains, and only until the user picks
 * a per-stream value.
 *
 * @param {number} legacyFrequency - The old 1-4 setting.
 * @return {AlertFrequency} The default reminder interval.
 */
export function defaultFrequencyFor(legacyFrequency: number): AlertFrequency {
  return legacyFrequency === 1 ? "daily" : DEFAULT_FREQUENCY;
}

/**
 * Check all favorite rivers for a specific user using pre-fetched reach data
 * @param {UserSettings} user - User settings and preferences
 * @param {Map<string, ReachData>} reachDataMap - Pre-fetched reach data
 * @return {Promise<number>} Number of alerts sent for this user
 */
async function checkUserRivers(
  user: UserSettings,
  reachDataMap: Map<string, ReachData>
): Promise<number> {
  let alertsSent = 0;

  for (const reachId of user.favoriteReachIds) {
    try {
      const source = sourceOf(user, reachId);
      const reachData = reachDataMap.get(reachKey(source, reachId));
      if (!reachData) {
        logger.warn(`⚠️ No pre-fetched data for reach ${reachId} (${source})`);
        continue;
      }

      // Decision 19. `assessReach` rather than `evaluateAlert` because the
      // trigger model needs to see a river that has returned to Normal — that
      // is what ends an event and sends the all-clear, and evaluateAlert
      // returns null for it, indistinguishable from having no data.
      const {category, alert} = assessReach(
        reachId,
        reachData,
        user.preferredFlowUnit
      );

      const prior = await lastNotified(user.userId, reachId);
      const trigger = decideTrigger({
        category,
        previous: prior?.category ?? null,
        lastSentAt: prior?.sentAt ?? null,
        frequency: reachId in user.alertFrequencies ?
          frequencyFrom(user.alertFrequencies[reachId]) :
          defaultFrequencyFor(user.notificationFrequency),
        now: new Date(),
      });

      if (trigger === "none") continue;

      const success = await sendAlert(user, reachId, source, {
        trigger,
        category,
        riverName: reachData.riverName,
        alert,
      });
      if (success) {
        alertsSent++;
      }
    } catch (error) {
      logger.error(
        `❌ Error checking river ${reachId} for user ${user.userId}`,
        {
          error: error instanceof Error ? error.message : String(error),
        }
      );
    }
  }

  return alertsSent;
}

/**
 * Evaluate whether a reach's forecast exceeds return period thresholds.
 * Pure function — no API calls, uses pre-fetched data.
 */
export function evaluateAlert(
  reachId: string,
  reachData: ReachData,
  userFlowUnit: "cfs" | "cms"
): AlertData | null {
  return assessReach(reachId, reachData, userFlowUnit).alert;
}

/** A reach's category, and the alert to send if it is elevated. */
export interface ReachAssessment {
  /** Always present — including "Normal", which is what ends an event. */
  category: FloodCategory;
  /** The alert payload, or null when the reach is Normal or unrankable. */
  alert: AlertData | null;
}

/**
 * Assess a reach: its category, and the alert if one is warranted.
 *
 * Split out from `evaluateAlert` for decision 19. `evaluateAlert` returns null
 * for a quiet river, which meant the alert loop could not tell "no flood" from
 * "no data" — and could therefore never notice a river returning to Normal, so
 * an all-clear was impossible to send. The category comes back either way.
 *
 * @param {string} reachId - The reach.
 * @param {ReachData} reachData - Pre-read data; no I/O happens here.
 * @param {"cfs" | "cms"} userFlowUnit - The unit to render numbers in.
 * @return {ReachAssessment} Category, and the alert when elevated.
 */
export function assessReach(
  reachId: string,
  reachData: ReachData,
  userFlowUnit: "cfs" | "cms"
): ReachAssessment {
  if (!reachData.forecast) {
    logger.warn(`⚠️ No forecast data for reach ${reachId}`);
    return {category: "Unknown", alert: null};
  }

  const peak = getMaxForecastFlow(reachData.forecast);
  if (peak === null) {
    logger.warn(`⚠️ No valid forecast values for reach ${reachId}`);
    return {category: "Unknown", alert: null};
  }
  const maxForecastFlow = peak.value;

  const thresholds = extractReturnPeriodThresholds(reachData.returnPeriods);
  const forecastCms = maxForecastFlow * 0.0283168;

  if (Object.keys(thresholds).length === 0) {
    logger.warn(
      `⚠️ No return period thresholds for reach ${reachId}` +
      " — cannot evaluate flood level", {
        reachId,
        riverName: reachData.riverName,
        maxForecastFlow_CFS: maxForecastFlow,
      });
    return {category: "Unknown", alert: null};
  }

  // Log the comparison
  logger.info(
    `🔍 Forecast vs thresholds for ${reachData.riverName}`, {
      reachId,
      maxForecastFlow_CFS: Math.round(maxForecastFlow * 100) / 100,
      maxForecastFlow_CMS: Math.round(forecastCms * 100) / 100,
      returnPeriods_CMS: Object.entries(thresholds).map(
        ([period, threshold]) => ({
          period,
          threshold_CMS: Math.round(threshold * 100) / 100,
          exceeds: forecastCms >= threshold,
        })),
    });

  // The category the APP would show for this same flow.
  //
  // Guard 3: the alert and the card must not describe one river in two
  // vocabularies. `thresholds` here is keyed "2-year"/"25-year"; the shared
  // ladder wants plain years, and it wants CMS on both sides — which
  // forecastCms already is, and the stored thresholds natively are.
  const ladder: Record<number, number> = {};
  for (const [label, value] of Object.entries(thresholds)) {
    const years = parseInt(label, 10);
    if (Number.isFinite(years)) ladder[years] = value;
  }
  const category = categoryFor(forecastCms, ladder);

  // Find HIGHEST exceeded threshold
  let highestExceededAlert: AlertData | null = null;

  // Ascending by recurrence year, so the LAST match really is the highest.
  // Keys are "2-year"/"25-year" — non-integer strings, so Object.entries would
  // otherwise iterate in Firestore field order and a shuffled document could
  // report the lowest exceeded threshold as the winner.
  const byYearAscending = Object.entries(thresholds)
    .sort(([a], [b]) => parseInt(a, 10) - parseInt(b, 10));

  for (const [returnPeriod, thresholdCms] of byYearAscending) {
    if (forecastCms >= thresholdCms) {
      const displayForecast = userFlowUnit === "cfs" ?
        maxForecastFlow :
        forecastCms;

      const displayThreshold = userFlowUnit === "cfs" ?
        thresholdCms / 0.0283168 :
        thresholdCms;

      highestExceededAlert = {
        forecastFlow: Math.round(displayForecast),
        threshold: Math.round(displayThreshold),
        returnPeriod,
        riverName: reachData.riverName,
        category,
        peakAt: peak.validTime,
      };
    }
  }

  if (highestExceededAlert) {
    logger.info(`🚨 Alert condition met for reach ${reachId}`, {
      riverName: highestExceededAlert.riverName,
      category: highestExceededAlert.category,
      returnPeriod: highestExceededAlert.returnPeriod,
      forecastFlow: highestExceededAlert.forecastFlow,
      unit: userFlowUnit.toUpperCase(),
    });
  }

  return {category, alert: highestExceededAlert};
}

/**
 * Send FCM alert to user
 * @param {UserSettings} user - User to send alert to
 * @param {string} reachId - River reach identifier
 * @param {AlertData} alertData - Alert details and thresholds
 * @return {Promise<boolean>} True if alert sent successfully
 */
/** Everything a send needs, decided before we get here. */
export interface AlertNotification {
  trigger: AlertTrigger;
  category: FloodCategory;
  riverName: string;
  /** Null only for an all-clear, where there is no exceeded threshold. */
  alert: AlertData | null;
}

/**
 * Compose and send one notification.
 *
 * @param {UserSettings} user - Recipient.
 * @param {string} reachId - The reach.
 * @param {ReachSource} source - Which network, for tap routing.
 * @param {AlertNotification} notification - What to say and why.
 * @return {Promise<boolean>} True when at least one token accepted it.
 */
async function sendAlert(
  user: UserSettings,
  reachId: string,
  source: ReachSource,
  notification: AlertNotification
): Promise<boolean> {
  // Category in the TITLE, timing in the body, and the river named once.
  //
  // The body used to read "Forecast: 147362 CFS (Exceeds 25-year flood
  // threshold)". A raw streamflow number on a lock screen is meaningless —
  // nobody knows whether 147362 CFS is a lot for that river, which is the
  // entire question — and there is room for about two lines.
  //
  // Shape settled with Jerson 2026-08-29:
  //
  //     White River — Major Event          (entry)
  //     Peaking in ~14 hours at 12,400 CFS.
  //
  //     White River — still Major Event    (persistence)
  //     Now peaking in ~6 hours at 13,100 CFS.
  //
  // Escalation and all-clear are new with decision 19 and follow the same
  // shape. "now" rather than "still" is the whole signal that it got worse, so
  // it must not be softened into a synonym.
  //
  // The recurrence interval ("25-year") is deliberately NOT shown. It is still
  // carried in the data payload for the app, but it competed for space with
  // the two things a reader can use: how bad, and how soon.
  const {trigger, category, riverName, alert} = notification;

  const unitLabel = user.preferredFlowUnit.toUpperCase();
  let title: string;
  let body: string;

  if (trigger === "all-clear") {
    title = `${riverName} — back to Normal`;
    body = "Flow has dropped below the Action level.";
  } else {
    const qualifier = trigger === "persistence" ? "still " :
      trigger === "escalation" ? "now " : "";
    title = `${riverName} — ${qualifier}${category} Event`;

    // An elevated trigger always carries an alert; this guard exists so a
    // future caller cannot produce a notification with a blank body.
    const flow = alert === null ? null :
      `${alert.forecastFlow.toLocaleString("en-US")} ${unitLabel}`;
    const when = alert === null ? null : timeToPeak(alert.peakAt);
    const lead = trigger === "persistence" ? "Now peaking" : "Peaking";

    body = flow === null ? `${category} flood level forecast.` :
      when === null ? `Peaking at ${flow}.` :
        `${lead} ${when} at ${flow}.`;
  }

  const staleTokens: string[] = [];
  let anySent = false;

  // Send to every registered token for this user
  for (const token of user.fcmTokens) {
    try {
      const message = {
        token,
        notification: {
          title,
          body,
        },
        data: {
          type: "flood_alert",
          reachId: reachId,
          // So the notification tap opens the correct forecast source.
          source: source,
          riverName,
          // The app reads these; an all-clear legitimately has no exceeded
          // threshold, so they are empty rather than absent or faked.
          category,
          trigger,
          forecastFlow: alert === null ? "" : String(alert.forecastFlow),
          threshold: alert === null ? "" : String(alert.threshold),
          returnPeriod: alert === null ? "" : alert.returnPeriod,
          peakAt: alert?.peakAt ?? "",
          flowUnit: user.preferredFlowUnit,
        },
        android: {
          notification: {
            channelId: "river_alerts",
            icon: "ic_notification",
            color: "#FF6B35",
          },
        },
        apns: {
          payload: {
            aps: {
              badge: 1,
              sound: "default",
            },
          },
        },
      };

      await messaging.send(message);
      anySent = true;
    } catch (error: unknown) {
      const errorCode = (error as {code?: string}).code;

      if (
        errorCode === "messaging/registration-token-not-registered" ||
        errorCode === "messaging/invalid-registration-token" ||
        errorCode === "messaging/invalid-argument"
      ) {
        logger.warn(
          `🗑️ Stale FCM token for user ${user.userId}`,
          {userId: user.userId, errorCode}
        );
        staleTokens.push(token);
      } else {
        const errorMessage = error instanceof Error ?
          error.message : String(error);
        logger.error(`❌ Failed to send to token for user ${user.userId}`, {
          error: errorMessage,
          errorCode,
          reachId,
        });
      }
    }
  }

  // Clean up any stale tokens
  if (staleTokens.length > 0) {
    try {
      const updateData: Record<string, unknown> = {
        fcmTokens: admin.firestore.FieldValue.arrayRemove(staleTokens),
      };
      // If all tokens are stale, disable notifications
      if (staleTokens.length === user.fcmTokens.length) {
        updateData.enableNotifications = false;
      }
      await db.collection("users").doc(user.userId).update(updateData);
      logger.info(
        `🗑️ Removed ${staleTokens.length} stale token(s) for user ${user.userId}`
      );
    } catch (cleanupError) {
      logger.error("❌ Failed to clean up stale tokens", {
        userId: user.userId,
        error: cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError),
      });
    }
  }

  // Log and return
  if (anySent) {
    await logNotification(user.userId, reachId, notification);
    logger.info(
      `📲 ${trigger} sent to user ${user.userId} for ${riverName}`,
      {
        userId: user.userId,
        reachId,
        trigger,
        category,
        forecastFlow: alert?.forecastFlow ?? null,
        unit: unitLabel,
        deviceCount: user.fcmTokens.length - staleTokens.length,
      }
    );
  }

  return anySent;
}

/**
 * Check if we sent an alert for this user/river in the last 6 hours
 * @param {string} userId - User identifier
 * @param {string} reachId - River reach identifier
 * @return {Promise<boolean>} True if recent alert exists
 */
/** The last notification actually sent for one user and reach. */
export interface LastNotification {
  category: FloodCategory | null;
  sentAt: Date;
}

/**
 * Read back the most recent notification for this user and reach.
 *
 * This replaced `checkRecentAlert`, which asked only "was anything sent in the
 * last six hours" and — despite reading like a cooldown — used the answer only
 * to change the wording to "still". Nothing ever skipped a send. decideTrigger
 * needs the CATEGORY as well, because that is what separates an escalation
 * from a repeat.
 *
 * Uses the composite index `notification_logs(userId, reachId, sentAt)`, which
 * is declared in firestore.indexes.json and verified READY in production.
 * A failure here returns null, which reads as "no prior notification" and
 * therefore as an entry — erring towards sending rather than towards silence,
 * because a missed flood alert is the worse failure.
 *
 * Entries written before 2026-08-29 carry no category. They return null and
 * the next evaluation reads as an entry: one extra notification per active
 * reach at rollout, and correct from then on.
 *
 * @param {string} userId - The user.
 * @param {string} reachId - The reach.
 * @return {Promise<LastNotification | null>} The last send, or null.
 */
async function lastNotified(
  userId: string,
  reachId: string
): Promise<LastNotification | null> {
  try {
    const snap = await db.collection("notification_logs")
      .where("userId", "==", userId)
      .where("reachId", "==", reachId)
      .orderBy("sentAt", "desc")
      .limit(1)
      .get();

    if (snap.empty) return null;
    const data = snap.docs[0].data();
    const sentAt = data.sentAt?.toDate?.();
    if (!(sentAt instanceof Date)) return null;

    const category = typeof data.category === "string" ?
      data.category as FloodCategory :
      null;
    return {category, sentAt};
  } catch (error) {
    logger.error("❌ Error reading the last notification", {error});
    return null;
  }
}

/**
 * Extract max flow value from forecast data
 * @param {object} forecastData - Forecast data from NOAA API
 * @return {number|null} Maximum flow value or null if no valid data
 */
/** The peak forecast value and WHEN it arrives. */
export interface ForecastPeak {
  value: number;
  /** ISO instant the peak is forecast for, or null when the point carried none. */
  validTime: string | null;
}

/**
 * The highest forecast value across the short and medium range, WITH its time.
 *
 * The time used to be discarded. It is the only part of an alert a reader can
 * act on — "peaking in about 14 hours" tells you whether to move the truck
 * tonight, where a streamflow number does not — and it was sitting in the
 * payload the whole time.
 *
 * @param {object} forecastData - Short and medium range series.
 * @return {ForecastPeak | null} The peak, or null when there is no valid value.
 */
function getMaxForecastFlow(forecastData: {
  shortRange: ForecastData | null;
  mediumRange: ForecastData | null;
}): ForecastPeak | null {
  let peak: ForecastPeak | null = null;

  for (const series of [forecastData.shortRange, forecastData.mediumRange]) {
    for (const point of series?.values ?? []) {
      // -9999 is NOAA's no-data sentinel; keeping the guard as it was.
      if (point.value <= -9000) continue;
      if (peak === null || point.value > peak.value) {
        peak = {
          value: point.value,
          validTime: typeof point.validTime === "string" &&
            point.validTime !== "" ? point.validTime : null,
        };
      }
    }
  }

  return peak;
}

/**
 * "in ~14 hours" — how long until [validTime], or null when it cannot be said.
 *
 * Deliberately RELATIVE. We do not store the user's timezone anywhere, so an
 * absolute "Saturday 4 PM" would be wrong for every user outside Mountain Time
 * and there would be nothing in the message to reveal it. Relative durations
 * are correct for everyone.
 *
 * Returns null for a peak already in the past (a stale forecast, or one whose
 * peak has passed while the value stayed high) — the caller then omits the
 * timing rather than printing "in ~-3 hours".
 *
 * @param {string | null} validTime - ISO instant of the peak.
 * @param {Date} now - Reference instant.
 * @return {string | null} A human phrase, or null.
 */
export function timeToPeak(
  validTime: string | null,
  now: Date = new Date()
): string | null {
  if (!validTime) return null;
  const at = Date.parse(validTime);
  if (Number.isNaN(at)) return null;

  const ms = at - now.getTime();
  if (ms <= 0) return null;

  const hours = Math.round(ms / 3600_000);
  if (hours < 1) return "within the hour";
  if (hours === 1) return "in ~1 hour";
  if (hours < 48) return `in ~${hours} hours`;

  const days = Math.round(hours / 24);
  return `in ~${days} days`;
}

/**
 * Extract return period thresholds from NOAA data
 * @param {unknown[]} returnPeriodData - Return period data from API
 * @return {Record<string, number>} Mapping of return periods to thresholds
 */
function extractReturnPeriodThresholds(
  returnPeriodData: unknown[]
): Record<string, number> {
  const thresholds: Record<string, number> = {};

  if (Array.isArray(returnPeriodData) && returnPeriodData.length > 0) {
    const data = returnPeriodData[0] as Record<string, unknown>;

    // Extract return periods (looking for return_period_X fields)
    for (const [key, value] of Object.entries(data)) {
      if (key.startsWith("return_period_") && typeof value === "number") {
        const years = key.replace("return_period_", "");
        thresholds[`${years}-year`] = value;
      }
    }
  }

  return thresholds;
}

/**
 * Log notification to prevent duplicates
 * @param {string} userId - User identifier
 * @param {string} reachId - River reach identifier
 * @param {AlertData} alertData - Alert details for logging
 */
async function logNotification(
  userId: string,
  reachId: string,
  notification: AlertNotification
): Promise<void> {
  try {
    const {alert} = notification;
    await db.collection("notification_logs").add({
      userId,
      reachId,
      riverName: notification.riverName,
      // The CATEGORY and the time are what decideTrigger reads back. Without
      // the category there is no way to tell an escalation from a repeat, and
      // the trigger model degrades to "notify every time".
      category: notification.category,
      trigger: notification.trigger,
      forecastFlow: alert?.forecastFlow ?? null,
      threshold: alert?.threshold ?? null,
      returnPeriod: alert?.returnPeriod ?? null,
      sentAt: new Date(),
    });
  } catch (error) {
    logger.error("❌ Error logging notification", {error});
  }
}
