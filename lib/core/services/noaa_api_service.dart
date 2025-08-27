// lib/core/services/noaa_api_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/reach_data.dart';
import 'error_service.dart';
import 'flow_unit_preference_service.dart';

/// Service for fetching data from NOAA APIs
/// Integrates with existing AppConfig and ErrorService
/// With selective loading for better performance
class NoaaApiService {
  static final NoaaApiService _instance = NoaaApiService._internal();
  factory NoaaApiService() => _instance;
  NoaaApiService._internal();

  final http.Client _client = http.Client();
  final FlowUnitPreferenceService _unitService = FlowUnitPreferenceService();

  // Different timeout durations for different request priorities
  static const Duration _quickTimeout = Duration(
    seconds: 10,
  ); // For overview data
  static const Duration _normalTimeout = Duration(
    seconds: 20,
  ); // For supplementary data
  static const Duration _longTimeout = Duration(
    seconds: 30,
  ); // For complete data

  // Reach Info Fetching (OPTIMIZED for overview)
  /// Fetch reach information from NOAA Reaches API
  /// Returns data in format expected by ReachData.fromNoaaApi()
  /// Now optimized with shorter timeout for overview loading
  Future<Map<String, dynamic>> fetchReachInfo(
    String reachId, {
    bool isOverview = false,
  }) async {
    try {
      print(
        'NOAA_API: Fetching reach info for: $reachId ${isOverview ? "(overview)" : ""}',
      );

      final url = AppConfig.getReachUrl(reachId);
      print('NOAA_API: URL: $url');

      final timeout = isOverview ? _quickTimeout : _normalTimeout;

      final response = await _client
          .get(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'RivrFlow/1.0',
              // Priority header for overview requests
              if (isOverview) 'X-Request-Priority': 'high',
            },
          )
          .timeout(timeout);

      print('NOAA_API: Response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        print('NOAA_API: Successfully fetched reach info');
        return data;
      } else if (response.statusCode == 404) {
        throw Exception('Reach not found: $reachId');
      } else {
        throw Exception(
          'NOAA API error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      print('NOAA_API: Error fetching reach info: $e');
      final userMessage = ErrorService.handleError(
        e,
        context: 'fetchReachInfo',
      );
      throw ApiException(userMessage);
    }
  }

  // Fast current flow fetching for overview
  /// Fetch only current flow data for overview display
  /// Uses short-range forecast but with optimized timeout
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId) async {
    print('NOAA_API: Fetching current flow only for: $reachId');

    // Use existing forecast method but with quick timeout and priority
    return await fetchForecast(reachId, 'short_range', isOverview: true);
  }

  // Return Period Fetching (handles failures gracefully)
  /// Fetch return period data from NWM API
  /// Returns array data in format expected by ReachData.fromReturnPeriodApi()
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    try {
      print('NOAA_API: Fetching return periods for: $reachId');

      final url = AppConfig.getReturnPeriodUrl(reachId);
      print('NOAA_API: Return period URL: $url');

      final response = await _client
          .get(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'RivrFlow/1.0',
            },
          )
          .timeout(_normalTimeout); // Use normal timeout for supplementary data

      print('NOAA_API: Return period response status: ${response.statusCode}');

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
            print(
              'NOAA_API: Successfully fetched return periods (${data.length} items)',
            );
            return data;
          } else {
            print(
              'NOAA_API: Return period data contains invalid values, skipping',
            );
            return []; // Return empty list for invalid data
          }
        } else if (data is Map && data.isNotEmpty) {
          print(
            'NOAA_API: Return period API returned single object, wrapping in array',
          );
          return [data];
        } else {
          print('NOAA_API: Return period API returned empty or invalid data');
          return [];
        }
      } else if (response.statusCode == 404) {
        print('NOAA_API: No return periods found for reach: $reachId');
        return []; // Return empty list instead of throwing
      } else {
        print('NOAA_API: Return period API error: ${response.statusCode}');
        return []; // Return empty list for non-critical data
      }
    } catch (e) {
      print('NOAA_API: Error fetching return periods: $e');
      // Don't throw for return periods - they're supplementary data
      // Just return empty list so reach loading doesn't fail
      return [];
    }
  }

  // Forecast Fetching (OPTIMIZED with priority support + UNIT CONVERSION)
  /// Fetch streamflow forecast data from NOAA API for a specific series
  /// Returns data in format expected by ForecastResponse.fromJson()
  /// Now with priority handling for overview vs detailed loading
  /// UPDATED: Now includes unit conversion for all forecast data
  Future<Map<String, dynamic>> fetchForecast(
    String reachId,
    String series, {
    bool isOverview = false, // Priority flag for overview loading
  }) async {
    try {
      print(
        'NOAA_API: Fetching $series forecast for: $reachId ${isOverview ? "(overview)" : ""}',
      );

      final url = AppConfig.getForecastUrl(reachId, series);
      print('NOAA_API: Forecast URL: $url');

      // Use appropriate timeout based on priority
      final timeout = isOverview ? _quickTimeout : _normalTimeout;

      final response = await _client
          .get(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'RivrFlow/1.0',
              // Priority header for overview requests
              if (isOverview) 'X-Request-Priority': 'high',
            },
          )
          .timeout(timeout);

      print('NOAA_API: Forecast response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // NEW: Apply unit conversion to all forecast data before returning
        final convertedData = _convertForecastResponse(data);

        print(
          'NOAA_API: Successfully fetched and converted $series forecast to ${_unitService.currentFlowUnit}',
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
      print('NOAA_API: Error fetching $series forecast: $e');
      final userMessage = ErrorService.handleError(e, context: 'fetchForecast');
      throw ApiException(userMessage);
    }
  }

  // Optimized overview data fetching
  /// Fetch minimal data needed for overview page: reach info + current flow
  /// Optimized for speed with shorter timeouts and priority headers
  /// UPDATED: Now includes unit conversion
  Future<Map<String, dynamic>> fetchOverviewData(String reachId) async {
    print('NOAA_API: Fetching overview data for reach: $reachId');

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

      print(
        'NOAA_API: ✅ Successfully fetched overview data with unit conversion',
      );
      return overviewResponse;
    } catch (e) {
      print('NOAA_API: ❌ Error fetching overview data: $e');
      rethrow;
    }
  }

  // Complete Forecast Fetching (use longer timeout for complete data)
  /// Fetch all available forecast types for a reach
  /// Orchestrates multiple API calls to get complete forecast data
  /// Returns combined data with all available forecasts
  /// UPDATED: Now includes unit conversion for all forecast types
  Future<Map<String, dynamic>> fetchAllForecasts(String reachId) async {
    print('NOAA_API: Fetching all forecasts for reach: $reachId');

    // Initialize combined response structure
    Map<String, dynamic>? combinedResponse;
    final forecastTypes = ['short_range', 'medium_range', 'long_range'];
    final results = <String, Map<String, dynamic>?>{};

    // Fetch each forecast type with longer timeout for complete data
    for (final forecastType in forecastTypes) {
      try {
        print('NOAA_API: Attempting to fetch $forecastType...');
        // Use normal timeout for complete data loading
        final response = await _client
            .get(
              Uri.parse(AppConfig.getForecastUrl(reachId, forecastType)),
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': 'RivrFlow/1.0',
              },
            )
            .timeout(_longTimeout); // Longer timeout for complete loading

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;

          // NEW: Convert forecast data to preferred units
          final convertedData = _convertForecastResponse(data);
          results[forecastType] = convertedData;
          combinedResponse ??= convertedData;

          print('NOAA_API: ✅ Successfully fetched and converted $forecastType');
        } else {
          print(
            'NOAA_API: ⚠️ Failed to fetch $forecastType: ${response.statusCode}',
          );
          results[forecastType] = null;
        }
      } catch (e) {
        print('NOAA_API: ⚠️ Failed to fetch $forecastType: $e');
        results[forecastType] = null;
        // Continue with other forecast types
      }
    }

    // Check if we got at least one forecast
    if (combinedResponse == null) {
      throw ApiException(
        'No forecast data available for reach $reachId. All forecast types failed.',
      );
    }

    // Merge all successful forecasts into combined response
    final mergedResponse = Map<String, dynamic>.from(combinedResponse);

    // Clear forecast sections and rebuild with all available data
    mergedResponse['analysisAssimilation'] = {};
    mergedResponse['shortRange'] = {};
    mergedResponse['mediumRange'] = {};
    mergedResponse['longRange'] = {};
    mergedResponse['mediumRangeBlend'] = {};

    // Merge forecast data from each successful response
    for (final entry in results.entries) {
      final forecastType = entry.key;
      final response = entry.value;

      if (response != null) {
        // Merge the forecast sections from this response
        _mergeForecastSections(mergedResponse, response, forecastType);
      }
    }

    final successCount = results.values.where((r) => r != null).length;
    print(
      'NOAA_API: ✅ Successfully combined $successCount/${forecastTypes.length} forecast types for reach $reachId with unit conversion',
    );

    return mergedResponse;
  }

  /// Helper method to merge forecast sections from individual responses
  void _mergeForecastSections(
    Map<String, dynamic> target,
    Map<String, dynamic> source,
    String forecastType,
  ) {
    // Map forecast types to their response sections
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

      print('NOAA_API: Starting forecast conversion to $targetUnit');

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
          print('NOAA_API: Converting section: $section');
          convertedResponse[section] = _convertForecastSection(
            convertedResponse[section],
          );
        }
      }

      print('NOAA_API: ✅ Forecast conversion completed');
      return convertedResponse;
    } catch (e) {
      print('NOAA_API: ❌ Failed to convert units: $e');
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
      print('NOAA_API: Converting single series data');
      convertedSection['series'] = _convertSingleSeries(
        convertedSection['series'],
      );
    }

    // Handle 'mean' data (ensemble mean)
    if (convertedSection['mean'] != null) {
      print('NOAA_API: Converting ensemble mean data');
      convertedSection['mean'] = _convertSingleSeries(convertedSection['mean']);
    }

    // Handle ensemble members (member01, member02, etc.)
    final memberKeys = convertedSection.keys
        .where((key) => key.startsWith('member'))
        .toList();

    if (memberKeys.isNotEmpty) {
      print('NOAA_API: Converting ${memberKeys.length} ensemble members');
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
      final originalSeries = ForecastSeries.fromJson(seriesData);
      final targetUnit = _unitService.currentFlowUnit;

      print(
        'NOAA_API: Series conversion - ${originalSeries.units} → $targetUnit (${originalSeries.data.length} points)',
      );

      // FIXED: The ForecastSeries.withPreferredUnits now prevents double conversion
      final convertedSeries = ForecastSeries.withPreferredUnits(
        originalUnits: originalSeries.units,
        preferredUnits: targetUnit,
        originalData: originalSeries.data,
        referenceTime: originalSeries.referenceTime,
      );

      // Convert back to JSON format
      return convertedSeries.toJson();
    } catch (e) {
      print('NOAA_API: ⚠️ Failed to convert series: $e');
      return Map<String, dynamic>.from(seriesData);
    }
  }
}

/// Custom exception for API errors
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => 'ApiException: $message';
}
