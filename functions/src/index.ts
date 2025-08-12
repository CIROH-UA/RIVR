// functions/src/index.ts

import {onSchedule} from "firebase-functions/v2/scheduler";
import {onRequest} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";

/**
 * Main scheduled function for checking river flood alerts
 *
 * Frequency:
 * - Development: Every 5 minutes (for easy testing)
 * - Production: Every 6 hours (to avoid spam)
 *
 * What it does:
 * 1. Get all users with notifications enabled
 * 2. For each user, check their favorite rivers
 * 3. Compare forecasts vs return period thresholds (scaled for dev)
 * 4. Send FCM notifications when thresholds exceeded
 */
export const checkRiverAlerts = onSchedule({
  // Schedule based on environment
  schedule: process.env.NODE_ENV === "production" ?
    "0 */6 * * *" : // Every 6 hours in production
    "*/2 * * * *", // Every 2 minutes in development

  // Set timezone to handle forecasts consistently
  timeZone: "America/Denver", // Mountain Time (matches NOAA data)

  // Memory and timeout settings
  memory: "1GiB",
  timeoutSeconds: 540, // 9 minutes max (plenty of time for API calls)

}, async (event) => {
  const startTime = Date.now();
  logger.info("🔔 Starting river alert check", {
    scheduledTime: event.scheduleTime,
    environment: process.env.NODE_ENV || "development",
  });

  try {
    // Import notification service (dynamic import to avoid cold start issues)
    const {checkAllUserAlerts} = await import("./notification-service.js");

    // Run the main notification logic
    const result = await checkAllUserAlerts();

    const duration = Date.now() - startTime;
    logger.info("✅ River alert check completed", {
      duration: `${duration}ms`,
      usersChecked: result.usersChecked,
      alertsSent: result.alertsSent,
      errors: result.errors,
    });

    // onSchedule handlers must return void
    return;
  } catch (error) {
    const duration = Date.now() - startTime;
    logger.error("❌ River alert check failed", {
      error: error instanceof Error ? error.message : String(error),
      duration: `${duration}ms`,
    });

    // Don't throw - let the function complete so it doesn't retry immediately
    return;
  }
});

/**
 * Optional: Manual trigger for testing
 * Call this HTTP endpoint to manually trigger a notification check
 * Remove this in production or add authentication
 */
export const triggerAlertCheck = onRequest(async (request, response) => {
  logger.info("🧪 Manual alert check triggered");

  try {
    const {checkAllUserAlerts} = await import("./notification-service.js");
    const result = await checkAllUserAlerts();

    logger.info("✅ Manual alert check completed", result);

    response.json({
      success: true,
      message: "Alert check completed successfully",
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
 * Health check endpoint - useful for monitoring
 */
export const healthCheck = onRequest(async (request, response) => {
  const timestamp = new Date().toISOString();

  logger.info("🏥 Health check requested");

  response.json({
    status: "healthy",
    timestamp,
    environment: process.env.NODE_ENV || "development",
    message: "RivrFlow notification system is running",
  });
});

// Simple development info endpoint
export const devInfo = onRequest(async (request, response) => {
  if (process.env.NODE_ENV === "production") {
    response.status(404).send("Not found");
    return;
  }

  response.json({
    environment: "development",
    scheduleFrequency: "Every 5 minutes",
    scaleFactor: "Return periods divided by 25 for easy testing",
    message: "In development mode - notifications trigger more frequently",
  });
});
