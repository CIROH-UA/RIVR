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
  fcmToken?: string;
  firstName: string;
  lastName: string;
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

// Scale factor for testing (set to 1 for production, increase for demos)
const SCALE_FACTOR = 1;

/**
 * Check alerts for a specific time slot
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
    // Get users for this time slot
    const users = await getNotificationUsers(timeSlot);
    logger.info(
      `📱 Found ${users.length} users for slot ${timeSlot}`
    );

    // Check each user's favorite rivers
    for (const user of users) {
      try {
        result.usersChecked++;
        const userAlerts = await checkUserRivers(user);
        result.alertsSent += userAlerts;
      } catch (error) {
        result.errors++;
        logger.error(`❌ Error checking alerts for user ${user.userId}`, {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    logger.info(`🎯 Slot ${timeSlot} check summary`, result);
    return result;
  } catch (error) {
    logger.error(`💥 Fatal error in slot ${timeSlot} check`, {
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
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

    const users: UserSettings[] = [];

    for (const doc of usersSnapshot.docs) {
      const data = doc.data();

      // Only include users with valid FCM tokens and favorite rivers
      if (data.fcmToken &&
          data.favoriteReachIds &&
          Array.isArray(data.favoriteReachIds) &&
          data.favoriteReachIds.length > 0) {
        users.push({
          userId: doc.id,
          enableNotifications: data.enableNotifications,
          notificationFrequency: data.notificationFrequency || 1,
          preferredFlowUnit: data.preferredFlowUnit || "cfs",
          favoriteReachIds: data.favoriteReachIds,
          fcmToken: data.fcmToken,
          firstName: data.firstName || "User",
          lastName: data.lastName || "",
        });
      }
    }

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
 * Check all favorite rivers for a specific user
 * @param {UserSettings} user - User settings and preferences
 * @return {Promise<number>} Number of alerts sent for this user
 */
async function checkUserRivers(user: UserSettings): Promise<number> {
  logger.info(`🏞️ Checking rivers for user ${user.firstName}`, {
    userId: user.userId,
    favoriteCount: user.favoriteReachIds.length,
    flowUnit: user.preferredFlowUnit,
    frequency: user.notificationFrequency,
  });

  let alertsSent = 0;

  for (const reachId of user.favoriteReachIds) {
    try {
      const shouldAlert = await shouldSendAlert(
        reachId,
        user.preferredFlowUnit
      );

      if (shouldAlert) {
        const success = await sendAlert(user, reachId, shouldAlert);
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
 * Check if we should send an alert for a specific river
 * Returns alert details if threshold exceeded, null otherwise
 * @param {string} reachId - The reach identifier
 * @param {string} userFlowUnit - User's preferred flow unit (cfs or cms)
 * @return {Promise<AlertData|null>} Alert data if threshold exceeded
 */
async function shouldSendAlert(
  reachId: string,
  userFlowUnit: "cfs" | "cms"
): Promise<null | AlertData> {
  try {
    // Import NOAA client
    const {getForecast, getReturnPeriods, getRiverName} =
      await import("./noaa-client.js");

    // Get forecast and return period data in parallel
    const [forecastData, returnPeriodData, riverName] = await Promise.all([
      getForecast(reachId),
      getReturnPeriods(reachId),
      getRiverName(reachId),
    ]);

    // Extract max flow from BOTH short and medium
    const maxForecastFlow = getMaxForecastFlow(forecastData);

    if (maxForecastFlow === null) {
      logger.warn(`⚠️ No valid forecast data for reach ${reachId}`);
      return null;
    }

    // Extract thresholds and convert forecast for comparison
    const thresholds = extractReturnPeriodThresholds(returnPeriodData);
    const forecastCms = maxForecastFlow * 0.0283168;

    // Log the forecast and threshold comparison values
    logger.info(`🔍 Forecast vs Return Periods comparison for ${riverName}`, {
      reachId,
      maxForecastFlow_CFS: Math.round(maxForecastFlow * 100) / 100,
      maxForecastFlow_CMS: Math.round(forecastCms * 100) / 100,
      returnPeriods_CMS: Object.entries(thresholds).map(
        ([period, threshold]) => ({
          period,
          threshold_CMS: Math.round(threshold * 100) / 100,
          scaledThreshold_CMS: Math.round(
            (threshold / SCALE_FACTOR) * 100) / 100,
          exceedsThreshold: forecastCms > (threshold / SCALE_FACTOR),
        })),
      scaleFactor: SCALE_FACTOR,
    });

    // Check against each return period threshold - find HIGHEST exceeded
    let highestExceededAlert: AlertData | null = null;

    for (const [returnPeriod, thresholdCms] of Object.entries(thresholds)) {
      // Apply scale factor for testing
      const scaledThreshold = thresholdCms / SCALE_FACTOR;

      if (forecastCms > scaledThreshold) {
        // Convert values to user's preferred unit for notification display
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
          riverName,
        };
        // Continue checking to find highest threshold
      }
    }

    if (highestExceededAlert) {
      logger.info(`🚨 Alert condition met for reach ${reachId}`, {
        riverName: highestExceededAlert.riverName,
        forecastFlow: highestExceededAlert.forecastFlow,
        threshold: highestExceededAlert.threshold,
        returnPeriod: highestExceededAlert.returnPeriod,
        unit: userFlowUnit.toUpperCase(),
        scaleFactor: SCALE_FACTOR,
      });
    }

    return highestExceededAlert;
  } catch (error) {
    logger.error(
      `❌ Error checking alert condition for reach ${reachId}`,
      {error}
    );
    return null;
  }
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
  alertData: AlertData
): Promise<boolean> {
  try {
    // Check if this is a repeat alert (sent within last 6 hours)
    const isRepeat = await checkRecentAlert(user.userId, reachId);
    const stillPrefix = isRepeat ? "Still exceeds" : "Exceeds";
    
    const unitLabel = user.preferredFlowUnit.toUpperCase();

    const message = {
      token: user.fcmToken || "",
      notification: {
        title: `🌊 ${alertData.riverName} Flood Alert`,
        body: `Forecast: ${alertData.forecastFlow} ${unitLabel} ` +
          `(${stillPrefix} ${alertData.returnPeriod} flood threshold)`,
      },
      data: {
        type: "flood_alert",
        reachId: reachId,
        riverName: alertData.riverName,
        forecastFlow: String(alertData.forecastFlow),
        threshold: String(alertData.threshold),
        returnPeriod: alertData.returnPeriod,
        flowUnit: user.preferredFlowUnit,
      },
      android: {
        notification: {
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

    // Log the sent notification
    await logNotification(user.userId, reachId, alertData);

    logger.info(
      `📲 Alert sent to ${user.firstName} for ${alertData.riverName}`,
      {
        userId: user.userId,
        reachId,
        forecastFlow: alertData.forecastFlow,
        unit: unitLabel,
        isRepeat,
      }
    );

    return true;
  } catch (error) {
    logger.error(`❌ Failed to send alert to user ${user.userId}`, {
      error: error instanceof Error ? error.message : String(error),
      reachId,
    });
    return false;
  }
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
 * @param {ForecastData} forecastData - Forecast data from NOAA API
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