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

// Types for NOAA API responses
interface ForecastValue {
  value: number;
  validTime: string;
}

interface ForecastData {
  values: ForecastValue[];
  units?: string;
}

interface ReturnPeriodData {
  feature_id: string;
  return_period_2?: number;
  return_period_5?: number;
  return_period_10?: number;
  return_period_25?: number;
  return_period_50?: number;
  return_period_100?: number;
}

// Type guards for API responses
interface ApiResponse {
  values?: ForecastValue[];
  units?: string;
  forecast?: {
    values: ForecastValue[];
    units?: string;
  };
  [key: string]: unknown;
}

interface ReturnPeriodItem {
  feature_id: string;
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
    const forecastData = extractForecastValues(data as ApiResponse);

    // Cache the result
    setCachedData(cacheKey, forecastData);

    logger.info(`✅ Successfully fetched forecast for reach ${reachId}`, {
      valueCount: forecastData.values.length,
    });

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
        return []; // Return empty array for missing data (graceful degradation)
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
  // Format: https://api.water.noaa.gov/nwps/v1/reaches/{reachId}/streamflow?series={series}
  return `${NOAA_CONFIG.noaaReachesBaseUrl}/reaches/${reachId}` +
    `/streamflow?series=${series}`;
}

/**
 * Build return period URL (matches AppConfig.getReturnPeriodUrl pattern)
 * @param {string} reachId - The reach identifier
 * @return {string} Complete return period URL
 */
function buildReturnPeriodUrl(reachId: string): string {
  // Format: https://nwm-api-updt-9f6idmxh.uc.gateway.dev/return-period?comids={reachId}&key={apiKey}
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
 * Handles the nested structure of NOAA forecast responses
 * @param {ApiResponse} apiResponse - The NOAA API response
 * @return {ForecastData} Extracted forecast data
 */
function extractForecastValues(apiResponse: ApiResponse): ForecastData {
  try {
    // NOAA forecast structure varies, try common patterns

    // Pattern 1: Direct values array
    if (apiResponse.values && Array.isArray(apiResponse.values)) {
      return {
        values: apiResponse.values,
        units: apiResponse.units || "cms", // NOAA typically returns CMS
      };
    }

    // Pattern 2: Nested in forecast data
    if (apiResponse.forecast && apiResponse.forecast.values) {
      return {
        values: apiResponse.forecast.values,
        units: apiResponse.forecast.units || "cms",
      };
    }

    // Pattern 3: Look for any array of forecast data
    const findValues = (obj: unknown): ForecastValue[] => {
      if (Array.isArray(obj)) {
        // Check if this looks like forecast values
        if (obj.length > 0 &&
            typeof obj[0] === "object" &&
            obj[0] !== null &&
            "value" in obj[0] &&
            "validTime" in obj[0]) {
          return obj as ForecastValue[];
        }
      }

      if (obj && typeof obj === "object" && obj !== null) {
        for (const key of Object.keys(obj)) {
          const result = findValues((obj as Record<string, unknown>)[key]);
          if (result.length > 0) return result;
        }
      }

      return [];
    };

    const values = findValues(apiResponse);

    if (values.length === 0) {
      throw new Error("No forecast values found in API response");
    }

    return {
      values,
      units: "cms", // Default to CMS for NOAA data
    };
  } catch (error) {
    logger.error("❌ Error extracting forecast values", {
      error: error instanceof Error ? error.message : String(error),
      responseStructure: Object.keys(apiResponse || {}),
    });

    // Return empty values instead of throwing
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
    typeof (item as ReturnPeriodItem).feature_id === "string"
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
 * @param {number} maxAge - Maximum age in milliseconds (default 1 hour)
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
