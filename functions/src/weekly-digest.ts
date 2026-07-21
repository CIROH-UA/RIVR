// functions/src/weekly-digest.ts
//
// Weekly Outlook digest — a once-a-week (Fri 7am MT) push summarizing how each
// user's favorite rivers are forecast to behave over the coming week. A single
// notification per user, led by the most "newsworthy" river. Reuses the flood
// alert fetch pipeline (batchFetchReachData) and mirrors the client-side
// WeeklyOutlookService logic (peak-anchored trend, flood category, newsworthiness
// ranking) so the push and the in-app Weekly Outlook page tell the same story.

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import {
  batchFetchReachData,
  reachKey,
  ReachData,
  ReachSource,
} from "./notification-service.js";

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const messaging = admin.messaging();

const CFS_TO_CMS = 0.0283168;
const CATEGORIES = ["Normal", "Action", "Moderate", "Major", "Extreme"];
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

  // One fetch per unique (source, reach) across all users.
  const unique = new Map<string, {source: ReachSource; reachId: string}>();
  for (const user of users) {
    for (const reachId of user.favoriteReachIds) {
      const source = sourceFor(user, reachId);
      unique.set(reachKey(source, reachId), {source, reachId});
    }
  }
  const reachDataMap = await batchFetchReachData(Array.from(unique.values()));

  const now = new Date();
  for (const user of users) {
    try {
      result.usersChecked++;
      const rows = buildRows(user, reachDataMap, now);
      if (rows.length === 0) continue; // nothing loaded for this user
      const {title, body} = compose(rows, user.preferredFlowUnit);
      const sent = await sendDigest(user, title, body);
      if (sent) result.digestsSent++;
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

/** Flood category index for a peak flow (CFS) vs return periods (CMS). Mirrors
 * the client's FlowClassification.indexFor (2/5/10/25-yr ladder). */
function categoryIndexFor(peakCfs: number, returnPeriods: unknown[]): number {
  const peakCms = peakCfs * CFS_TO_CMS;
  const rp = Array.isArray(returnPeriods) && returnPeriods.length > 0 ?
    returnPeriods[0] as Record<string, unknown> : null;
  if (!rp) return -1;
  const t = (y: number): number | null =>
    typeof rp[`return_period_${y}`] === "number" ?
      rp[`return_period_${y}`] as number : null;
  const t2 = t(2); const t5 = t(5); const t10 = t(10); const t25 = t(25);
  if (t2 === null || t5 === null || t10 === null || t25 === null) return -1;
  if (peakCms < t2) return 0;
  if (peakCms < t5) return 1;
  if (peakCms < t10) return 2;
  if (peakCms < t25) return 3;
  return 4;
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
    body = `${top.name} reaches ${CATEGORIES[top.categoryIndex]} ` +
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
