// functions/src/weekly-digest.ts
//
// Weekly Outlook digest — a once-a-week (Fri 7am MT) push summarizing how each
// user's favorite rivers are forecast to behave over the coming week. A single
// notification per user, led by the most "newsworthy" river.
//
// Reads the SAME store the alert path and the app read (ADR 0011 Phase 6), and
// classifies through the SAME shared ladder, so the digest, the alert and the
// card cannot describe one river three different ways. It used to fetch NOAA
// and GEOGLOWS itself via batchFetchReachData and carry its own copy of the
// 2/5/10/25-year ladder — the third implementation of one rule, named in
// decision 13.
//
// Still mirrors the client-side WeeklyOutlookService for the parts that are
// genuinely presentational: peak-anchored trend and newsworthiness ranking.

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import {
  ReachData,
  reachKey,
  ReachSource,
} from "./notification-service.js";
import {readAlertDataFromStore} from "./store-alert-source.js";
import {
  FLOOD_CATEGORIES,
  indexFor,
  ladderFromReturnPeriods,
} from "./flow-classification.js";

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const messaging = admin.messaging();

const CFS_TO_CMS = 0.0283168;
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

interface DigestUser {
  userId: string;
  preferredFlowUnit: "cfs" | "cms";
  favoriteReachIds: string[];
  favoriteSources: Record<string, string>;
  // App-populated display labels (reachId -> "White River" / "Castilla, Peru").
  // Used for the banner because the server can't geocode; falls back to the
  // reach's river name when a label hasn't been written yet.
  favoriteLabels: Record<string, string>;
  weeklyDigestsSinceOpen: number;
  fcmTokens: string[];
}

interface DigestRow {
  name: string;
  peakCfs: number;
  dayLabel: string;
  trend: "rising" | "falling" | "steady";
  categoryIndex: number; // -1 unknown, 0..4
}

export interface DigestResult {
  usersChecked: number;
  digestsSent: number;
  errors: number;
}

/** Main entry: build + send a weekly digest to every opted-in user. */
export async function sendWeeklyDigests(): Promise<DigestResult> {
  const result: DigestResult = {usersChecked: 0, digestsSent: 0, errors: 0};

  const users = await getWeeklyOutlookUsers();
  logger.info(`📅 ${users.length} users opted into the weekly outlook`);
  if (users.length === 0) return result;

  // Engagement back-off: only users "due" this week (see isDueThisWeek).
  const now = new Date();
  const weekIndex = Math.floor(now.getTime() / (7 * 86400000));
  const dueUsers = users.filter(
    (u) => isDueThisWeek(u.weeklyDigestsSinceOpen, weekIndex)
  );
  logger.info(`📬 ${dueUsers.length}/${users.length} due this week`);
  if (dueUsers.length === 0) return result;

  // One fetch per unique (source, reach) across the due users.
  const unique = new Map<string, {source: ReachSource; reachId: string}>();
  for (const user of dueUsers) {
    for (const reachId of user.favoriteReachIds) {
      const source = sourceFor(user, reachId);
      unique.set(reachKey(source, reachId), {source, reachId});
    }
  }
  const reachDataMap = await readAlertDataFromStore(
    Array.from(unique.values()));

  for (const user of dueUsers) {
    try {
      result.usersChecked++;
      const rows = buildRows(user, reachDataMap, now);
      if (rows.length === 0) continue; // nothing loaded for this user
      const {title, body} = compose(rows, user.preferredFlowUnit);
      const sent = await sendDigest(user, title, body);
      if (sent) {
        result.digestsSent++;
        // Count this send; the app resets it to 0 when the user opens the outlook.
        await bumpSinceOpen(user.userId);
      }
    } catch (error) {
      result.errors++;
      logger.error(`❌ Weekly digest failed for ${user.userId}`, {
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  logger.info("🎯 Weekly digest run complete", {...result});
  return result;
}

/**
 * Engagement back-off: weekly until 4 consecutive unopened digests, then
 * biweekly, then monthly after 12. Uses a global week index so the skipped
 * weeks are spread deterministically — no per-user "last sent" bookkeeping.
 */
export function isDueThisWeek(sinceOpen: number, weekIndex: number): boolean {
  if (sinceOpen >= 12) return weekIndex % 4 === 0; // monthly
  if (sinceOpen >= 4) return weekIndex % 2 === 0; // biweekly
  return true; // weekly
}

/** Increment a user's unopened-digest counter (reset to 0 by the app on open). */
async function bumpSinceOpen(userId: string): Promise<void> {
  try {
    await db.collection("users").doc(userId).update({
      weeklyDigestsSinceOpen: admin.firestore.FieldValue.increment(1),
    });
  } catch (e) {
    logger.warn(`Could not bump weeklyDigestsSinceOpen for ${userId}`, {
      error: e instanceof Error ? e.message : String(e),
    });
  }
}

/** Users with the weekly outlook on, a valid token, and at least one favorite. */
async function getWeeklyOutlookUsers(): Promise<DigestUser[]> {
  const snap = await db.collection("users")
    .where("weeklyOutlookEnabled", "==", true)
    .get();

  const users: DigestUser[] = [];
  for (const doc of snap.docs) {
    const data = doc.data();

    const tokens: string[] = [];
    if (Array.isArray(data.fcmTokens) && data.fcmTokens.length > 0) {
      tokens.push(...data.fcmTokens);
    } else if (data.fcmToken) {
      tokens.push(data.fcmToken);
    }
    if (tokens.length === 0) continue;
    if (!Array.isArray(data.favoriteReachIds) ||
        data.favoriteReachIds.length === 0) {
      continue;
    }

    users.push({
      userId: doc.id,
      preferredFlowUnit: data.preferredFlowUnit === "cms" ? "cms" : "cfs",
      favoriteReachIds: data.favoriteReachIds,
      favoriteSources: (data.favoriteSources &&
        typeof data.favoriteSources === "object") ?
        data.favoriteSources as Record<string, string> : {},
      favoriteLabels: (data.favoriteLabels &&
        typeof data.favoriteLabels === "object") ?
        data.favoriteLabels as Record<string, string> : {},
      weeklyDigestsSinceOpen:
        typeof data.weeklyDigestsSinceOpen === "number" ?
          data.weeklyDigestsSinceOpen : 0,
      fcmTokens: tokens,
    });
  }
  return users;
}

function sourceFor(user: DigestUser, reachId: string): ReachSource {
  return user.favoriteSources[reachId] === "geoglows" ? "geoglows" : "nwm";
}

/** Summarize each of a user's favorites, most-newsworthy first. */
function buildRows(
  user: DigestUser,
  reachDataMap: Map<string, ReachData>,
  now: Date
): DigestRow[] {
  const rows: DigestRow[] = [];
  for (const reachId of user.favoriteReachIds) {
    const source = sourceFor(user, reachId);
    const reach = reachDataMap.get(reachKey(source, reachId));
    if (!reach) continue;

    const series = seriesFor(reach);
    if (series.length === 0) continue;

    let peak = series[0];
    for (const p of series) if (p.value > peak.value) peak = p;

    rows.push({
      // Prefer the app-populated label (real name / geocoded place); the
      // server's riverName ("Stream <id>" for GEOGLOWS) is the fallback.
      name: user.favoriteLabels[reachId] ?? reach.riverName,
      peakCfs: peak.value,
      dayLabel: dayLabel(peak.validTime, now),
      trend: trendOf(series),
      categoryIndex: categoryIndexFor(peak.value, reach.returnPeriods),
    });
  }

  rows.sort((a, b) => {
    const byScore = newsworthiness(b) - newsworthiness(a);
    return byScore !== 0 ? byScore : b.peakCfs - a.peakCfs;
  });
  return rows;
}

/** Forecast values in CFS: NWM medium-range (~10d) or, failing that, short-range
 * (also the GEOGLOWS 15-day median series, which the client shapes as shortRange). */
function seriesFor(reach: ReachData): Array<{value: number; validTime: string}> {
  const f = reach.forecast;
  if (!f) return [];
  const medium = f.mediumRange?.values ?? [];
  const short = f.shortRange?.values ?? [];
  const series = medium.length > 0 ? medium : short;
  return series.filter((p) => typeof p.value === "number" && p.value > -9000);
}

/** Peak-anchored trend, identical rule to the client's computeFlowTrend. */
function trendOf(
  series: Array<{value: number; validTime: string}>
): "rising" | "falling" | "steady" {
  if (series.length < 2) return "steady";
  const current = series[0].value;
  const last = series[series.length - 1].value;
  let peak = series[0].value;
  for (const p of series) if (p.value > peak) peak = p.value;

  if (current <= 0) return peak > 0 ? "rising" : "steady";
  if (peak > current * 1.05) return "rising";
  if (last < current * 0.95) return "falling";
  return "steady";
}

/**
 * Flood category index for a peak flow (CFS) against return periods (CMS).
 *
 * Delegates to the SHARED ladder. This file used to carry its own copy — the
 * third implementation of one rule, named in ADR 0011 decision 13 alongside
 * the client's and evaluateAlert's. The copy was faithful, which is exactly why
 * it was dangerous: nothing would have failed when one of the three drifted,
 * and ADR 0002 exists because two of them already had.
 *
 * @param {number} peakCfs - Peak forecast flow, CFS.
 * @param {unknown[]} returnPeriods - Upstream return-period payload, CMS.
 * @return {number} Index 0..4, or -1 when undeterminable.
 */
function categoryIndexFor(peakCfs: number, returnPeriods: unknown[]): number {
  return indexFor(peakCfs * CFS_TO_CMS,
    ladderFromReturnPeriods(returnPeriods));
}

/** Higher = more newsworthy (shown/led first). Mirrors OutlookRow.newsworthiness. */
function newsworthiness(row: DigestRow): number {
  const cat = Math.max(0, Math.min(99, row.categoryIndex)) * 100;
  const trend = row.trend === "rising" ? 30 : row.trend === "steady" ? 10 : 5;
  return cat + trend;
}

function dayLabel(iso: string, now: Date): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  if (d.getUTCFullYear() === now.getUTCFullYear() &&
      d.getUTCMonth() === now.getUTCMonth() &&
      d.getUTCDate() === now.getUTCDate()) {
    return "today";
  }
  return WEEKDAYS[d.getUTCDay()];
}

/** Craft the push — leads with the single most newsworthy river; honest on calm
 * weeks. Useful even unopened. */
function compose(
  rows: DigestRow[],
  unit: "cfs" | "cms"
): {title: string; body: string} {
  const n = rows.length;
  const rising = rows.filter((r) => r.trend === "rising").length;
  const top = rows[0];
  const unitLabel = unit.toUpperCase();
  const fmt = (cfs: number) => {
    const v = unit === "cfs" ? cfs : cfs * CFS_TO_CMS;
    return Math.round(v).toLocaleString("en-US");
  };

  let body: string;
  if (top.categoryIndex >= 1) {
    body = `${top.name} reaches ${FLOOD_CATEGORIES[top.categoryIndex]} ` +
      `${top.dayLabel}. ${n} river${n === 1 ? "" : "s"}, ${rising} rising.`;
  } else if (rising > 0) {
    body = `${top.name} peaks ${fmt(top.peakCfs)} ${unitLabel} ` +
      `${top.dayLabel}. ${rising} of ${n} rising this week.`;
  } else {
    body = `A calm week — all ${n} river${n === 1 ? "" : "s"} ` +
      "steady and normal.";
  }
  return {title: "Your rivers this week", body};
}

/** Send one digest to all of a user's devices; prune stale tokens. */
async function sendDigest(
  user: DigestUser,
  title: string,
  body: string
): Promise<boolean> {
  const staleTokens: string[] = [];
  let anySent = false;

  for (const token of user.fcmTokens) {
    try {
      await messaging.send({
        token,
        notification: {title: `📅 ${title}`, body},
        data: {type: "weekly_outlook"},
        android: {
          notification: {
            channelId: "river_alerts",
            icon: "ic_notification",
            color: "#0E9BB3",
          },
        },
        apns: {payload: {aps: {sound: "default"}}},
      });
      anySent = true;
    } catch (error: unknown) {
      const code = (error as {code?: string}).code;
      if (code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token" ||
          code === "messaging/invalid-argument") {
        staleTokens.push(token);
      } else {
        logger.error(`❌ Weekly digest send failed for ${user.userId}`, {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  if (staleTokens.length > 0) {
    try {
      const update: Record<string, unknown> = {
        fcmTokens: admin.firestore.FieldValue.arrayRemove(staleTokens),
      };
      // If every token is dead, turn the digest off so we stop trying.
      if (staleTokens.length === user.fcmTokens.length) {
        update.weeklyOutlookEnabled = false;
      }
      await db.collection("users").doc(user.userId).update(update);
    } catch (cleanupError) {
      logger.error("❌ Failed to prune stale tokens (weekly)", {
        userId: user.userId,
        error: cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError),
      });
    }
  }

  if (anySent) {
    logger.info(`📲 Weekly digest sent to ${user.userId}`, {body});
  }
  return anySent;
}
