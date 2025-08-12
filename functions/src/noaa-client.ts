// functions/src/noaa-client.ts

import * as logger from "firebase-functions/logger";

// Simple in-memory cache for function duration (resets on each cold start)
const cache = new Map<string, {data: unknown; expires: number}>();

// NOAA API configuration (matches your exact AppConfig)
const NOAA_CONFIG = {
  // Base URLs matching your AppConfig exactly
  noaaReachesBaseUrl: "https://api.water.noaa.gov/nwps/v1",
  nwmReturnPeriodUrl: "https://nwm-api-updt-9f6idmxh.uc.gateway.dev/return-period",
  nwmApiKey: "***REMOVED***",

  // Request configuration
  timeout: 15000, // 15 second timeout
  headers: {
    "Content-Type": "application/json",
    "User-Agent": "RivrFlow-Functions/1.0",
  },
};

// Updated types to match real NOAA API structure
interface ForecastValue {
  value: number;
  validTime: string;
}

interface ForecastData {
  values: ForecastValue[];
  units?: string;
}

interface ReturnPeriodData {
  feature_id: string | number; // API returns number, but we accept both
  return_period_2?: number;
  return_period_5?: number;
  return_period_10?: number;
  return_period_25?: number;
  return_period_50?: number;
  return_period_100?: number;
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
  // Long range forecast structure
  longRange?: {
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
 * Get forecast data for a reach (uses short-range for notification checks)
 * @param {string} reachId - The reach identifier
 * @return {Promise<ForecastData>} Forecast data with values array
 */
export async function getForecast(reachId: string): Promise<ForecastData> {
  const cacheKey = `forecast:${reachId}`;

  // Check cache first (valid for 1 hour)
  const cached = getCachedData(cacheKey);
  if (cached) {
    logger.info(`📦 Using cached forecast for reach ${reachId}`);
    return cached as ForecastData;
  }

  try {
    logger.info(`📡 Fetching forecast for reach ${reachId}`);

    // Use short_range forecast for notification checks (most current/reliable)
    const url = buildForecastUrl(reachId, "short_range");
    const response = await fetchWithTimeout(url);

    if (!response.ok) {
      if (response.status === 404) {
        throw new Error(`Forecast not available for reach ${reachId}`);
      }
      throw new Error(
        `NOAA API error: ${response.status} - ${response.statusText}`
      );
    }

    const data = await response.json();

    // Extract forecast values from NOAA response structure
    const forecastData = extractForecastValues(data as NoaaApiResponse);

    // Cache the result only if we got valid data
    if (forecastData.values.length > 0) {
      setCachedData(cacheKey, forecastData);
      logger.info(`✅ Successfully fetched forecast for reach ${reachId}`, {
        valueCount: forecastData.values.length,
      });
    } else {
      logger.warn(`⚠️ No valid forecast data extracted for reach ${reachId}`);
    }

    return forecastData;
  } catch (error) {
    logger.error(`❌ Error fetching forecast for reach ${reachId}`, {
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
}

/**
 * Get return period thresholds for a reach
 * @param {string} reachId - The reach identifier
 * @return {Promise<ReturnPeriodData[]>} Array of return period data
 */
export async function getReturnPeriods(
  reachId: string
): Promise<ReturnPeriodData[]> {
  const cacheKey = `return-periods:${reachId}`;

  // Check cache first (valid for 24 hours - this data changes rarely)
  const cached = getCachedData(cacheKey);
  if (cached) {
    logger.info(`📦 Using cached return periods for reach ${reachId}`);
    return cached as ReturnPeriodData[];
  }

  try {
    logger.info(`📡 Fetching return periods for reach ${reachId}`);

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

    // Cache the result
    setCachedData(cacheKey, validData);

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
 * Get river name for notification display
 * @param {string} reachId - The reach identifier
 * @return {Promise<string>} River name or fallback
 */
export async function getRiverName(reachId: string): Promise<string> {
  const cacheKey = `river-name:${reachId}`;

  // Check cache first (valid for 24 hours - names don't change)
  const cached = getCachedData(cacheKey);
  if (cached) {
    return cached as string;
  }

  try {
    logger.info(`📡 Fetching river name for reach ${reachId}`);

    const url = buildReachUrl(reachId);
    const response = await fetchWithTimeout(url);

    if (!response.ok) {
      throw new Error(
        `Reach info API error: ${response.status} - ${response.statusText}`
      );
    }

    const data = await response.json() as ReachResponse;
    const riverName = data.name || `Reach ${reachId}`;

    // Cache the result
    setCachedData(cacheKey, riverName);

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
 * Matches the exact parsing logic from your working Flutter app
 * @param {NoaaApiResponse} apiResponse - The NOAA API response
 * @return {ForecastData} Extracted forecast data
 */
function extractForecastValues(apiResponse: NoaaApiResponse): ForecastData {
  try {
    // Log the structure for debugging
    logger.info("🔍 NOAA API Response Structure", {
      topLevelKeys: Object.keys(apiResponse || {}),
    });

    // STEP 1: Try shortRange.series.data (used by short_range forecast)
    if (apiResponse.shortRange?.series?.data) {
      const seriesData = apiResponse.shortRange.series.data;
      if (Array.isArray(seriesData) && seriesData.length > 0) {
        logger.info("✅ Found shortRange.series.data", {
          pointCount: seriesData.length,
          firstPoint: seriesData[0],
        });

        // {validTime, flow} to{validTime, value}
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
          return {
            values,
            units: apiResponse.shortRange.series.units || "cms",
          };
        }
      }
    }

    // STEP 2: Try mediumRange.mean.data (used by medium_range forecast)
    if (apiResponse.mediumRange?.mean?.data) {
      const meanData = apiResponse.mediumRange.mean.data;
      if (Array.isArray(meanData) && meanData.length > 0) {
        logger.info("✅ Found mediumRange.mean.data", {
          pointCount: meanData.length,
        });

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
          return {
            values,
            units: apiResponse.mediumRange.mean.units || "cms",
          };
        }
      }
    }

    // STEP 3: Try longRange.mean.data (used by long_range forecast)
    if (apiResponse.longRange?.mean?.data) {
      const meanData = apiResponse.longRange.mean.data;
      if (Array.isArray(meanData) && meanData.length > 0) {
        logger.info("✅ Found longRange.mean.data", {
          pointCount: meanData.length,
        });

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
          return {
            values,
            units: apiResponse.longRange.mean.units || "cms",
          };
        }
      }
    }

    // STEP 4: Fall back to ensemble members (member1, member2, etc.)
    const forecastTypes = ["shortRange", "mediumRange", "longRange"] as const;

    for (const forecastType of forecastTypes) {
      const forecastSection = apiResponse[forecastType];
      if (forecastSection && typeof forecastSection === "object") {
        // Look for member1, member2, etc.
        const memberKeys = Object.keys(forecastSection)
          .filter((key) => key.startsWith("member"))
          .sort(); // member1, member2, etc.

        for (const memberKey of memberKeys) {
          const memberSection = (forecastSection as
            Record<string, unknown>)[memberKey];
          const memberData = (memberSection as
            {data?: NoaaForecastPoint[]})?.data;
          if (Array.isArray(memberData) && memberData.length > 0) {
            logger.info(`✅ Found ${forecastType}.${memberKey}.data`, {
              pointCount: memberData.length,
            });

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
              return {
                values,
                units: (memberSection as {units?: string})?.units || "cms",
              };
            }
          }
        }
      }
    }

    // STEP 5: Legacy fallback patterns (keep for compatibility)
    if (apiResponse.values && Array.isArray(apiResponse.values)) {
      const validValues = apiResponse.values.filter((v) =>
        v.value !== null &&
        v.value !== undefined &&
        !isNaN(v.value)
      );
      if (validValues.length > 0) {
        logger.info("✅ Found legacy values array", {
          pointCount: validValues.length,
        });
        return {
          values: validValues,
          units: apiResponse.units || "cms",
        };
      }
    }

    if (apiResponse.forecast?.values) {
      const validValues = apiResponse.forecast.values.filter((v) =>
        v.value !== null &&
        v.value !== undefined &&
        !isNaN(v.value)
      );
      if (validValues.length > 0) {
        logger.info("✅ Found legacy forecast.values", {
          pointCount: validValues.length,
        });
        return {
          values: validValues,
          units: apiResponse.forecast.units || "cms",
        };
      }
    }

    // Log the full structure for debugging if no data found
    logger.warn("❌ No forecast data found in expected locations", {
      responseKeys: Object.keys(apiResponse || {}),
      shortRange: apiResponse.shortRange ?
        Object.keys(apiResponse.shortRange) : null,
      mediumRange: apiResponse.mediumRange ?
        Object.keys(apiResponse.mediumRange) : null,
      longRange: apiResponse.longRange ?
        Object.keys(apiResponse.longRange) : null,
    });

    return {
      values: [],
      units: "cms",
    };
  } catch (error) {
    logger.error("❌ Error extracting forecast values", {
      error: error instanceof Error ? error.message : String(error),
      responseStructure: Object.keys(apiResponse || {}),
    });

    return {
      values: [],
      units: "cms",
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

/**
 * Simple cache management (following your existing patterns)
 * @param {string} key - Cache key
 * @return {unknown|null} Cached data or null
 */
function getCachedData(key: string): unknown | null {
  const cached = cache.get(key);
  if (cached && Date.now() < cached.expires) {
    return cached.data;
  }

  // Clean up expired entry
  if (cached) {
    cache.delete(key);
  }

  return null;
}

/**
 * Set data in cache with expiration
 * @param {string} key - Cache key
 * @param {unknown} data - Data to cache
 * @param {number} maxAge - Maximum age in ms (default 1 hour)
 */
function setCachedData(
  key: string,
  data: unknown,
  maxAge: number = 60 * 60 * 1000
): void {
  cache.set(key, {
    data,
    expires: Date.now() + maxAge,
  });
}

/**
 * Clear cache (useful for testing)
 */
export function clearCache(): void {
  cache.clear();
  logger.info("🧹 Cache cleared");
}

/**
 * Get cache stats (useful for monitoring)
 * @return {object} Cache statistics with size and keys
 */
export function getCacheStats(): {size: number; keys: string[]} {
  return {
    size: cache.size,
    keys: Array.from(cache.keys()),
  };
}
