// lib/core/services/forecast_service.dart

import 'package:rivr/core/models/hourly_flow_data.dart';
import 'package:rivr/features/map/services/map_search_service.dart';
import '../models/reach_data.dart';
import 'app_logger.dart';
import 'noaa_api_service.dart';
import 'reach_cache_service.dart';
import 'flow_unit_preference_service.dart';

/// Simple service for loading complete forecast data
/// Combines reach info, return periods, and all forecast types
/// Now with phased loading for better performance
class ForecastService {
  static final ForecastService _instance = ForecastService._internal();
  factory ForecastService() => _instance;
  ForecastService._internal();

  final NoaaApiService _apiService = NoaaApiService();
  final ReachCacheService _cacheService = ReachCacheService();
  final FlowUnitPreferenceService _unitService = FlowUnitPreferenceService();

  // Cache computed values to avoid repeated calculations
  final Map<String, double?> _currentFlowCache = {};
  final Map<String, String> _flowCategoryCache = {};

  // PHASE 1 - Load minimal data for overview page
  /// Load only essential data for overview page: reach info + current flow
  /// This is the fastest possible load - only what's needed immediately
  Future<ForecastResponse> loadOverviewData(String reachId) async {
    try {
      AppLogger.debug('ForecastService', 'Loading overview data for reach: $reachId');

      // Step 1: Check cache for reach data first
      final cachedReach = await _cacheService.get(reachId);

      ReachData reach;
      if (cachedReach != null) {
        AppLogger.info('ForecastService', 'Using cached reach data');
        reach = cachedReach;

        // KEY: Check if cached reach needs geocoding
        if (reach.city == null || reach.state == null) {
          AppLogger.debug('ForecastService', 'Adding location to cached reach via reverse geocoding');

          try {
            final locationData = await MapSearchService.reverseGeocode(
              reach.latitude,
              reach.longitude,
            );

            // Update cached reach with city/state
            reach = reach.copyWith(
              city: locationData['city'],
              state: locationData['state'],
            );

            AppLogger.info('ForecastService', 'Enhanced cached reach with location: ${reach.city}, ${reach.state}');

            // Re-cache the updated reach data
            await _cacheService.store(reach);
            AppLogger.info('ForecastService', 'Re-cached reach data with location info');
          } catch (e) {
            AppLogger.warning('ForecastService', 'Reverse geocoding failed for cached reach: $e');
          }
        } else {
          AppLogger.debug('ForecastService', 'Cached reach already has location: city=${reach.city}, state=${reach.state}');
        }
      } else {
        AppLogger.debug('ForecastService', 'Cache miss - fetching reach info only');

        // Step 2: Fetch reach info from NOAA API
        final reachInfo = await _apiService.fetchReachInfo(
          reachId,
          isOverview: true,
        );

        // Step 3: Create initial reach data from API response
        reach = ReachData.fromNoaaApi(reachInfo);

        // Step 4: IMMEDIATELY do reverse geocoding BEFORE any caching
        if (reach.city == null || reach.state == null) {
          AppLogger.debug('ForecastService', 'Performing reverse geocoding for complete location data');

          try {
            final locationData = await MapSearchService.reverseGeocode(
              reach.latitude,
              reach.longitude,
            );

            // Update reach with city/state BEFORE caching
            reach = reach.copyWith(
              city: locationData['city'],
              state: locationData['state'],
              isPartiallyLoaded:
                  true, // Still partial since no return periods yet
            );

            AppLogger.info('ForecastService', 'Enhanced with location: ${reach.city}, ${reach.state}');
          } catch (e) {
            AppLogger.warning('ForecastService', 'Reverse geocoding failed: $e');
            reach = reach.copyWith(isPartiallyLoaded: true);
          }
        } else {
          AppLogger.debug('ForecastService', 'New reach already has location: city=${reach.city}, state=${reach.state}');
        }

        // Step 5: Now cache the reach data with city/state already populated
        await _cacheService.store(reach);
        AppLogger.info('ForecastService', 'Cached reach data with location info');
      }

      // Step 6: Get only short-range forecast for current flow (already converted by NoaaApiService)
      final shortRangeData = await _apiService.fetchCurrentFlowOnly(reachId);
      final forecastResponse = ForecastResponse.fromJson(shortRangeData);

      final overviewResponse = ForecastResponse(
        reach:
            reach, // Now guaranteed to have city/state if geocoding succeeded!
        shortRange: forecastResponse.shortRange,
        analysisAssimilation: forecastResponse.analysisAssimilation,
        mediumRange: {}, // Empty map - not loaded yet
        longRange: {}, // Empty map - not loaded yet
        mediumRangeBlend: null, // This is nullable, so null is OK
      );

      AppLogger.info('ForecastService', 'Overview data loaded successfully');
      AppLogger.debug('ForecastService', 'Final response reach: city=${overviewResponse.reach.city}, state=${overviewResponse.reach.state}');

      return overviewResponse;
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading overview data', e);
      rethrow;
    }
  }

  // PHASE 2 - Add return periods and forecast summaries
  /// Load supplementary data: return periods + other forecast summaries
  /// Call this after overview data is displayed to enhance functionality
  Future<ForecastResponse> loadSupplementaryData(
    String reachId,
    ForecastResponse existingData,
  ) async {
    try {
      AppLogger.debug('ForecastService', 'Loading supplementary data for reach: $reachId');

      ReachData reach = existingData.reach;

      // Only load return periods if we don't have them
      if (!reach.hasReturnPeriods) {
        try {
          final returnPeriods = await _apiService.fetchReturnPeriods(reachId);
          if (returnPeriods.isNotEmpty) {
            final returnPeriodData = ReachData.fromReturnPeriodApi(
              returnPeriods,
            );
            reach = reach.mergeWith(returnPeriodData);

            // Update cache with complete data
            await _cacheService.store(reach);
            AppLogger.info('ForecastService', 'Added return period data');
          }
        } catch (e) {
          AppLogger.warning('ForecastService', 'Return periods failed, continuing: $e');
          // Continue without return periods
        }
      }

      // Load medium-range summary for forecast grid (don't need full data)
      // Data is already converted by NoaaApiService
      ForecastResponse enhancedResponse = existingData;
      try {
        final mediumRangeData = await _apiService.fetchForecast(
          reachId,
          'medium_range',
        );
        final mediumForecast = ForecastResponse.fromJson(mediumRangeData);

        enhancedResponse = ForecastResponse(
          reach: reach,
          analysisAssimilation: existingData.analysisAssimilation,
          shortRange: existingData.shortRange,
          mediumRange: mediumForecast.mediumRange,
          longRange: existingData.longRange,
          mediumRangeBlend: existingData.mediumRangeBlend,
        );
      } catch (e) {
        AppLogger.warning('ForecastService', 'Medium range forecast failed, continuing: $e');
        // Use existing data if medium range fails
        enhancedResponse = ForecastResponse(
          reach: reach,
          analysisAssimilation: existingData.analysisAssimilation,
          shortRange: existingData.shortRange,
          mediumRange: existingData.mediumRange,
          longRange: existingData.longRange,
          mediumRangeBlend: existingData.mediumRangeBlend,
        );
      }

      // UPDATED: Use unit-aware flow category calculation
      if (reach.hasReturnPeriods) {
        final currentFlow = getCurrentFlow(enhancedResponse);
        if (currentFlow != null) {
          // Use the current unit from service - forecast data is already converted
          final currentUnit = _unitService.currentFlowUnit;
          _flowCategoryCache[reachId] = reach.getFlowCategory(
            currentFlow,
            currentUnit,
          );
        }
      }

      AppLogger.info('ForecastService', 'Supplementary data loaded successfully');
      return enhancedResponse;
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading supplementary data', e);
      // Return existing data if supplementary loading fails
      return existingData;
    }
  }

  // Keep for backwards compatibility and detail pages
  /// Load complete reach and forecast data
  /// Returns ForecastResponse with all available forecast types
  /// Uses cache for static reach data, always fetches fresh forecast data
  Future<ForecastResponse> loadCompleteReachData(String reachId) async {
    try {
      AppLogger.debug('ForecastService', 'Loading complete data for reach: $reachId');

      // Step 1: Check cache for reach data first
      final cachedReach = await _cacheService.get(reachId);

      ReachData reach;
      if (cachedReach != null) {
        AppLogger.info('ForecastService', 'Using cached reach data');
        reach = cachedReach;
      } else {
        AppLogger.debug('ForecastService', 'Cache miss - fetching fresh reach data');

        // Step 2: Get reach info and return periods in parallel
        final futures = await Future.wait([
          _apiService.fetchReachInfo(reachId),
          _apiService.fetchReturnPeriods(reachId),
        ]);

        final reachInfo = futures[0] as Map<String, dynamic>;
        final returnPeriods = futures[1] as List<dynamic>;

        AppLogger.info('ForecastService', 'Loaded reach info and return periods');

        // Step 3: Create complete reach data
        reach = ReachData.fromNoaaApi(reachInfo);

        // Wrap return period processing in try-catch
        try {
          // Merge return periods if available
          if (returnPeriods.isNotEmpty) {
            final returnPeriodData = ReachData.fromReturnPeriodApi(
              returnPeriods,
            );
            reach = reach.mergeWith(returnPeriodData);
            AppLogger.info('ForecastService', 'Merged return period data');
          }
        } catch (e) {
          AppLogger.warning('ForecastService', 'Failed to parse return periods for reach $reachId: $e');
          AppLogger.info('ForecastService', 'Continuing without return period data');
          // Continue without return periods - the reach will work fine without them
          // No need to throw or break the entire loading process
        }

        // Step 4: Cache the complete reach data
        await _cacheService.store(reach);
        AppLogger.info('ForecastService', 'Cached reach data');
      }

      // Step 5: Always get fresh forecast data (this changes frequently)
      // Data is already converted by NoaaApiService
      final forecastData = await _apiService.fetchAllForecasts(reachId);
      AppLogger.info('ForecastService', 'Loaded fresh forecast data');

      // Step 6: Create forecast response with cached/fresh reach data + fresh forecasts
      final forecastResponse = ForecastResponse.fromJson(forecastData);
      final completeResponse = ForecastResponse(
        reach: reach, // Use cached or fresh reach data
        analysisAssimilation: forecastResponse.analysisAssimilation,
        shortRange: forecastResponse.shortRange,
        mediumRange: forecastResponse.mediumRange,
        longRange: forecastResponse.longRange,
        mediumRangeBlend: forecastResponse.mediumRangeBlend,
      );

      // UPDATED: Update caches with unit-aware flow category
      final currentFlow = getCurrentFlow(completeResponse);
      if (currentFlow != null) {
        _currentFlowCache[reachId] = currentFlow;
        if (reach.hasReturnPeriods) {
          // Use the current unit from service - forecast data is already converted
          final currentUnit = _unitService.currentFlowUnit;
          _flowCategoryCache[reachId] = reach.getFlowCategory(
            currentFlow,
            currentUnit,
          );
        }
      }

      AppLogger.info('ForecastService', 'Complete data loaded successfully');
      return completeResponse;
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading complete data', e);
      rethrow;
    }
  }

  /// Load only specific forecast type (faster for simple displays)
  /// Also uses cache for reach data
  Future<ForecastResponse> loadSpecificForecast(
    String reachId,
    String forecastType,
  ) async {
    try {
      AppLogger.debug('ForecastService', 'Loading $forecastType forecast for reach: $reachId');

      // Check cache for reach data first
      final cachedReach = await _cacheService.get(reachId);

      ReachData reach;
      if (cachedReach != null) {
        AppLogger.info('ForecastService', 'Using cached reach data for specific forecast');
        reach = cachedReach;

        // Only fetch the specific forecast (already converted by NoaaApiService)
        final forecastData = await _apiService.fetchForecast(
          reachId,
          forecastType,
        );
        final forecastResponse = ForecastResponse.fromJson(forecastData);

        final specificResponse = ForecastResponse(
          reach: reach, // Use cached reach data
          analysisAssimilation: forecastResponse.analysisAssimilation,
          shortRange: forecastResponse.shortRange,
          mediumRange: forecastResponse.mediumRange,
          longRange: forecastResponse.longRange,
          mediumRangeBlend: forecastResponse.mediumRangeBlend,
        );

        AppLogger.info('ForecastService', '$forecastType forecast loaded with cached reach data');
        return specificResponse;
      } else {
        // Cache miss - get both reach info and forecast
        final futures = await Future.wait([
          _apiService.fetchReachInfo(reachId),
          _apiService.fetchForecast(reachId, forecastType),
        ]);

        final reachInfo = futures[0];
        final forecastData = futures[1];

        // Create reach data and cache it
        reach = ReachData.fromNoaaApi(reachInfo);
        await _cacheService.store(reach);

        // Parse forecast response (already converted)
        final forecastResponse = ForecastResponse.fromJson(forecastData);
        final specificResponse = ForecastResponse(
          reach: reach,
          analysisAssimilation: forecastResponse.analysisAssimilation,
          shortRange: forecastResponse.shortRange,
          mediumRange: forecastResponse.mediumRange,
          longRange: forecastResponse.longRange,
          mediumRangeBlend: forecastResponse.mediumRangeBlend,
        );

        AppLogger.info('ForecastService', '$forecastType forecast loaded and reach data cached');
        return specificResponse;
      }
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading $forecastType forecast', e);
      rethrow;
    }
  }

  /// Force refresh reach data (clear cache and fetch fresh)
  Future<ForecastResponse> refreshReachData(String reachId) async {
    AppLogger.debug('ForecastService', 'Force refreshing reach data for: $reachId');
    await _cacheService.forceRefresh(reachId);

    // Clear computed caches too
    _currentFlowCache.remove(reachId);
    _flowCategoryCache.remove(reachId);

    return await loadCompleteReachData(reachId);
  }

  /// Check if reach data is cached
  Future<bool> isReachCached(String reachId) async {
    return await _cacheService.isCached(reachId);
  }

  /// Get cache statistics for debugging
  Future<Map<String, dynamic>> getCacheStats() async {
    return await _cacheService.getCacheStats();
  }

  // ===== EFFICIENT LOADING METHODS FOR FAVORITES =====

  /// Load only current flow data for favorites display (optimized)
  /// Gets: reach info + current flow + return periods only
  /// Skips: hourly/daily/extended forecast arrays (90% data reduction)
  Future<ForecastResponse> loadCurrentFlowOnly(String reachId) async {
    try {
      AppLogger.debug('ForecastService', 'Loading current flow only for: $reachId');

      // Step 1: Check cache for reach data first
      final cachedReach = await _cacheService.get(reachId);

      ReachData reach;
      if (cachedReach != null) {
        AppLogger.info('ForecastService', 'Using cached reach data for current flow');
        reach = cachedReach;
      } else {
        // Load fresh reach data with return periods
        final futures = await Future.wait([
          _apiService.fetchReachInfo(reachId),
          _apiService.fetchReturnPeriods(reachId),
        ]);

        final reachInfo = futures[0] as Map<String, dynamic>;
        final returnPeriods = futures[1] as List<dynamic>;

        // Create reach data
        reach = ReachData.fromNoaaApi(reachInfo);

        // Add return periods if available
        try {
          if (returnPeriods.isNotEmpty) {
            final returnPeriodData = ReachData.fromReturnPeriodApi(
              returnPeriods,
            );
            reach = reach.mergeWith(returnPeriodData);
          }
        } catch (e) {
          AppLogger.warning('ForecastService', 'Failed to parse return periods: $e');
          // Continue without return periods
        }

        // Cache the reach data
        await _cacheService.store(reach);
        AppLogger.info('ForecastService', 'Cached reach data');
      }

      // Step 2: Use the working loadOverviewData method instead
      // This properly handles the forecast parsing (already converted by NoaaApiService)
      final currentFlowData = await _apiService.fetchCurrentFlowOnly(reachId);

      // Parse using the same parser that works in loadOverviewData
      final forecastResponse = ForecastResponse.fromJson(currentFlowData);

      // Step 3: Create response with proper reach data
      final lightweightResponse = ForecastResponse(
        reach: reach, // Use our properly loaded reach with return periods
        analysisAssimilation: forecastResponse.analysisAssimilation,
        shortRange: forecastResponse.shortRange,
        mediumRange: {}, // Empty for efficiency
        longRange: {}, // Empty for efficiency
        mediumRangeBlend: null, // Empty for efficiency
      );

      AppLogger.info('ForecastService', 'Current flow only loaded successfully');
      return lightweightResponse;
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading current flow only', e);
      rethrow;
    }
  }

  /// Load basic reach info only (coordinates + name) for map integration
  /// Ultra-lightweight for map heart button functionality
  Future<ReachData> loadBasicReachInfo(String reachId) async {
    try {
      AppLogger.debug('ForecastService', 'Loading basic reach info for: $reachId');

      // Check cache first for super-fast response
      final cachedReach = await _cacheService.get(reachId);
      if (cachedReach != null) {
        AppLogger.info('ForecastService', 'Using cached basic reach info');
        return cachedReach;
      }

      // Load minimal reach info only
      final reachInfo = await _apiService.fetchReachInfo(reachId);
      final reach = ReachData.fromNoaaApi(reachInfo);

      // Cache for future use
      await _cacheService.store(reach);

      AppLogger.info('ForecastService', 'Basic reach info loaded and cached');
      return reach;
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading basic reach info', e);
      rethrow;
    }
  }

  /// Merge current flow data with existing favorite data efficiently
  /// Helper method for updating favorites without losing existing info
  ForecastResponse mergeCurrentFlowData(
    ForecastResponse existing,
    ForecastResponse newFlowData,
  ) {
    return ForecastResponse(
      reach: existing.reach, // Keep existing reach data
      // Update only current flow data (already converted by NoaaApiService)
      analysisAssimilation: newFlowData.analysisAssimilation?.isNotEmpty == true
          ? newFlowData.analysisAssimilation
          : existing.analysisAssimilation,
      shortRange: newFlowData.shortRange?.isNotEmpty == true
          ? newFlowData.shortRange
          : existing.shortRange,
      // Keep existing forecast arrays (if any) - don't overwrite with empty
      mediumRange: existing.mediumRange,
      longRange: existing.longRange,
      mediumRangeBlend: existing.mediumRangeBlend,
    );
  }

  // Use cache first, then compute if needed
  /// Get current flow value for display - now with caching
  /// NOTE: Flow values are already converted by NoaaApiService
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType}) {
    final reachId = forecast.reach.reachId;

    // Check cache first
    if (_currentFlowCache.containsKey(reachId)) {
      return _currentFlowCache[reachId];
    }

    // Priority order for current flow display
    final types = preferredType != null
        ? [preferredType, 'short_range', 'medium_range', 'long_range']
        : ['short_range', 'medium_range', 'long_range'];

    for (final type in types) {
      final flow = forecast.getLatestFlow(type);
      // Filter out missing data values
      if (flow != null && flow > -9000) {
        // Check for missing data sentinel values
        AppLogger.debug('ForecastService', 'Using $type for current flow: $flow ${_unitService.currentFlowUnit}');

        // Cache the result
        _currentFlowCache[reachId] = flow;
        return flow;
      }
    }

    AppLogger.debug('ForecastService', 'No current flow data available');
    _currentFlowCache[reachId] = null; // Cache null result too
    return null;
  }

  // Use cache first, then compute if needed
  /// UPDATED: Get flow category with return period context - now unit-aware
  String getFlowCategory(ForecastResponse forecast, {String? preferredType}) {
    final reachId = forecast.reach.reachId;

    // Check cache first
    if (_flowCategoryCache.containsKey(reachId)) {
      return _flowCategoryCache[reachId]!;
    }

    final flow = getCurrentFlow(forecast, preferredType: preferredType);
    if (flow == null) return 'Unknown';

    // UPDATED: Use unit-aware flow category calculation
    // Flow values are already in the correct unit from NoaaApiService
    final currentUnit = _unitService.currentFlowUnit;
    final category = forecast.reach.getFlowCategory(flow, currentUnit);

    // Cache the result
    _flowCategoryCache[reachId] = category;
    return category;
  }

  /// Get available forecast types
  List<String> getAvailableForecastTypes(ForecastResponse forecast) {
    final available = <String>[];

    if (forecast.shortRange?.isNotEmpty == true) {
      available.add('short_range');
    }
    if (forecast.mediumRange.isNotEmpty) {
      available.add('medium_range');
    }
    if (forecast.longRange.isNotEmpty) {
      available.add('long_range');
    }
    if (forecast.analysisAssimilation?.isNotEmpty == true) {
      available.add('analysis_assimilation');
    }
    if (forecast.mediumRangeBlend?.isNotEmpty == true) {
      available.add('medium_range_blend');
    }

    return available;
  }

  /// Check if reach has ensemble data for hydrographs
  bool hasEnsembleData(ForecastResponse forecast) {
    return forecast.mediumRange.length > 1 || forecast.longRange.length > 1;
  }

  /// Get ensemble summary for a forecast type
  Map<String, dynamic> getEnsembleSummary(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensemble = forecast.getAllEnsembleData(forecastType);
    if (ensemble.isEmpty) {
      return {'available': false};
    }

    final memberKeys = ensemble.keys
        .where((k) => k.startsWith('member'))
        .toList();
    final hasMean = ensemble.containsKey('mean');

    return {
      'available': true,
      'hasMean': hasMean,
      'memberCount': memberKeys.length,
      'members': memberKeys,
      'dataSource': forecast.getDataSource(forecastType),
    };
  }

  /// Extract hourly data points for short-range forecast with trends
  /// Filters out past hours - only shows current hour and future
  /// NOTE: Flow values are already converted by NoaaApiService
  List<HourlyFlowDataPoint> getShortRangeHourlyData(ForecastResponse forecast) {
    if (forecast.shortRange == null || forecast.shortRange!.isEmpty) {
      return [];
    }

    final shortRange = forecast.shortRange!;
    final now = DateTime.now();
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);

    // Filter out past hours - only include current hour and future
    final futureData = shortRange.data.where((point) {
      final pointHour = DateTime(
        point.validTime.toLocal().year,
        point.validTime.toLocal().month,
        point.validTime.toLocal().day,
        point.validTime.toLocal().hour,
      );
      return pointHour.isAtSameMomentAs(currentHour) ||
          pointHour.isAfter(currentHour);
    }).toList();

    final List<HourlyFlowDataPoint> hourlyData = [];

    for (int i = 0; i < futureData.length; i++) {
      final point = futureData[i];

      // Calculate trend from previous hour
      FlowTrend? trend;
      double? trendPercentage;

      if (i > 0) {
        final previousFlow = futureData[i - 1].flow;
        final change = point.flow - previousFlow;
        final changePercent = (change / previousFlow) * 100;

        if (change.abs() > 5) {
          // 5 unit threshold for trend detection (works for both CFS and CMS)
          trend = change > 0 ? FlowTrend.rising : FlowTrend.falling;
          trendPercentage = changePercent.abs();
        } else {
          trend = FlowTrend.stable;
          trendPercentage = 0.0;
        }
      }

      hourlyData.add(
        HourlyFlowDataPoint(
          validTime: point.validTime.toLocal(), // Convert UTC to local time
          flow: point.flow, // Already converted to preferred unit
          trend: trend,
          trendPercentage: trendPercentage,
          confidence: 0.95 - (i * 0.02), // Decreasing confidence over time
        ),
      );
    }

    return hourlyData;
  }

  /// Get ALL short-range hourly data (including past hours) for charts
  /// This is the unfiltered version needed for complete visualization
  /// NOTE: Flow values are already converted by NoaaApiService
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData(
    ForecastResponse forecast,
  ) {
    if (forecast.shortRange == null || forecast.shortRange!.isEmpty) {
      return [];
    }

    final shortRange = forecast.shortRange!;
    // NO FILTERING - use all 18 hours from API
    final allData = shortRange.data;

    final List<HourlyFlowDataPoint> hourlyData = [];
    for (int i = 0; i < allData.length; i++) {
      final point = allData[i];
      // Calculate trend from previous hour
      FlowTrend? trend;
      double? trendPercentage;

      if (i > 0) {
        final previousFlow = allData[i - 1].flow;
        final change = point.flow - previousFlow;
        final changePercent = (change / previousFlow) * 100;

        if (change.abs() > 5) {
          // 5 unit threshold for trend detection (works for both CFS and CMS)
          trend = change > 0 ? FlowTrend.rising : FlowTrend.falling;
          trendPercentage = changePercent.abs();
        } else {
          trend = FlowTrend.stable;
          trendPercentage = 0.0;
        }
      }

      hourlyData.add(
        HourlyFlowDataPoint(
          validTime: point.validTime.toLocal(), // Convert UTC to local time
          flow: point.flow, // Already converted to preferred unit
          trend: trend,
          trendPercentage: trendPercentage,
          confidence: 0.95 - (i * 0.02), // Decreasing confidence over time
        ),
      );
    }
    return hourlyData;
  }

  /// Get ensemble statistics for uncertainty visualization
  /// Returns min, max, and mean values at each time point
  /// NOTE: Flow values are already converted by NoaaApiService
  List<EnsembleStatPoint> getEnsembleStatistics(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);

    // Get only the member data (exclude mean if present, we'll calculate our own)
    final members = ensembleData.entries
        .where((e) => e.key.startsWith('member'))
        .map((e) => e.value)
        .where((series) => series.isNotEmpty)
        .toList();

    if (members.isEmpty) return [];

    // Group by time point
    final timeGroups = <DateTime, List<double>>{};

    for (final member in members) {
      for (final point in member.data) {
        final time = point.validTime.toLocal();
        timeGroups[time] ??= [];
        timeGroups[time]!.add(point.flow); // Already converted
      }
    }

    // Calculate statistics for each time point
    final stats = <EnsembleStatPoint>[];
    final sortedTimes = timeGroups.keys.toList()..sort();

    for (final time in sortedTimes) {
      final flows = timeGroups[time]!;
      if (flows.isNotEmpty) {
        flows.sort();
        stats.add(
          EnsembleStatPoint(
            time: time,
            minFlow: flows.first,
            maxFlow: flows.last,
            meanFlow: flows.reduce((a, b) => a + b) / flows.length,
            memberCount: flows.length,
          ),
        );
      }
    }

    return stats;
  }

  /// Check if forecast has multiple ensemble members (for UI decisions)
  bool hasMultipleEnsembleMembers(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);
    final memberCount = ensembleData.keys
        .where((k) => k.startsWith('member'))
        .length;
    return memberCount > 1;
  }

  // ===== NEW METHODS FOR CHART DISPLAY (NO CONFLICTS) =====

  /// Get all ensemble data ready for chart display
  /// Returns Map<String, List<ChartData where ChartData has x,y coordinates
  /// This replaces the conflicting getAllEnsembleChartData method
  /// NOTE: Flow values are already converted by NoaaApiService
  Map<String, List<ChartData>> getEnsembleSeriesForChart(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);
    final chartSeries = <String, List<ChartData>>{};

    // Find earliest time for reference point (for x-axis calculation)
    DateTime? earliestTime;
    for (final entry in ensembleData.entries) {
      final series = entry.value;
      if (series.isNotEmpty) {
        final firstTime = series.data.first.validTime.toLocal();
        if (earliestTime == null || firstTime.isBefore(earliestTime)) {
          earliestTime = firstTime;
        }
      }
    }

    if (earliestTime == null) return chartSeries;

    for (final entry in ensembleData.entries) {
      final memberName = entry.key;
      final series = entry.value;

      if (series.isEmpty) continue;

      final chartData = series.data.map((point) {
        final localTime = point.validTime.toLocal();
        final hoursDiff = localTime
            .difference(earliestTime!)
            .inHours
            .toDouble();

        return ChartData(hoursDiff, point.flow); // Already converted
      }).toList();

      chartSeries[memberName] = chartData;
    }

    AppLogger.debug('ForecastService', 'Generated ${chartSeries.length} chart series for $forecastType (${_unitService.currentFlowUnit})');
    return chartSeries;
  }

  /// Get ensemble data as time-based points (for bounds calculation in charts)
  /// Returns the first available series as ChartDataPoint (DateTime, flow) for interactive_chart.dart
  /// NOTE: Flow values are already converted by NoaaApiService
  List<ChartDataPoint> getEnsembleReferenceData(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);

    // Get the first available series for reference
    for (final entry in ensembleData.entries) {
      final series = entry.value;
      if (series.isNotEmpty) {
        return series.data
            .map(
              (point) => ChartDataPoint(
                time: point.validTime.toLocal(),
                flow: point.flow, // Already converted
              ),
            )
            .toList();
      }
    }

    return [];
  }

  void clearUnitDependentCaches() {
    AppLogger.debug('ForecastService', 'Clearing unit-dependent caches for unit change');

    // Clear flow and category caches (these depend on units)
    _currentFlowCache.clear();
    _flowCategoryCache.clear();
  }

  // Clear all caches (useful for testing)
  void clearComputedCaches() {
    _currentFlowCache.clear();
    _flowCategoryCache.clear();
    AppLogger.debug('ForecastService', 'Cleared computed value caches');
  }
}

// Simple data classes for ensemble display
class EnsembleStatPoint {
  final DateTime time;
  final double minFlow;
  final double maxFlow;
  final double meanFlow;
  final int memberCount;

  const EnsembleStatPoint({
    required this.time,
    required this.minFlow,
    required this.maxFlow,
    required this.meanFlow,
    required this.memberCount,
  });
}

// Internal ChartDataPoint class for forecast_service.dart (time-based)
class ChartDataPoint {
  final DateTime time;
  final double flow;
  final double? confidence;
  final Map<String, dynamic>? metadata;

  const ChartDataPoint({
    required this.time,
    required this.flow,
    this.confidence,
    this.metadata,
  });
}

// Simple ChartData class for chart output (x,y coordinates)
class ChartData {
  final double x;
  final double y;

  ChartData(this.x, this.y);
}
