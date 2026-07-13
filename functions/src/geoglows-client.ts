// functions/src/geoglows-client.ts
//
// Server-side GEOGLOWS data client for flood-alert evaluation. GEOGLOWS reaches
// (LINKNO ids) are not on the NWM/NOAA APIs, so we fetch them through the same
// forecast proxy the app uses (functions_geoglows/geoglows_forecast), which
// returns forecast + gumbel return periods straight from GEOGLOWS RFS v2.
//
// IMPORTANT — units: the proxy returns EVERYTHING in m³/s (CMS). To reuse the
// NWM evaluation path unchanged (which expects forecast in CFS and thresholds
// in CMS), we convert the forecast median CMS→CFS here and leave the return
// periods in CMS. evaluateAlert() then treats GEOGLOWS exactly like NWM.

import * as logger from "firebase-functions/logger";

// Public, non-secret proxy URL (same one config.template.dart ships to the app).
const GEOGLOWS_PROXY_URL =
  "https://us-west1-ciroh-rivr-app.cloudfunctions.net/geoglows_forecast";

// The proxy can cold-start (~10–30s: heavy geoglows/xarray/zarr imports), so use
// a generous timeout and retry.
const GEOGLOWS_TIMEOUT_MS = 60000;

const CMS_TO_CFS = 35.3147; // 1 m³/s = 35.3147 ft³/s

interface ForecastValue {
  value: number; // CFS, to match the NWM forecast shape
  validTime: string;
}

interface ForecastData {
  values: ForecastValue[];
  units?: string;
}

// Same shape noaa-client.getReturnPeriods returns (values in CMS).
interface ReturnPeriodData {
  feature_id: string | number;
  return_period_2?: number;
  return_period_5?: number;
  return_period_10?: number;
  return_period_25?: number;
  return_period_50?: number;
  return_period_100?: number;
}

interface GeoglowsProxyResponse {
  river_id: number;
  units: string;
  forecast?: {
    datetime?: string[];
    flow_median?: Array<number | null>;
  };
  return_periods?: Record<string, number>;
}

/** Fetch with timeout + a couple of retries (GEOGLOWS cold starts / 5xx). */
async function fetchGeoglows(reachId: string): Promise<GeoglowsProxyResponse> {
  const url = `${GEOGLOWS_PROXY_URL}?river_id=${encodeURIComponent(reachId)}`;
  const maxAttempts = 3;
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), GEOGLOWS_TIMEOUT_MS);
    try {
      const response = await fetch(url, {signal: controller.signal});
      clearTimeout(timeoutId);

      if (response.ok) {
        return (await response.json()) as GeoglowsProxyResponse;
      }
      // The proxy returns 400 for a bad id, 502 when the river/date isn't found.
      if (response.status < 500 || attempt === maxAttempts) {
        throw new Error(
          `GEOGLOWS proxy ${response.status} for reach ${reachId}`
        );
      }
    } catch (error) {
      clearTimeout(timeoutId);
      lastError = error instanceof Error ? error : new Error(String(error));
      if (attempt === maxAttempts) break;
    }
    await new Promise((r) => setTimeout(r, 1000 * Math.pow(2, attempt - 1)));
  }

  throw lastError || new Error(`GEOGLOWS fetch failed for reach ${reachId}`);
}

/** Forecast + gumbel return periods for one GEOGLOWS reach, shaped to match the
 * NWM path so the shared evaluator consumes them unchanged. Fetched in a SINGLE
 * proxy call (the proxy returns both), avoiding a second cold start. */
export interface GeoglowsReachData {
  forecast: {
    shortRange: ForecastData | null;
    mediumRange: ForecastData | null;
  } | null;
  returnPeriods: ReturnPeriodData[];
  riverName: string;
}

/**
 * Fetch a GEOGLOWS reach's forecast + return periods in one call and shape them
 * like NWM data: forecast median series in CFS (surfaced as shortRange so
 * getMaxForecastFlow picks the horizon peak), gumbel return periods in CMS.
 * GEOGLOWS reaches are unnamed, so riverName falls back to `Stream <id>`.
 */
export async function getGeoglowsReachData(
  reachId: string
): Promise<GeoglowsReachData> {
  const data = await fetchGeoglows(reachId);

  // Forecast median (CMS → CFS).
  const times = data.forecast?.datetime ?? [];
  const medians = data.forecast?.flow_median ?? [];
  const values: ForecastValue[] = [];
  for (let i = 0; i < medians.length; i++) {
    const cms = medians[i];
    if (cms === null || cms === undefined || Number.isNaN(cms)) continue;
    values.push({value: cms * CMS_TO_CFS, validTime: times[i] ?? ""});
  }
  const forecast: GeoglowsReachData["forecast"] = values.length > 0 ?
    {shortRange: {values, units: "ft³/s"}, mediumRange: null} :
    null;

  // Return periods (CMS, same field names/shape as noaa-client).
  const rp = data.return_periods ?? {};
  const record: ReturnPeriodData = {feature_id: reachId};
  let anyRp = false;
  for (const [years, value] of Object.entries(rp)) {
    if (typeof value !== "number" || Number.isNaN(value)) continue;
    if (["2", "5", "10", "25", "50", "100"].includes(years)) {
      (record as unknown as Record<string, number>)[`return_period_${years}`] =
        value;
      anyRp = true;
    }
  }

  logger.info(`✅ GEOGLOWS data for reach ${reachId}`, {
    forecastValues: values.length,
    hasReturnPeriods: anyRp,
  });

  return {
    forecast,
    returnPeriods: anyRp ? [record] : [],
    riverName: `Stream ${reachId}`,
  };
}
