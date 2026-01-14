// functions/src/index.ts

import {onSchedule} from "firebase-functions/v2/scheduler";
import {onRequest} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";

/**
 * Scheduled functions for checking river flood alerts at specific times
 * 
 * Time slots based on user notification frequency preferences:
 * - Slot 1 (6am MT): All users (1x, 2x, 3x, 4x daily)
 * - Slot 2 (12pm MT): 3x and 4x daily users
 * - Slot 3 (6pm MT): 2x, 3x, and 4x daily users
 * - Slot 4 (12am MT): 4x daily users only
 */

// Slot 1: 6:00 AM Mountain Time
export const checkRiverAlerts6am = onSchedule({
  schedule: "0 6 * * *",
  timeZone: "America/Denver",
  memory: "1GiB",
  timeoutSeconds: 540,
}, async (event) => {
  await runAlertCheckForSlot(1, event.scheduleTime);
});

// Slot 2: 12:00 PM Mountain Time
export const checkRiverAlerts12pm = onSchedule({
  schedule: "0 12 * * *",
  timeZone: "America/Denver",
  memory: "1GiB",
  timeoutSeconds: 540,
}, async (event) => {
  await runAlertCheckForSlot(2, event.scheduleTime);
});

// Slot 3: 6:00 PM Mountain Time
export const checkRiverAlerts6pm = onSchedule({
  schedule: "0 18 * * *",
  timeZone: "America/Denver",
  memory: "1GiB",
  timeoutSeconds: 540,
}, async (event) => {
  await runAlertCheckForSlot(3, event.scheduleTime);
});

// Slot 4: 12:00 AM Mountain Time
export const checkRiverAlerts12am = onSchedule({
  schedule: "0 0 * * *",
  timeZone: "America/Denver",
  memory: "1GiB",
  timeoutSeconds: 540,
}, async (event) => {
  await runAlertCheckForSlot(4, event.scheduleTime);
});

/**
 * Shared logic for running alert checks
 */
async function runAlertCheckForSlot(
  slot: number,
  scheduleTime: string
): Promise<void> {
  const startTime = Date.now();
  logger.info(`🔔 Starting river alert check for slot ${slot}`, {
    slot,
    scheduleTime,
  });

  try {
    const {checkAlertsForTimeSlot} = await import("./notification-service.js");
    const result = await checkAlertsForTimeSlot(slot);

    const duration = Date.now() - startTime;
    logger.info(`✅ Slot ${slot} alert check completed`, {
      slot,
      duration: `${duration}ms`,
      usersChecked: result.usersChecked,
      alertsSent: result.alertsSent,
      errors: result.errors,
    });
  } catch (error) {
    const duration = Date.now() - startTime;
    logger.error(`❌ Slot ${slot} alert check failed`, {
      slot,
      error: error instanceof Error ? error.message : String(error),
      duration: `${duration}ms`,
    });
  }
}

/**
 * Manual trigger for testing specific time slots
 * Usage: POST with body {"slot": 1} to test slot 1
 */
export const triggerAlertCheck = onRequest(async (request, response) => {
  logger.info("🧪 Manual alert check triggered");

  try {
    const slot = request.body?.slot || 1;
    
    if (slot < 1 || slot > 4) {
      response.status(400).json({
        success: false,
        error: "Slot must be between 1 and 4",
      });
      return;
    }

    const {checkAlertsForTimeSlot} = await import("./notification-service.js");
    const result = await checkAlertsForTimeSlot(slot);

    logger.info(`✅ Manual check for slot ${slot} completed`, result);

    response.json({
      success: true,
      slot,
      message: `Alert check for slot ${slot} completed successfully`,
      ...result,
    });
  } catch (error) {
    logger.error("❌ Manual alert check failed", {error});

    response.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : String(error),
    });
  }
});

/**
 * Health check endpoint
 */
export const healthCheck = onRequest(async (request, response) => {
  response.json({
    status: "healthy",
    timestamp: new Date().toISOString(),
    message: "RIVR notification system is running",
    schedule: {
      slot1: "6:00 AM MT (all users)",
      slot2: "12:00 PM MT (3x, 4x users)",
      slot3: "6:00 PM MT (2x, 3x, 4x users)",
      slot4: "12:00 AM MT (4x users)",
    },
  });
});