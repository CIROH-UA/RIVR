// lib/services/4_infrastructure/api/noaa_api_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Service for fetching data from NOAA APIs
/// Integrates with existing AppConfig and ErrorService
/// With selective loading for better performance
class NoaaApiService implements INoaaApiService {
  final http.Client _client;
  final IFlowUnitPreferenceService _unitService;

  /// Short-lived cache for the unfiltered forecast response, shared across
  /// multiple fallback calls within a single load cycle. Keyed by reachId.
  final Map<String, _UnfilteredCacheEntry> _unfilteredCache = {};
  static const _unfilteredCacheTtl = Duration(seconds: 30);

  NoaaApiService({
    http.Client? client,
    required IFlowUnitPreferenceService unitService,
  })  : _client = client ?? http.Client(),
        _unitService = unitService;

  // Different timeout durations for different request priorities
  static const Duration _quickTimeout = Duration(
    seconds: 15,
  ); // For overview data
  static const Duration _normalTimeout = Duration(
    seconds: 20,
  ); // For supplementary data
  static const Duration _longTimeout = Duration(
    seconds: 30,
  ); // For complete data

  static const _defaultHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': 'RIVR/1.0',
  };

  /// Simple HTTP GET with timeout.
  Future<http.Response> _httpGet(
    String url, {
    required Duration timeout,
    Map<String, String>? extraHeaders,
  }) async {
    return await _client
        .get(
          Uri.parse(url),
          headers: {
            ..._defaultHeaders,
            ...?extraHeaders,
          },
        )
        .timeout(timeout);
  }

  /// HTTP GET with automatic retry on timeout or server errors.
  Future<http.Response> _httpGetWithRetry(
    String url, {
    required Duration timeout,
    Map<String, String>? extraHeaders,
    int maxRetries = 2,
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await _httpGet(
          url,
          timeout: timeout,
          extraHeaders: extraHeaders,
        );
        if (response.statusCode >= 500 && attempt < maxRetries) {
          AppLogger.warning(
            'NoaaApi',
            'Server error ${response.statusCode} on attempt ${attempt + 1}, retrying: $url',
          );
          await Future.delayed(Duration(seconds: attempt + 1));
          continue;
        }
        return response;
      } on TimeoutException {
        if (attempt < maxRetries) {
          AppLogger.warning(
            'NoaaApi',
            'Timeout on attempt ${attempt + 1}, retrying: $url',
          );
          await Future.delayed(Duration(seconds: attempt + 1));
          continue;
        }
        rethrow;
      }
    }
    // Final fallback (unreachable in practice)
    return _httpGet(url, timeout: timeout, extraHeaders: extraHeaders);
  }

  // Reach Info Fetching (OPTIMIZED for overview)
  /// Fetch reach information from NOAA Reaches API
  /// Returns data in format expected by ReachData.fromNoaaApi()
  /// Now optimized with shorter timeout for overview loading
  @override
  Future<Map<String, dynamic>> fetchReachInfo(
    String reachId, {
    bool isOverview = false,
  }) async {
    try {
      AppLogger.debug(
        'NoaaApi',
        'Fetching reach info for: $reachId ${isOverview ? "(overview)" : ""}',
      );

      final url = AppConfig.getReachUrl(reachId);
      AppLogger.debug('NoaaApi', 'URL: $url');

      final timeout = isOverview ? _quickTimeout : _normalTimeout;

      final response = await _httpGetWithRetry(
        url,
        timeout: timeout,
        extraHeaders: {if (isOverview) 'X-Request-Priority': 'high'},
      );

      AppLogger.debug('NoaaApi', 'Response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        AppLogger.debug('NoaaApi', 'Successfully fetched reach info');
        return data;
      } else if (response.statusCode == 404) {
        throw Exception('Reach not found: $reachId');
      } else {
        throw Exception(
          'NOAA API error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      AppLogger.error('NoaaApi', 'Error fetching reach info', e);
      throw ServiceException.fromError(e, context: 'fetchReachInfo');
    }
  }

  // Fast current flow fetching for overview
  /// Fetch only current flow data for overview display
  /// Uses short-range forecast but with optimized timeout
  @override
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId) async {
    AppLogger.debug('NoaaApi', 'Fetching current flow only for: $reachId');

    // Use existing forecast method but with quick timeout and priority
    return await fetchForecast(reachId, 'short_range', isOverview: true);
  }

  // Return Period Fetching (handles failures gracefully)
  /// Fetch return period data from NWM API
  /// Returns array data in format expected by ReachData.fromReturnPeriodApi()
  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    final start = DateTime.now();
    try {
      AppLogger.debug('NoaaApi', 'Fetching return periods for: $reachId');

      final url = AppConfig.getReturnPeriodUrl(reachId);
      AppLogger.debug('NoaaApi', 'Return period URL: $url');

      final response = await _httpGetWithRetry(
        url,
        timeout: _normalTimeout,
      );

      final duration = DateTime.now().difference(start);
      AppLogger.debug('NoaaApi', 'API_TIME_RETURN_PERIOD: ${duration.inMilliseconds}ms');

      AppLogger.debug('NoaaApi', 'Return period response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // Validate the data structure before returning
        if (data is List) {
          // Check if the data contains valid values
          bool hasValidData = true;
          for (final item in data) {
            if (item is! Map || item.isEmpty) {
              hasValidData = false;
              break;
            }
            // Check if the item has the expected numeric fields
            final values = item.values;
            if (values.any((value) => value != null && value is! num)) {
              hasValidData = false;
              break;
            }
          }

          if (hasValidData && data.isNotEmpty) {
            AppLogger.debug(
              'NoaaApi',
              'Successfully fetched return periods (${data.length} items)',
            );
            return data;
          } else {
            AppLogger.debug(
              'NoaaApi',
              'Return period data contains invalid values, skipping',
            );
            return []; // Return empty list for invalid data
          }
        } else if (data is Map && data.isNotEmpty) {
          AppLogger.debug(
            'NoaaApi',
            'Return period API returned single object, wrapping in array',
          );
          return [data];
        } else {
          AppLogger.debug('NoaaApi', 'Return period API returned empty or invalid data');
          return [];
        }
      } else if (response.statusCode == 404) {
        AppLogger.debug('NoaaApi', 'No return periods found for reach: $reachId');
        return []; // Return empty list instead of throwing
      } else {
        AppLogger.debug('NoaaApi', 'Return period API error: ${response.statusCode}');
        return []; // Return empty list for non-critical data
      }
    } catch (e) {
      AppLogger.error('NoaaApi', 'Error fetching return periods', e);
      // Don't throw for return periods - they're supplementary data
      // Just return empty list so reach loading doesn't fail
      return [];
    }
  }

  // Forecast Fetching (OPTIMIZED with priority support + UNIT CONVERSION)
  /// Fetch streamflow forecast data from NOAA API for a specific series.
  /// If the filtered endpoint returns HTTP 200 but empty data for the
  /// requested section, automatically falls back to the unfiltered endpoint.
  @override
  Future<Map<String, dynamic>> fetchForecast(
    String reachId,
    String series, {
    bool isOverview = false, // Priority flag for overview loading
  }) async {
    final start = DateTime.now();
    try {
      AppLogger.debug(
        'NoaaApi',
        'Fetching $series forecast for: $reachId ${isOverview ? "(overview)" : ""}',
      );

      final url = AppConfig.getForecastUrl(reachId, series);
      AppLogger.debug('NoaaApi', 'Forecast URL: $url');

      // Use appropriate timeout based on priority
      final timeout = isOverview ? _quickTimeout : _normalTimeout;

      final response = await _httpGetWithRetry(
        url,
        timeout: timeout,
        extraHeaders: {if (isOverview) 'X-Request-Priority': 'high'},
      );

      final duration = DateTime.now().difference(start);
      AppLogger.debug('NoaaApi', 'API_TIME_NWM_$series: ${duration.inMilliseconds}ms');

      AppLogger.debug('NoaaApi', 'Forecast response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Check if the target section has actual data
        final sectionKey = _seriesToSectionKey(series);
        if (sectionKey != null && _isForecastSectionEmpty(data, sectionKey)) {
          AppLogger.warning(
            'NoaaApi',
            '?series=$series returned empty data, falling back to unfiltered endpoint',
          );
          return await _fetchWithUnfilteredFallback(reachId, sectionKey);
        }

        final convertedData = _convertForecastResponse(data);

        AppLogger.info(
          'NoaaApi',
          'Successfully fetched and converted $series forecast to ${_unitService.currentFlowUnit}',
        );
        return convertedData;
      } else if (response.statusCode == 404) {
        throw Exception('$series forecast not available for reach: $reachId');
      } else {
        throw Exception(
          'Forecast API error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      AppLogger.error('NoaaApi', 'Error fetching $series forecast', e);
      throw ServiceException.fromError(e, context: 'fetchForecast');
    }
  }

  // ===== UNFILTERED FALLBACK LOGIC =====

  /// Maps a series query param to the JSON response key.
  static String? _seriesToSectionKey(String series) {
    switch (series) {
      case 'short_range':
        return 'shortRange';
      case 'medium_range':
        return 'mediumRange';
      case 'long_range':
        return 'longRange';
      default:
        return null;
    }
  }

  /// Returns `true` when the given section exists but all its data arrays
  /// are empty or its referenceTime is null — indicating the server returned
  /// the structure without actual forecast values.
  bool _isForecastSectionEmpty(Map<String, dynamic> response, String sectionKey) {
    final section = response[sectionKey];
    if (section == null || section is! Map<String, dynamic> || section.isEmpty) {
      return true;
    }

    // Check every sub-key (series, mean, member1, member2, …)
    for (final value in section.values) {
      if (value is Map<String, dynamic>) {
        final data = value['data'];
        if (data is List && data.isNotEmpty) {
          return false; // At least one sub-series has data
        }
      }
    }
    return true;
  }

  /// Fetch the unfiltered endpoint (all series in one call) with a short-lived
  /// in-memory cache so multiple fallbacks in the same load cycle share one
  /// network request.
  Future<Map<String, dynamic>> _fetchUnfilteredForecast(String reachId) async {
    // Check cache
    final cached = _unfilteredCache[reachId];
    if (cached != null && !cached.isExpired(_unfilteredCacheTtl)) {
      AppLogger.debug('NoaaApi', 'Using cached unfiltered response for $reachId');
      return cached.data;
    }

    final url = AppConfig.getStreamflowUrl(reachId);
    AppLogger.debug('NoaaApi', 'Fetching unfiltered forecast: $url');

    final response = await _httpGetWithRetry(url, timeout: _longTimeout);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final convertedData = _convertForecastResponse(data);
      _unfilteredCache[reachId] = _UnfilteredCacheEntry(convertedData);
      AppLogger.info('NoaaApi', 'Unfiltered forecast fetched and cached for $reachId');
      return convertedData;
    } else {
      throw Exception(
        'Unfiltered forecast API error: ${response.statusCode} - ${response.body}',
      );
    }
  }

  /// Attempt the unfiltered endpoint and return the full response (which
  /// includes all sections). If the unfiltered response also has empty data
  /// for the requested section, return it as-is (genuine no-data).
  Future<Map<String, dynamic>> _fetchWithUnfilteredFallback(
    String reachId,
    String sectionKey,
  ) async {
    try {
      final unfilteredData = await _fetchUnfilteredForecast(reachId);

      if (_isForecastSectionEmpty(unfilteredData, sectionKey)) {
        AppLogger.warning(
          'NoaaApi',
          'Unfiltered endpoint also has empty $sectionKey — genuine no-data for this reach',
        );
      } else {
        AppLogger.info(
          'NoaaApi',
          'Unfiltered fallback provided $sectionKey data successfully',
        );
      }

      return unfilteredData;
    } catch (e) {
      AppLogger.error('NoaaApi', 'Unfiltered fallback also failed', e);
      rethrow;
    }
  }

  // Optimized overview data fetching
  /// Fetch minimal data needed for overview page: reach info + current flow
  /// Optimized for speed with shorter timeouts and priority headers
  /// UPDATED: Now includes unit conversion
  @override
  Future<Map<String, dynamic>> fetchOverviewData(String reachId) async {
    AppLogger.debug('NoaaApi', 'Fetching overview data for reach: $reachId');

    try {
      // Fetch reach info and short-range forecast in parallel with overview priority
      final futures = await Future.wait([
        fetchReachInfo(reachId, isOverview: true),
        fetchCurrentFlowOnly(
          reachId,
        ), // This already gets converted by fetchForecast
      ]);

      final reachInfo = futures[0];
      final flowData = futures[1]; // Already converted

      // Combine into overview response format
      final overviewResponse = Map<String, dynamic>.from(flowData);
      overviewResponse['reach'] = reachInfo;

      AppLogger.info(
        'NoaaApi',
        'Successfully fetched overview data with unit conversion',
      );
      return overviewResponse;
    } catch (e) {
      AppLogger.error('NoaaApi', 'Error fetching overview data', e);
      rethrow;
    }
  }

  // Complete Forecast Fetching
  /// Fetch all available forecast types for a reach using the unfiltered
  /// endpoint (single request, all sections). Falls back to parallel filtered
  /// calls if the unfiltered endpoint fails.
  @override
  Future<Map<String, dynamic>> fetchAllForecasts(String reachId) async {
    AppLogger.debug('NoaaApi', 'Fetching all forecasts for reach: $reachId');

    try {
      // Primary path: single unfiltered request returns all sections
      final data = await _fetchUnfilteredForecast(reachId);
      AppLogger.info(
        'NoaaApi',
        'All forecasts loaded via unfiltered endpoint for reach $reachId',
      );
      return data;
    } catch (e) {
      AppLogger.warning(
        'NoaaApi',
        'Unfiltered endpoint failed, falling back to filtered calls: $e',
      );
      return await _fetchAllForecastsFiltered(reachId);
    }
  }

  /// Fallback: fetch each series individually and merge results.
  Future<Map<String, dynamic>> _fetchAllForecastsFiltered(String reachId) async {
    Map<String, dynamic>? combinedResponse;
    final forecastTypes = ['short_range', 'medium_range', 'long_range'];
    final results = <String, Map<String, dynamic>?>{};

    final futures = forecastTypes.map((forecastType) async {
      try {
        AppLogger.debug('NoaaApi', 'Attempting filtered fetch $forecastType...');
        final response = await _httpGetWithRetry(
          AppConfig.getForecastUrl(reachId, forecastType),
          timeout: _longTimeout,
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final convertedData = _convertForecastResponse(data);
          AppLogger.info('NoaaApi', 'Successfully fetched and converted $forecastType');
          return MapEntry(forecastType, convertedData);
        } else {
          AppLogger.warning(
            'NoaaApi',
            'Failed to fetch $forecastType: ${response.statusCode}',
          );
          return MapEntry<String, Map<String, dynamic>?>(forecastType, null);
        }
      } catch (e) {
        AppLogger.warning('NoaaApi', 'Failed to fetch $forecastType: $e');
        return MapEntry<String, Map<String, dynamic>?>(forecastType, null);
      }
    }).toList();

    final entries = await Future.wait(futures);
    for (final entry in entries) {
      results[entry.key] = entry.value;
      if (entry.value != null) {
        combinedResponse ??= entry.value;
      }
    }

    if (combinedResponse == null) {
      throw const ServiceException.notFound(
        'No forecast data available. All forecast types failed.',
        detail: 'fetchAllForecasts: combinedResponse was null after all attempts',
      );
    }

    final mergedResponse = Map<String, dynamic>.from(combinedResponse);
    mergedResponse['analysisAssimilation'] = {};
    mergedResponse['shortRange'] = {};
    mergedResponse['mediumRange'] = {};
    mergedResponse['longRange'] = {};
    mergedResponse['mediumRangeBlend'] = {};

    for (final entry in results.entries) {
      if (entry.value != null) {
        _mergeForecastSections(mergedResponse, entry.value!, entry.key);
      }
    }

    final successCount = results.values.where((r) => r != null).length;
    AppLogger.info(
      'NoaaApi',
      'Filtered fallback combined $successCount/${forecastTypes.length} forecast types for reach $reachId',
    );
    return mergedResponse;
  }

  /// Helper method to merge forecast sections from individual responses
  void _mergeForecastSections(
    Map<String, dynamic> target,
    Map<String, dynamic> source,
    String forecastType,
  ) {
    switch (forecastType) {
      case 'short_range':
        if (source['shortRange'] != null) {
          target['shortRange'] = source['shortRange'];
        }
        if (source['analysisAssimilation'] != null) {
          target['analysisAssimilation'] = source['analysisAssimilation'];
        }
        break;
      case 'medium_range':
        if (source['mediumRange'] != null) {
          target['mediumRange'] = source['mediumRange'];
        }
        if (source['mediumRangeBlend'] != null) {
          target['mediumRangeBlend'] = source['mediumRangeBlend'];
        }
        break;
      case 'long_range':
        if (source['longRange'] != null) {
          target['longRange'] = source['longRange'];
        }
        break;
    }
  }

  /// FIXED: Added better logging to track conversions and prevent double conversion
  Map<String, dynamic> _convertForecastResponse(
    Map<String, dynamic> rawResponse,
  ) {
    try {
      final convertedResponse = Map<String, dynamic>.from(rawResponse);
      final targetUnit = _unitService.currentFlowUnit;

      AppLogger.debug('NoaaApi', 'Starting forecast conversion to $targetUnit');

      // Convert all forecast sections that contain series data
      final sectionsToConvert = [
        'analysisAssimilation',
        'shortRange',
        'mediumRange',
        'longRange',
        'mediumRangeBlend',
      ];

      for (final section in sectionsToConvert) {
        if (convertedResponse[section] != null) {
          AppLogger.debug('NoaaApi', 'Converting section: $section');
          convertedResponse[section] = _convertForecastSection(
            convertedResponse[section],
          );
        }
      }

      AppLogger.info('NoaaApi', 'Forecast conversion completed');
      return convertedResponse;
    } catch (e) {
      AppLogger.error('NoaaApi', 'Failed to convert units', e);
      // Return original data if conversion fails
      return rawResponse;
    }
  }

  /// Convert a forecast section (handles both single series and ensemble data)
  /// FIXED: Added logging to track what gets converted
  dynamic _convertForecastSection(dynamic section) {
    if (section == null || section is! Map<String, dynamic>) {
      return section;
    }

    final convertedSection = Map<String, dynamic>.from(section);

    // Handle 'series' data (single forecast series)
    if (convertedSection['series'] != null) {
      AppLogger.debug('NoaaApi', 'Converting single series data');
      convertedSection['series'] = _convertSingleSeries(
        convertedSection['series'],
      );
    }

    // Handle 'mean' data (ensemble mean)
    if (convertedSection['mean'] != null) {
      AppLogger.debug('NoaaApi', 'Converting ensemble mean data');
      convertedSection['mean'] = _convertSingleSeries(convertedSection['mean']);
    }

    // Handle ensemble members (member01, member02, etc.)
    final memberKeys = convertedSection.keys
        .where((key) => key.startsWith('member'))
        .toList();

    if (memberKeys.isNotEmpty) {
      AppLogger.debug('NoaaApi', 'Converting ${memberKeys.length} ensemble members');
    }

    for (final memberKey in memberKeys) {
      if (convertedSection[memberKey] != null) {
        convertedSection[memberKey] = _convertSingleSeries(
          convertedSection[memberKey],
        );
      }
    }

    return convertedSection;
  }

  /// Convert a single forecast series
  /// FIXED: Added detailed logging to track double conversion prevention
  Map<String, dynamic> _convertSingleSeries(dynamic seriesData) {
    if (seriesData == null || seriesData is! Map<String, dynamic>) {
      return seriesData ?? {};
    }

    try {
      // Parse the series to get the data structure
      final originalSeries = ForecastSeriesDto.fromJson(seriesData).toEntity();
      final targetUnit = _unitService.currentFlowUnit;

      AppLogger.debug(
        'NoaaApi',
        'Series conversion - ${originalSeries.units} -> $targetUnit (${originalSeries.data.length} points)',
      );

      // Convert to user's preferred unit (prevents double conversion internally)
      final convertedSeries = originalSeries.convertToUnit(
        targetUnit,
        _unitService,
      );

      // Convert back to JSON format
      return ForecastSeriesDto.fromEntity(convertedSeries).toJson();
    } catch (e) {
      AppLogger.warning('NoaaApi', 'Failed to convert series: $e');
      return Map<String, dynamic>.from(seriesData);
    }
  }
}

/// Short-lived cache entry for unfiltered forecast responses.
class _UnfilteredCacheEntry {
  final Map<String, dynamic> data;
  final DateTime cachedAt;

  _UnfilteredCacheEntry(this.data) : cachedAt = DateTime.now();

  bool isExpired(Duration ttl) => DateTime.now().difference(cachedAt) > ttl;
}

/// Deprecated — use [ServiceException] directly.
/// Kept as a subclass so existing `catch (ApiException)` and `isA<ApiException>()`
/// in tests continue to work during migration.
@Deprecated('Use ServiceException instead. Will be removed in Phase 8.')
class ApiException extends ServiceException {
  const ApiException(String message)
      : super(
          type: ServiceErrorType.network,
          message: message,
        );

  @override
  String toString() => 'ApiException: $message';
}
