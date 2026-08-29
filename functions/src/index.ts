// functions/src/index.ts
// Using Firebase Functions 1st gen (v1) for compatibility

import * as functions from "firebase-functions/v1";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";
import {
  checkStoreHealth,
  runGeoglowsRefresh,
  runStoreGc,
  runStoreStaticRefresh,
  runStoreRefresh,
  runStoreWriteThrough,
} from "./store-service.js";
import {fetchForStore} from "./store-upstream.js";
import {sourceOfFavourite} from "./notification-service.js";


// Initialize Firebase Admin if not already done
if (!admin.apps.length) {
  admin.initializeApp();
}

/**
 * Alert evaluation is RUN-DRIVEN, not clock-driven.
 *
 * Four scheduled functions used to live here — 6am, noon, 6pm and midnight
 * Mountain — and `notificationFrequency` decided which of them a user appeared
 * in. ADR 0011 Phase 6: evaluation now happens when the upstream run advances,
 * which is what takes the time from publication to alert from up to six hours
 * down to under one. The evaluation itself is triggered at the end of
 * `storeRefreshHourly` and `storeGeoglowsDaily`, so it runs against data that
 * was just written and only when there was something new to write.
 *
 * Guard 4 — "no new run, no evaluation, no sends" — is then free rather than
 * enforced: the store refresh already knows, and does nothing when nothing
 * advanced.
 */

/**
 * Weekly Outlook digest — Fridays at 7:00 AM Mountain Time. One summary push per
 * opted-in user (weeklyOutlookEnabled). Independent from flood alerts.
 */
export const sendWeeklyOutlook = functions
  .runWith({memory: "1GB", timeoutSeconds: 540})
  .pubsub.schedule("0 7 * * 5")
  .timeZone("America/Denver")
  .onRun(async () => {
    const startTime = Date.now();
    logger.info("📅 Starting weekly outlook digest");
    try {
      const {sendWeeklyDigests} = await import("./weekly-digest.js");
      const result = await sendWeeklyDigests();
      logger.info("✅ Weekly outlook digest completed", {
        duration: `${Date.now() - startTime}ms`,
        ...result,
      });
    } catch (error) {
      logger.error("❌ Weekly outlook digest failed", {
        error: error instanceof Error ? error.message : String(error),
        duration: `${Date.now() - startTime}ms`,
      });
    }
  });

/**
 * Validates the admin API key against the ADMIN_API_KEY env variable.
 * Accepts the key via `Authorization: Bearer <key>` or `X-Admin-Key: <key>`.
 * The X-Admin-Key header is useful when Google Cloud IAM consumes the
 * Authorization header before the request reaches the function code.
 * Returns true if authenticated, false otherwise (also sends the 401 response).
 */
function authenticateRequest(
  request: functions.https.Request,
  response: functions.Response
): boolean {
  const adminApiKey = process.env.ADMIN_API_KEY;

  if (!adminApiKey) {
    logger.error("ADMIN_API_KEY environment variable is not configured");
    response.status(500).json({
      success: false,
      error: "Server authentication is not configured",
    });
    return false;
  }

  // Try X-Admin-Key header first (works when IAM consumes Authorization)
  const xAdminKey = request.headers["x-admin-key"] as string | undefined;
  if (xAdminKey) {
    if (xAdminKey === adminApiKey) return true;

    logger.warn("Unauthorized request: invalid X-Admin-Key");
    response.status(401).json({success: false, error: "Invalid API key"});
    return false;
  }

  // Fall back to Authorization: Bearer <key>
  const authHeader = request.headers.authorization;

  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    logger.warn("Unauthorized request: missing admin key");
    response.status(401).json({
      success: false,
      error: "Missing API key. Use Authorization: Bearer <key> or X-Admin-Key: <key>",
    });
    return false;
  }

  const token = authHeader.slice("Bearer ".length);

  if (token !== adminApiKey) {
    logger.warn("Unauthorized request: invalid API key");
    response.status(401).json({
      success: false,
      error: "Invalid API key",
    });
    return false;
  }

  return true;
}

/**
 * Manual trigger for testing specific time slots (requires ADMIN_API_KEY)
 * Usage: POST with Authorization: Bearer <ADMIN_API_KEY> and body {"slot": 1}
 */
export const triggerAlertCheck = functions
  .runWith({memory: "1GB", timeoutSeconds: 540})
  .https.onRequest(
    async (request, response) => {
      if (!authenticateRequest(request, response)) {
        return;
      }

      logger.info("🧪 Manual alert evaluation triggered");

      try {
        // No slot any more — evaluation is driven by the upstream run, so a
        // manual trigger simply evaluates the store as it stands now.
        const {runAlertEvaluation} = await import(
          "./notification-service.js"
        );
        const result = await runAlertEvaluation("manual");

        logger.info("✅ Manual alert evaluation completed", result);

        response.json({
          success: true,
          message: "Alert evaluation completed successfully",
          ...result,
        });
      } catch (error) {
        logger.error("❌ Manual alert check failed", {error});

        response.status(500).json({
          success: false,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  );

/**
 * Manual trigger for the weekly outlook digest (requires ADMIN_API_KEY).
 * Usage: POST with Authorization: Bearer <ADMIN_API_KEY> (or X-Admin-Key).
 */
export const triggerWeeklyOutlook = functions
  .runWith({memory: "1GB", timeoutSeconds: 540})
  .https.onRequest(async (request, response) => {
    if (!authenticateRequest(request, response)) return;

    logger.info("🧪 Manual weekly outlook triggered");
    try {
      const {sendWeeklyDigests} = await import("./weekly-digest.js");
      const result = await sendWeeklyDigests();
      response.json({success: true, ...result});
    } catch (error) {
      logger.error("❌ Manual weekly outlook failed", {error});
      response.status(500).json({
        success: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  });

/**
 * Health check endpoint (requires ADMIN_API_KEY)
 */
export const healthCheck = functions.https.onRequest(
  async (request, response) => {
    if (!authenticateRequest(request, response)) {
      return;
    }

    response.json({
      status: "healthy",
      timestamp: new Date().toISOString(),
      message: "RIVR notification system is running (1st gen)",
      // Was a four-slot Mountain-Time schedule. Those functions were deleted
      // in ADR 0011 Phase 6 and this endpoint kept announcing them — the same
      // failure as the settings screen that advertised deleted check times,
      // and worse, because this is what someone queries to find out what the
      // system does.
      schedule: {
        alerts: "run-driven — evaluated whenever an upstream model publishes, " +
          "at the end of storeRefreshHourly (:20) and storeGeoglowsDaily " +
          "(11:30 UTC). No new run means no evaluation and no sends.",
        weeklyOutlook: "Fridays, 7:00 AM Mountain",
      },
    });
  }
);

/**
 * Daily cleanup of old notification logs (runs at 3:00 AM MT).
 * Deletes documents older than 30 days to keep the collection bounded.
 */
export const cleanupNotificationLogs = functions
  .runWith({memory: "256MB", timeoutSeconds: 120})
  .pubsub.schedule("0 3 * * *")
  .timeZone("America/Denver")
  .onRun(async () => {
    const db = admin.firestore();
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);

    logger.info("🧹 Starting notification_logs cleanup", {
      cutoff: thirtyDaysAgo.toISOString(),
    });

    let totalDeleted = 0;

    // Delete in batches of 500 (Firestore batch limit)
    const batchSize = 500;
    let hasMore = true;

    while (hasMore) {
      const snapshot = await db.collection("notification_logs")
        .where("sentAt", "<", thirtyDaysAgo)
        .limit(batchSize)
        .get();

      if (snapshot.empty) {
        hasMore = false;
        break;
      }

      const batch = db.batch();
      snapshot.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();

      totalDeleted += snapshot.size;

      // If we got fewer than batchSize, we're done
      if (snapshot.size < batchSize) {
        hasMore = false;
      }
    }

    logger.info("✅ Notification logs cleanup completed", {
      deletedCount: totalDeleted,
    });
  });

// ADR 0011 Phase 0 — hourly publish-cadence probe (instrumentation).
// Measures when NOAA runs actually land, and how often the fetch fails, so the
// probe interval and monitoring thresholds rest on a week of data rather than
// on one sitting during a 504 window.
export {probePublishCadence} from "./publish-cadence-probe.js";


// ─────────────────────────────────────────────────────────────────────────────
// ADR 0011 Phase 4 — the cloud store.
//
// Server-only. No client reads these documents until Phase 5, so a fault here
// degrades to "the store is stale", never to a broken app.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Hourly refresh. Reads the Phase 0 probe, refreshes ONLY the products whose
 * upstream run advanced, and does nothing at all otherwise (guard 1).
 *
 * Runs at :20 past, deliberately after the probe's top-of-hour sample so it
 * decides on this hour's evidence rather than last hour's.
 */
export const storeRefreshHourly = functions
  .runWith({memory: "1GB", timeoutSeconds: 540})
  .pubsub.schedule("20 * * * *")
  .timeZone("UTC")
  .onRun(async () => {
    const outcome = await runStoreRefresh({
      fetchProduct: fetchForStore,
    });
    logger.info("🗄️ storeRefreshHourly", {
      ran: outcome.ran,
      reason: outcome.reason,
      written: outcome.report?.written ?? 0,
      failed: outcome.report?.failed ?? 0,
      lagging: outcome.report?.skippedLagging ?? 0,
      usage: outcome.usage,
    });

    await evaluateAlertsAfterStoreRun("nwm run advanced", outcome);
  });

/**
 * Evaluate alerts, but only when the store actually advanced.
 *
 * ADR 0011 Phase 6 guard 4 — "no new run, no evaluation, no sends" — is free
 * here rather than enforced: the store refresh already decided whether anything
 * advanced, so gating on its outcome means an idle upstream costs nothing. It
 * also guarantees ordering, since the documents alerts read were written
 * moments earlier by the same invocation.
 *
 * Failures are logged and swallowed. An alert evaluation must never be able to
 * fail a store run: the store is what the app reads, and a broken notification
 * is a smaller problem than a stale river.
 *
 * @param {string} reason - What triggered it, for the logs.
 * @param {object} outcome - The store run's outcome.
 * @return {Promise<void>} Nothing; outcomes are logged.
 */
async function evaluateAlertsAfterStoreRun(
  reason: string,
  outcome: {ran: boolean; report: {written: number} | null}
): Promise<void> {
  const written = outcome.report?.written ?? 0;
  if (!outcome.ran || written === 0) {
    logger.info("🔕 no new data; alerts not evaluated", {reason, written});
    return;
  }

  try {
    const {runAlertEvaluation} = await import("./notification-service.js");
    const result = await runAlertEvaluation(reason);
    logger.info("🔔 alerts evaluated after store run", {reason, ...result});
  } catch (error) {
    logger.error("❌ alert evaluation failed after a store run", {
      reason,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/**
 * Write-through on favourite (guard 9).
 *
 * Fires when a user document changes and their favourites GREW. A newly
 * favourited reach must have a document within seconds; waiting up to an hour
 * is the experience this exists to remove.
 *
 * Only the added ids are refreshed — a removal must not trigger fetches, and
 * an unrelated settings change must trigger nothing at all.
 */
export const storeWriteThroughOnFavourite = functions
  .runWith({memory: "512MB", timeoutSeconds: 120})
  .firestore.document("users/{userId}")
  .onWrite(async (change) => {
    const before: string[] = change.before.exists ?
      (change.before.data()?.favoriteReachIds ?? []) : [];
    const after: string[] = change.after.exists ?
      (change.after.data()?.favoriteReachIds ?? []) : [];

    const beforeSet = new Set(before.filter((r) => typeof r === "string"));
    const added = after.filter(
      (r) => typeof r === "string" && r !== "" && !beforeSet.has(r));
    if (added.length === 0) return;

    const sources: Record<string, string> =
      change.after.data()?.favoriteSources ?? {};

    for (const reachId of added) {
      const source = sourceOfFavourite(sources, reachId);
      try {
        const outcome = await runStoreWriteThrough(
          {fetchProduct: fetchForStore}, source, reachId);
        logger.info("⚡ write-through", {
          reachId, source, written: outcome.report?.written ?? 0,
        });
      } catch (error) {
        // A write-through failure must not fail the user's favourite action.
        // The hourly refresh picks the reach up on its next tick.
        logger.error("write-through failed; hourly refresh will cover it", {
          reachId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  });

/**
 * Daily GEOGLOWS refresh at 11:30 UTC, gated on the run date.
 *
 * It ran at 01:30 on the assumption the 00Z run had published by then. It never
 * had. Measured 2026-08-29: 01:30 on the 28th returned the 27th's run, 01:30 on
 * the 29th returned the 28th's, and a direct query at 03:07 on the 29th still
 * returned the 28th's. So the store never once held the current day's run — it
 * took yesterday's and held it 24 hours, while any device on the live path
 * picked up the new one as soon as it appeared. Two devices, one river,
 * different numbers: Phase 5 guard 2 failing by construction, every day.
 *
 * 11:30 comes from a measurement this repo already held and an earlier pass of
 * mine did not look up: functions_geoglows/main.py records the daily run
 * publishing at 10:15-10:30 UTC, from S3 Last-Modified on two consecutive days,
 * and the flood builder is scheduled at 11:00 because of it.
 *
 * **The schedule is not trusted on its own.** runGeoglowsRefresh probes ONE
 * reach for its forecast_date and fans out only if it advanced, so a late
 * publication is a cheap no-op that retries rather than another silent day of
 * yesterday's water. An hourly version of this was written first and reverted:
 * it turned 4 fetches a day into 24 to rediscover a number already on disk, and
 * each cold call costs 10-14s against a zarr on S3 — the exact waste the store
 * exists to remove.
 */
export const storeGeoglowsDaily = functions
  .runWith({memory: "1GB", timeoutSeconds: 540})
  .pubsub.schedule("30 11 * * *")
  .timeZone("UTC")
  .onRun(async () => {
    const outcome = await runGeoglowsRefresh({fetchProduct: fetchForStore});
    logger.info("🌍 storeGeoglowsDaily", {
      ran: outcome.ran,
      reason: outcome.reason,
      written: outcome.report?.written ?? 0,
      failed: outcome.report?.failed ?? 0,
    });

    // GEOGLOWS advances on its own daily cycle, not the NWM probe's, so its
    // reaches would otherwise only be evaluated when an unrelated NWM run
    // happened to advance.
    await evaluateAlertsAfterStoreRun("geoglows run advanced", outcome);
  });

/**
 * Daily refresh of the near-static products — river names and flood
 * thresholds (Phase 5 guard 1).
 *
 * Separate from the hourly cycle on purpose: these carry no run identity for
 * the probe to compare and hold a 30-day window, so they are refetched only
 * when a stored document is missing or within a week of expiring. Most days
 * this performs reads and no fetches at all.
 *
 * 02:30 UTC — after the GEOGLOWS pass at 01:30 and before GC at 03:40, so the
 * three daily jobs do not overlap.
 */
export const storeStaticDaily = functions
  .runWith({memory: "512MB", timeoutSeconds: 540})
  .pubsub.schedule("30 2 * * *")
  .timeZone("UTC")
  .onRun(async () => {
    const outcome = await runStoreStaticRefresh({fetchProduct: fetchForStore});
    logger.info("🪨 storeStaticDaily", {
      ran: outcome.ran,
      reason: outcome.reason,
      written: outcome.report?.written ?? 0,
      failed: outcome.report?.failed ?? 0,
    });
  });

/** Daily garbage collection (guard 7). Refuses implausible deletes itself. */
export const storeGcDaily = functions
  .runWith({memory: "512MB", timeoutSeconds: 540})
  .pubsub.schedule("40 3 * * *")
  .timeZone("UTC")
  .onRun(async () => {
    const outcome = await runStoreGc();
    logger.info("🧹 storeGcDaily", outcome);
  });

/**
 * Heartbeat. Logs at error level when the store has not been written for
 * longer than a publish cycle allows, so a store that silently stopped
 * surfaces without anybody watching.
 */
export const storeHeartbeat = functions
  .runWith({memory: "256MB", timeoutSeconds: 120})
  .pubsub.schedule("0 */2 * * *")
  .timeZone("UTC")
  .onRun(async () => {
    await checkStoreHealth();
  });

/** On-demand health read, for answering "is the store fresh right now?". */
export const storeHealth = functions.https.onRequest(async (_req, res) => {
  const health = await checkStoreHealth();
  // Only "down" is a 503. "degraded" — exactly one cause, e.g. a single NOAA
  // series pausing — returns 200 with the status in the body.
  //
  // The ladder distinguished the two from the start and the endpoint
  // collapsed them, so one ordinary upstream pause served an outage page.
  // This repo documents a five-hour NOAA stall as NORMAL and cites it as
  // proof that guard 1 works; past the hold cap the store stops covering
  // that product and says so, which is worth reporting and not worth waking
  // anyone for. A monitor that wants to escalate on degraded can read
  // `status` — a monitor that only reads the HTTP code should not be paged
  // by a bad afternoon at NOAA.
  res.status(health.status === "down" ? 503 : 200).json(health);
});
