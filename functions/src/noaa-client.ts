// functions/src/noaa-client.ts

import * as logger from "firebase-functions/logger";

// NOAA API configuration (matches your exact AppConfig)
const NOAA_CONFIG = {
  // Base URLs matching your AppConfig exactly
  noaaReachesBaseUrl: "https://api.water.noaa.gov/nwps/v1",
  nwmReturnPeriodUrl: "https://nwm-api.ciroh.org//return-period",
  nwmApiKey: "***REMOVED***",

  // Request configuration
  timeout: 30000, // 30 second timeout
  headers: {
    "Content-Type": "application/json",
    "User-Agent": "RivrFlow-Functions/1.0",
  },
};

// Types to match real NOAA API structure
interface ForecastValue {
  value: number;
  validTime: string;
}

interface ForecastData {
  values: ForecastValue[];
  units?: string; // Always "ft³/s" (CFS) from NOAA API
}

interface ReturnPeriodData {
  feature_id: string | number; // API returns number, but we accept both
  return_period_2?: number; // All return period values are in CMS (m³/s)
  return_period_5?: number; // All return period values are in CMS (m³/s)
  return_period_10?: number; // All return period values are in CMS (m³/s)
  return_period_25?: number; // All return period values are in CMS (m³/s)
  return_period_50?: number; // All return period values are in CMS (m³/s)
  return_period_100?: number; // All return period values are in CMS (m³/s)
}

// Real NOAA API response structures (matching your Flutter app)
interface NoaaForecastPoint {
  validTime: string;
  flow: number; // NOAA uses 'flow', not 'value'
}

interface NoaaForecastSeries {
  data: NoaaForecastPoint[];
  units?: string;
}

interface NoaaApiResponse {
  // Short range forecast structure
  shortRange?: {
    series?: NoaaForecastSeries;
    [key: string]: unknown;
  };
  // Medium range forecast structure
  mediumRange?: {
    mean?: NoaaForecastSeries;
    [memberKey: string]: NoaaForecastSeries | unknown;
  };
  // Legacy fallback structures
  values?: ForecastValue[];
  units?: string;
  forecast?: {
    values: ForecastValue[];
    units?: string;
  };
  [key: string]: unknown;
}

interface ReturnPeriodItem {
  feature_id: string | number; // API returns number, but we accept both
  [key: string]: unknown;
}

interface ReachResponse {
  name?: string;
  [key: string]: unknown;
}

/**
 * Get forecast data for a reach (always fetches fresh data)
 * Fetches BOTH short_range AND medium_range forecasts for notifications
 * Returns structure that matches app's ForecastResponse format
 *
 * @param {string} reachId - The reach identifier
 */
export async function getForecast(reachId: string): Promise<{
  shortRange: ForecastData | null;
  mediumRange: ForecastData | null;
}> {
  logger.info(`📡 Fetching both forecasts for reach ${reachId}`);

  let shortRangeForecast: ForecastData | null = null;
  let mediumRangeForecast: ForecastData | null = null;

  // Fetch short_range forecast
  try {
    const shortRangeUrl = buildForecastUrl(reachId, "short_range");
    const shortRangeResponse = await fetchWithTimeout(shortRangeUrl);

    if (shortRangeResponse.ok) {
      const shortRangeData = await shortRangeResponse.json();
      const extracted = extractForecastValues(shortRangeData as
        NoaaApiResponse);

      if (extracted.values.length > 0) {
        shortRangeForecast = extracted;
        logger.info(`✅ Fetched short_range forecast for reach ${reachId}`, {
          valueCount: extracted.values.length,
        });
      } else {
        logger.warn(`⚠️ Short_range exists, no valid data for ${reachId}`);
      }
    } else {
      logger.warn(`⚠️ Short failed ${reachId}: ${shortRangeResponse.status}`);
    }
  } catch (error) {
    logger.warn(`⚠️ Error fetching short_range forecast for ${reachId}`, {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  // Fetch medium_range forecast
  try {
    const mediumRangeUrl = buildForecastUrl(reachId, "medium_range");
    const mediumRangeResponse = await fetchWithTimeout(mediumRangeUrl);

    if (mediumRangeResponse.ok) {
      const mediumRangeData = await mediumRangeResponse.json();
      const extracted = extractForecastValues(mediumRangeData as
        NoaaApiResponse);

      if (extracted.values.length > 0) {
        mediumRangeForecast = extracted;
        logger.info(`✅ Successfully fetched medium for ${reachId}`, {
          valueCount: extracted.values.length,
        });
      } else {
        logger.warn(`⚠️ Medium exists, no valid data for reach ${reachId}`);
      }
    } else {
      logger.warn(`⚠️ Medium failed ${reachId}: ${mediumRangeResponse.status}`);
    }
  } catch (error) {
    logger.warn(`⚠️ Error fetching medium forecast for ${reachId}`, {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  // Check if we got any valid data
  if (shortRangeForecast || mediumRangeForecast) {
    logger.info(`✅ Forecast data fetched for reach ${reachId}`, {
      hasShortRange: !!shortRangeForecast,
      hasMediumRange: !!mediumRangeForecast,
      shortRangeValues: shortRangeForecast?.values.length || 0,
      mediumRangeValues: mediumRangeForecast?.values.length || 0,
    });

    return {
      shortRange: shortRangeForecast,
      mediumRange: mediumRangeForecast,
    };
  } else {
    // No data from either forecast
    logger.error(`❌ No valid from short or medium ${reachId}`);
    throw new Error(`No forecast data available for reach ${reachId}`);
  }
}

/**
 * Get return period thresholds for a reach (always fetches fresh data)
 *
 * IMPORTANT: Return period values are ALWAYS in CMS (m³/s) from NWM API
 * Forecast values from getForecast() are ALWAYS in CFS (ft³/s)
 * Conversion factor: CFS * 0.0283168 = CMS
 *
 * @param {string} reachId - The reach identifier
 * @return {Promise<ReturnPeriodData[]>} Array of return period data (in CMS)
 */
export async function getReturnPeriods(
  reachId: string
): Promise<ReturnPeriodData[]> {
  try {
    logger.info(`📡 Fetching fresh return periods for reach ${reachId}`);

    const url = buildReturnPeriodUrl(reachId);
    const response = await fetchWithTimeout(url);

    if (!response.ok) {
      if (response.status === 404) {
        logger.warn(`⚠️ No return periods found for reach ${reachId}`);
        // Return empty array for missing data (graceful degradation)
        return [];
      }
      throw new Error(
        `Return period API error: ${response.status} - ${response.statusText}`
      );
    }

    const data = await response.json();

    // Ensure data is in array format (following your existing pattern)
    const returnPeriodData = Array.isArray(data) ? data : [data];

    // Validate the data structure
    const validData = returnPeriodData.filter(
      (item: unknown): item is ReturnPeriodData =>
        isReturnPeriodItem(item)
    );

    if (validData.length === 0) {
      logger.warn(`⚠️ No valid return period data for reach ${reachId}`);
      return [];
    }

    logger.info(
      `✅ Successfully fetched return periods for reach ${reachId}`,
      {
        periods: Object.keys(validData[0]).filter((k) =>
          k.startsWith("return_period_")
        ),
      }
    );

    return validData;
  } catch (error) {
    logger.error(`❌ Error fetching return periods for reach ${reachId}`, {
      error: error instanceof Error ? error.message : String(error),
    });

    // Don't throw for return periods - they're supplementary data
    // Return empty array so notification checking can continue
    return [];
  }
}

/**
 * Get river name for notification display (always fetches fresh data)
 * @param {string} reachId - The reach identifier
 * @return {Promise<string>} River name or fallback
 */
export async function getRiverName(reachId: string): Promise<string> {
  try {
    logger.info(`📡 Fetching fresh river name for reach ${reachId}`);

    const url = buildReachUrl(reachId);
    const response = await fetchWithTimeout(url);

    if (!response.ok) {
      throw new Error(
        `Reach info API error: ${response.status} - ${response.statusText}`
      );
    }

    const data = await response.json() as ReachResponse;
    const riverName = data.name || `Reach ${reachId}`;

    logger.info(`✅ Successfully fetched river name: ${riverName}`);
    return riverName;
  } catch (error) {
    logger.error(`❌ Error fetching river name for reach ${reachId}`, {
      error: error instanceof Error ? error.message : String(error),
    });

    // Return fallback name instead of throwing
    return `Reach ${reachId}`;
  }
}

/**
 * Build forecast URL (matches your exact AppConfig.getForecastUrl pattern)
 * @param {string} reachId - The reach identifier
 * @param {string} series - The forecast series type
 * @return {string} Complete forecast URL
 */
function buildForecastUrl(reachId: string, series: string): string {
  // Format: https://api.water.noaa.gov/nwps/v1/reaches/{reachId}/streamflow
  // ?series={series}
  return `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${reachId}` +
    `/streamflow?series=${series}`;
}

/**
 * Build return period URL (matches AppConfig.getReturnPeriodUrl pattern)
 * @param {string} reachId - The reach identifier
 * @return {string} Complete return period URL
 */
function buildReturnPeriodUrl(reachId: string): string {
  // Format: https://nwm-api-updt-9f6idmxh.uc.gateway.dev/return-period
  // ?comids={reachId}&key={apiKey}
  return `${NOAA_CONFIG.nwmReturnPeriodUrl}?comids=${reachId}` +
    `&key=${NOAA_CONFIG.nwmApiKey}`;
}

/**
 * Build reach info URL (matches your exact AppConfig.getReachUrl pattern)
 * @param {string} reachId - The reach identifier
 * @return {string} Complete reach info URL
 */
function buildReachUrl(reachId: string): string {
  // Format: https://api.water.noaa.gov/nwps/v1/reaches/{reachId}
  return `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${reachId}`;
}

/**
 * Fetch with timeout (following your existing patterns)
 * @param {string} url - The URL to fetch
 * @return {Promise<Response>} Fetch response
 */
async function fetchWithTimeout(url: string): Promise<Response> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), NOAA_CONFIG.timeout);

  try {
    const response = await fetch(url, {
      headers: NOAA_CONFIG.headers,
      signal: controller.signal,
    });

    clearTimeout(timeoutId);
    return response;
  } catch (error) {
    clearTimeout(timeoutId);

    if (error instanceof Error && error.name === "AbortError") {
      throw new Error(`Request timeout after ${NOAA_CONFIG.timeout}ms`);
    }

    throw error;
  }
}

/**
 * Extract forecast values from NOAA API response
 * Handles shortRange and mediumRange data only
 * @param {NoaaApiResponse} apiResponse - The NOAA API response
 * @return {ForecastData} Extracted forecast data
 */
function extractForecastValues(apiResponse: NoaaApiResponse): ForecastData {
  try {
    // STEP 1: Try shortRange.series.data (used by short_range forecast)
    if (apiResponse.shortRange?.series?.data) {
      const seriesData = apiResponse.shortRange.series.data;
      if (Array.isArray(seriesData) && seriesData.length > 0) {
        // Convert {validTime, flow} to {validTime, value}
        const values = seriesData
          .filter((point) =>
            point.flow !== null &&
            point.flow !== undefined &&
            !isNaN(point.flow)
          )
          .map((point) => ({
            validTime: point.validTime,
            value: point.flow, // NOAA uses 'flow', we use 'value'
          }));

        if (values.length > 0) {
          logger.info("✅ Found shortRange.series.data", {
            pointCount: values.length,
          });
          return {
            values,
            units: apiResponse.shortRange.series.units || "ft³/s",
          };
        }
      }
    }

    // STEP 2: Try mediumRange.mean.data (used by medium_range forecast)
    if (apiResponse.mediumRange?.mean?.data) {
      const meanData = apiResponse.mediumRange.mean.data;
      if (Array.isArray(meanData) && meanData.length > 0) {
        const values = meanData
          .filter((point) =>
            point.flow !== null &&
            point.flow !== undefined &&
            !isNaN(point.flow)
          )
          .map((point) => ({
            validTime: point.validTime,
            value: point.flow,
          }));

        if (values.length > 0) {
          logger.info("✅ Found mediumRange.mean.data", {
            pointCount: values.length,
          });
          return {
            values,
            units: apiResponse.mediumRange.mean.units || "ft³/s",
          };
        }
      }
    }

    // STEP 3: Fall back to ensemble members (member1, member2, etc.)
    if (apiResponse.mediumRange &&
      typeof apiResponse.mediumRange === "object") {
      const memberKeys = Object.keys(apiResponse.mediumRange)
        .filter((key) => key.startsWith("member"))
        .sort(); // member1, member2, etc.

      for (const memberKey of memberKeys) {
        const memberSection = (apiResponse.mediumRange as
          Record<string, unknown>)[memberKey];
        const memberData = (memberSection as
          {data?: NoaaForecastPoint[]})?.data;
        if (Array.isArray(memberData) && memberData.length > 0) {
          const values = memberData
            .filter((point) =>
              point.flow !== null &&
              point.flow !== undefined &&
              !isNaN(point.flow)
            )
            .map((point) => ({
              validTime: point.validTime,
              value: point.flow,
            }));

          if (values.length > 0) {
            logger.info(`✅ Found mediumRange.${memberKey}.data`, {
              pointCount: values.length,
            });
            return {
              values,
              units: (memberSection as {units?: string})?.units || "ft³/s",
            };
          }
        }
      }
    }

    // No forecast data found
    logger.warn("❌ No forecast data found in expected locations", {
      responseKeys: Object.keys(apiResponse || {}),
      shortRange: apiResponse.shortRange ?
        Object.keys(apiResponse.shortRange) : null,
      mediumRange: apiResponse.mediumRange ?
        Object.keys(apiResponse.mediumRange) : null,
    });

    return {
      values: [],
      units: "ft³/s",
    };
  } catch (error) {
    logger.error("❌ Error extracting forecast values", {
      error: error instanceof Error ? error.message : String(error),
    });

    return {
      values: [],
      units: "ft³/s",
    };
  }
}

/**
 * Type guard for return period items
 * @param {unknown} item - Item to check
 * @return {boolean} True if item is valid return period data
 */
function isReturnPeriodItem(item: unknown): item is ReturnPeriodData {
  return (
    item !== null &&
    typeof item === "object" &&
    "feature_id" in item &&
    (typeof (item as ReturnPeriodItem).feature_id === "string" ||
     typeof (item as ReturnPeriodItem).feature_id === "number")
  );
}
