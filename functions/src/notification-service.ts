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
  fcmTokens: string[];
  firstName: string;
  lastName: string;
}

type ReachSource = "nwm" | "geoglows";

/** Resolve a favorite's source; anything not "geoglows" is treated as NWM. */
function sourceOf(user: UserSettings, reachId: string): ReachSource {
  return user.favoriteSources[reachId] === "geoglows" ? "geoglows" : "nwm";
}

/**
 * Reach ids are only unique WITHIN a source (an NWM comid and a GEOGLOWS linkno
 * can collide numerically), so key pre-fetched data by source + id.
 */
function reachKey(source: ReachSource, reachId: string): string {
  return `${source}:${reachId}`;
}

interface ForecastData {
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

interface AlertData {
  forecastFlow: number;
  threshold: number;
  returnPeriod: string;
  riverName: string;
}

/** Pre-fetched data for a single reach, shared across all users. */
interface ReachData {
  forecast: {
    shortRange: ForecastData | null;
    mediumRange: ForecastData | null;
  } | null;
  returnPeriods: unknown[];
  riverName: string;
}

// Scale factor for testing (set to 1 for production, increase for demos)
const SCALE_FACTOR = 1;

/**
 * Check alerts for a specific time slot.
 * Batch-fetches reach data once per unique reach, then evaluates per user.
 * @param {number} timeSlot - Time slot number (1-4)
 * @return {Promise<AlertCheckResult>} Summary of alert check results
 */
export async function checkAlertsForTimeSlot(
  timeSlot: number
): Promise<AlertCheckResult> {
  logger.info(`🔍 Starting alert check for time slot ${timeSlot}`, {
    timeSlot,
    scaleFactor: SCALE_FACTOR,
  });

  const result: AlertCheckResult = {
    usersChecked: 0,
    alertsSent: 0,
    errors: 0,
  };

  try {
    // Step 1: Get eligible users for this time slot
    const users = await getNotificationUsers(timeSlot);
    logger.info(
      `📱 Found ${users.length} eligible users for slot ${timeSlot}`
    );

    if (users.length === 0) {
      logger.info(`🎯 Slot ${timeSlot}: no eligible users, done.`);
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

    // Step 3: Batch-fetch data for all unique reaches (branches NWM/GEOGLOWS)
    const reachDataMap = await batchFetchReachData(
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

    logger.info(`🎯 Slot ${timeSlot} check complete`, {
      ...result,
      uniqueReaches: uniqueReaches.size,
      reachesWithForecast: reachesWithData,
      reachesWithReturnPeriods: reachesWithThresholds,
    });

    return result;
  } catch (error) {
    logger.error(`💥 Fatal error in slot ${timeSlot} check`, {
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
async function batchFetchReachData(
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
 * Get users who should be checked for this time slot
 * Time slot mapping:
 * - Slot 1 (6am): All users (1x, 2x, 3x, 4x daily)
 * - Slot 2 (12pm): 3x and 4x daily users
 * - Slot 3 (6pm): 2x, 3x, and 4x daily users
 * - Slot 4 (12am): 4x daily users only
 * @param {number} timeSlot - Time slot number (1-4)
 * @return {Promise<UserSettings[]>} Array of users for this slot
 */
async function getNotificationUsers(
  timeSlot: number
): Promise<UserSettings[]> {
  try {
    // Determine minimum frequency for this slot
    const minFrequency = getMinFrequencyForSlot(timeSlot);

    const usersSnapshot = await db.collection("users")
      .where("enableNotifications", "==", true)
      .where("notificationFrequency", ">=", minFrequency)
      .get();

    logger.info(
      `📊 User query: ${usersSnapshot.size} docs matched` +
      ` (slot ${timeSlot}, minFrequency ${minFrequency})` +
      ", filtering for valid FCM + favorites..."
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
 * Get minimum frequency required for a time slot
 * @param {number} timeSlot - Time slot number (1-4)
 * @return {number} Minimum notification frequency
 */
function getMinFrequencyForSlot(timeSlot: number): number {
  switch (timeSlot) {
  case 1: // 6am - all users
    return 1;
  case 2: // 12pm - 3x and 4x
    return 3;
  case 3: // 6pm - 2x, 3x, 4x
    return 2;
  case 4: // 12am - 4x only
    return 4;
  default:
    return 1;
  }
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

      const alertData = evaluateAlert(
        reachId,
        reachData,
        user.preferredFlowUnit
      );

      if (alertData) {
        const success = await sendAlert(user, reachId, alertData, source);
        if (success) {
          alertsSent++;
        }
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
function evaluateAlert(
  reachId: string,
  reachData: ReachData,
  userFlowUnit: "cfs" | "cms"
): AlertData | null {
  if (!reachData.forecast) {
    logger.warn(`⚠️ No forecast data for reach ${reachId}`);
    return null;
  }

  const maxForecastFlow = getMaxForecastFlow(reachData.forecast);
  if (maxForecastFlow === null) {
    logger.warn(`⚠️ No valid forecast values for reach ${reachId}`);
    return null;
  }

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
    return null;
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
          exceeds: forecastCms > (threshold / SCALE_FACTOR),
        })),
    });

  // Find HIGHEST exceeded threshold
  let highestExceededAlert: AlertData | null = null;

  for (const [returnPeriod, thresholdCms] of Object.entries(thresholds)) {
    const scaledThreshold = thresholdCms / SCALE_FACTOR;

    if (forecastCms > scaledThreshold) {
      const displayForecast = userFlowUnit === "cfs" ?
        maxForecastFlow :
        forecastCms;

      const displayThreshold = userFlowUnit === "cfs" ?
        scaledThreshold / 0.0283168 :
        scaledThreshold;

      highestExceededAlert = {
        forecastFlow: Math.round(displayForecast),
        threshold: Math.round(displayThreshold),
        returnPeriod,
        riverName: reachData.riverName,
      };
    }
  }

  if (highestExceededAlert) {
    logger.info(`🚨 Alert condition met for reach ${reachId}`, {
      riverName: highestExceededAlert.riverName,
      returnPeriod: highestExceededAlert.returnPeriod,
      forecastFlow: highestExceededAlert.forecastFlow,
      unit: userFlowUnit.toUpperCase(),
    });
  }

  return highestExceededAlert;
}

/**
 * Send FCM alert to user
 * @param {UserSettings} user - User to send alert to
 * @param {string} reachId - River reach identifier
 * @param {AlertData} alertData - Alert details and thresholds
 * @return {Promise<boolean>} True if alert sent successfully
 */
async function sendAlert(
  user: UserSettings,
  reachId: string,
  alertData: AlertData,
  source: ReachSource
): Promise<boolean> {
  // Check if this is a repeat alert (sent within last 6 hours)
  const isRepeat = await checkRecentAlert(user.userId, reachId);
  const stillPrefix = isRepeat ? "Still exceeds" : "Exceeds";
  const unitLabel = user.preferredFlowUnit.toUpperCase();

  const staleTokens: string[] = [];
  let anySent = false;

  // Send to every registered token for this user
  for (const token of user.fcmTokens) {
    try {
      const message = {
        token,
        notification: {
          title: `🌊 ${alertData.riverName} Flood Alert`,
          body: `Forecast: ${alertData.forecastFlow} ${unitLabel} ` +
            `(${stillPrefix} ${alertData.returnPeriod} flood threshold)`,
        },
        data: {
          type: "flood_alert",
          reachId: reachId,
          // So the notification tap opens the correct forecast source.
          source: source,
          riverName: alertData.riverName,
          forecastFlow: String(alertData.forecastFlow),
          threshold: String(alertData.threshold),
          returnPeriod: alertData.returnPeriod,
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
    await logNotification(user.userId, reachId, alertData);
    logger.info(
      `📲 Alert sent to user ${user.userId} for ${alertData.riverName}`,
      {
        userId: user.userId,
        reachId,
        forecastFlow: alertData.forecastFlow,
        unit: unitLabel,
        isRepeat,
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
async function checkRecentAlert(
  userId: string,
  reachId: string
): Promise<boolean> {
  try {
    const sixHoursAgo = new Date(Date.now() - 6 * 60 * 60 * 1000);

    const recentAlerts = await db.collection("notification_logs")
      .where("userId", "==", userId)
      .where("reachId", "==", reachId)
      .where("sentAt", ">", sixHoursAgo)
      .limit(1)
      .get();

    return !recentAlerts.empty;
  } catch (error) {
    logger.error("❌ Error checking recent alerts", {error});
    // Assume not repeat on error (better to send than miss)
    return false;
  }
}

/**
 * Extract max flow value from forecast data
 * @param {object} forecastData - Forecast data from NOAA API
 * @return {number|null} Maximum flow value or null if no valid data
 */
function getMaxForecastFlow(forecastData: {
  shortRange: ForecastData | null;
  mediumRange: ForecastData | null;
}): number | null {
  let maxFlow = -Infinity;

  // Check short range data
  if (forecastData.shortRange?.values) {
    for (const point of forecastData.shortRange.values) {
      if (point.value > maxFlow && point.value > -9000) {
        maxFlow = point.value;
      }
    }
  }

  // Check medium range data
  if (forecastData.mediumRange?.values) {
    for (const point of forecastData.mediumRange.values) {
      if (point.value > maxFlow && point.value > -9000) {
        maxFlow = point.value;
      }
    }
  }

  return maxFlow === -Infinity ? null : maxFlow;
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
  alertData: AlertData
): Promise<void> {
  try {
    await db.collection("notification_logs").add({
      userId,
      reachId,
      riverName: alertData.riverName,
      forecastFlow: alertData.forecastFlow,
      threshold: alertData.threshold,
      returnPeriod: alertData.returnPeriod,
      sentAt: new Date(),
      scaleFactor: SCALE_FACTOR,
    });
  } catch (error) {
    logger.error("❌ Error logging notification", {error});
  }
}
