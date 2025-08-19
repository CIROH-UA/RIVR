// lib/core/models/reach_data.dart

import '../services/flow_unit_preference_service.dart';

class ReachData {
  // NOAA reach info
  final String reachId; // "23021904"
  final String riverName; // "Deep Creek" (from reaches API 'name' field)
  final double latitude;
  final double longitude;

  // Location context (from geocoding)
  final String? city; // "Spokane"
  final String? state; // "WA"

  // Available forecast types (from reaches API 'streamflow' array)
  final List<String>
  availableForecasts; // ["analysis_assimilation", "short_range", etc.]

  // Return periods (from separate return-period API - always in CMS)
  final Map<int, double>?
  returnPeriods; // {2: 3518.03, 5: 6119.41, 10: 7841.75}
  final String returnPeriodUnit = 'cms'; // Always CMS from API

  // Routing info (from reaches API)
  final List<String>? upstreamReaches; // ["23021906", "23023198"]
  final List<String>? downstreamReaches; // ["23022058"]

  // User customization
  final String?
  customName; // User can rename "Deep Creek" to "My Favorite Creek"

  // Cache metadata
  final DateTime cachedAt;
  final DateTime? lastApiUpdate;

  // Partial loading state
  final bool isPartiallyLoaded;

  ReachData({
    required this.reachId,
    required this.riverName,
    required this.latitude,
    required this.longitude,
    this.city,
    this.state,
    required this.availableForecasts,
    this.returnPeriods,
    this.upstreamReaches,
    this.downstreamReaches,
    this.customName,
    required this.cachedAt,
    this.lastApiUpdate,
    this.isPartiallyLoaded = false,
  });

  // Factory constructor from NOAA reaches API
  factory ReachData.fromNoaaApi(Map<String, dynamic> json) {
    try {
      final route = json['route'] as Map<String, dynamic>?;

      return ReachData(
        reachId: (json['reachId'] as String).trim(),
        riverName: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        availableForecasts: (json['streamflow'] as List<dynamic>)
            .map((e) => e.toString())
            .toList(),
        upstreamReaches: route?['upstream'] != null
            ? (route!['upstream'] as List<dynamic>)
                  .map((e) => (e as Map<String, dynamic>)['reachId'] as String)
                  .toList()
            : null,
        downstreamReaches: route?['downstream'] != null
            ? (route!['downstream'] as List<dynamic>)
                  .map((e) => (e as Map<String, dynamic>)['reachId'] as String)
                  .toList()
            : null,
        cachedAt: DateTime.now(),
        isPartiallyLoaded: false,
      );
    } catch (e) {
      throw FormatException('Failed to parse NOAA reaches API response: $e');
    }
  }

  // Factory constructor from return period API (array response)
  factory ReachData.fromReturnPeriodApi(List<dynamic> jsonArray) {
    try {
      if (jsonArray.isEmpty) {
        throw FormatException('Return period API returned empty array');
      }

      final json = jsonArray.first as Map<String, dynamic>;
      final featureId = json['feature_id'].toString();

      final returnPeriods = <int, double>{};

      // Parse all available return periods
      for (final entry in json.entries) {
        if (entry.key.startsWith('return_period_')) {
          final years = int.tryParse(
            entry.key.substring('return_period_'.length),
          );
          final flow = (entry.value as num).toDouble();
          if (years != null) {
            returnPeriods[years] = flow;
          }
        }
      }

      return ReachData(
        reachId: featureId,
        riverName: 'Unknown', // Will be filled from reaches API
        latitude: 0.0, // Will be filled from reaches API
        longitude: 0.0, // Will be filled from reaches API
        availableForecasts: [],
        returnPeriods: returnPeriods,
        cachedAt: DateTime.now(),
        isPartiallyLoaded: true, // This is partial data
      );
    } catch (e) {
      throw FormatException('Failed to parse return period API response: $e');
    }
  }

  // Factory constructor from cached JSON
  factory ReachData.fromJson(Map<String, dynamic> json) {
    return ReachData(
      reachId: json['reachId'] as String,
      riverName: json['riverName'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      city: json['city'] as String?,
      state: json['state'] as String?,
      availableForecasts: (json['availableForecasts'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
      returnPeriods: json['returnPeriods'] != null
          ? Map<int, double>.from(
              (json['returnPeriods'] as Map<String, dynamic>).map(
                (key, value) =>
                    MapEntry(int.parse(key), (value as num).toDouble()),
              ),
            )
          : null,
      upstreamReaches: json['upstreamReaches'] != null
          ? (json['upstreamReaches'] as List<dynamic>)
                .map((e) => e.toString())
                .toList()
          : null,
      downstreamReaches: json['downstreamReaches'] != null
          ? (json['downstreamReaches'] as List<dynamic>)
                .map((e) => e.toString())
                .toList()
          : null,
      customName: json['customName'] as String?,
      cachedAt: DateTime.parse(json['cachedAt'] as String),
      lastApiUpdate: json['lastApiUpdate'] != null
          ? DateTime.parse(json['lastApiUpdate'] as String)
          : null,
      isPartiallyLoaded: json['isPartiallyLoaded'] as bool? ?? false,
    );
  }

  // Convert to JSON for caching
  Map<String, dynamic> toJson() {
    return {
      'reachId': reachId,
      'riverName': riverName,
      'latitude': latitude,
      'longitude': longitude,
      'city': city,
      'state': state,
      'availableForecasts': availableForecasts,
      'returnPeriods': returnPeriods?.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      'upstreamReaches': upstreamReaches,
      'downstreamReaches': downstreamReaches,
      'customName': customName,
      'cachedAt': cachedAt.toIso8601String(),
      'lastApiUpdate': lastApiUpdate?.toIso8601String(),
      'isPartiallyLoaded': isPartiallyLoaded,
    };
  }

  // Merge with data from another source (like return periods)
  ReachData mergeWith(ReachData other) {
    return ReachData(
      reachId: reachId,
      riverName: riverName.isNotEmpty ? riverName : other.riverName,
      latitude: latitude != 0.0 ? latitude : other.latitude,
      longitude: longitude != 0.0 ? longitude : other.longitude,
      city: city ?? other.city,
      state: state ?? other.state,
      availableForecasts: availableForecasts.isNotEmpty
          ? availableForecasts
          : other.availableForecasts,
      returnPeriods: returnPeriods ?? other.returnPeriods,
      upstreamReaches: upstreamReaches ?? other.upstreamReaches,
      downstreamReaches: downstreamReaches ?? other.downstreamReaches,
      customName: customName ?? other.customName,
      cachedAt: DateTime.now(),
      lastApiUpdate: other.lastApiUpdate ?? lastApiUpdate,
      isPartiallyLoaded: false, // Merged data is complete
    );
  }

  // Update with user customizations
  ReachData copyWith({
    String? customName,
    String? city,
    String? state,
    DateTime? lastApiUpdate,
    bool? isPartiallyLoaded,
  }) {
    return ReachData(
      reachId: reachId,
      riverName: riverName,
      latitude: latitude,
      longitude: longitude,
      city: city ?? this.city,
      state: state ?? this.state,
      availableForecasts: availableForecasts,
      returnPeriods: returnPeriods,
      upstreamReaches: upstreamReaches,
      downstreamReaches: downstreamReaches,
      customName: customName ?? this.customName,
      cachedAt: cachedAt,
      lastApiUpdate: lastApiUpdate ?? this.lastApiUpdate,
      isPartiallyLoaded: isPartiallyLoaded ?? this.isPartiallyLoaded,
    );
  }

  // Helper methods
  String get displayName => customName ?? riverName;
  bool get hasCustomName => customName != null && customName!.isNotEmpty;

  // Location formatting for subtitles
  String get formattedLocation =>
      city != null && state != null ? '$city, $state' : '';

  // Location subtitle with coordinate fallback (fixes the subtitle issue)
  String get formattedLocationSubtitle {
    if (city != null && state != null) {
      return '$city, $state';
    }
    // Fallback to coordinates if no city/state
    return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
  }

  bool get hasReturnPeriods =>
      returnPeriods != null && returnPeriods!.isNotEmpty;

  // Check if core location data is available
  bool get hasLocationData =>
      latitude != 0.0 && longitude != 0.0 && riverName != 'Unknown';

  bool isCacheStale({Duration maxAge = const Duration(days: 180)}) {
    return DateTime.now().difference(cachedAt) > maxAge;
  }

  /// NEW: Get return periods converted to specified unit
  Map<int, double>? getReturnPeriodsInUnit(String targetUnit) {
    if (returnPeriods == null) return null;

    final converter = FlowUnitPreferenceService();
    return returnPeriods!.map(
      (year, cmsValue) =>
          MapEntry(year, converter.convertFlow(cmsValue, 'CMS', targetUnit)),
    );
  }

  /// UPDATED: Get flood risk category based on NOAA return periods (unit-agnostic)
  String getFlowCategory(double flowValue, String flowUnit) {
    if (!hasReturnPeriods) return 'Unknown';

    // Get return periods in the same unit as the flow value
    final periods = getReturnPeriodsInUnit(flowUnit);
    if (periods == null) return 'Unknown';

    // Get threshold values for each return period
    final threshold2yr = periods[2];
    final threshold5yr = periods[5];
    final threshold10yr = periods[10];
    final threshold25yr = periods[25];

    // Classify flow based on NOAA flood risk categories
    if (threshold2yr != null && flowValue < threshold2yr) {
      return 'Normal'; // Below 2-year return period
    }

    if (threshold5yr != null && flowValue < threshold5yr) {
      return 'Action'; // Above 2-year, below 5-year return period
    }

    if (threshold10yr != null && flowValue < threshold10yr) {
      return 'Moderate'; // Above 5-year, below 10-year return period
    }

    if (threshold25yr != null && flowValue < threshold25yr) {
      return 'Major'; // Above 10-year, below 25-year return period
    }

    return 'Extreme'; // Above 25-year return period
  }

  // Get next return period threshold
  MapEntry<int, double>? getNextThreshold(double flowCfs) {
    if (!hasReturnPeriods) return null;

    final flowCms = flowCfs * 0.0283168;
    final periods = returnPeriods!.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final period in periods) {
      if (flowCms < period.value) {
        return period;
      }
    }

    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReachData &&
          runtimeType == other.runtimeType &&
          reachId == other.reachId;

  @override
  int get hashCode => reachId.hashCode;

  @override
  String toString() {
    return 'ReachData{reachId: $reachId, displayName: $displayName, location: $formattedLocationSubtitle, hasReturnPeriods: $hasReturnPeriods, isPartial: $isPartiallyLoaded}';
  }
}

class ForecastPoint {
  final DateTime validTime;
  final double flow;

  ForecastPoint({required this.validTime, required this.flow});

  factory ForecastPoint.fromJson(Map<String, dynamic> json) {
    return ForecastPoint(
      validTime: DateTime.parse(json['validTime'] as String),
      flow: (json['flow'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'validTime': validTime.toIso8601String(), 'flow': flow};
  }

  @override
  String toString() => 'ForecastPoint{validTime: $validTime, flow: $flow}';
}

class ForecastSeries {
  final DateTime? referenceTime;
  final String units;
  final List<ForecastPoint> data;

  ForecastSeries({this.referenceTime, required this.units, required this.data});

  /// NEW: Factory constructor for unit conversion
  factory ForecastSeries.withPreferredUnits({
    required String originalUnits,
    required String preferredUnits,
    required List<ForecastPoint> originalData,
    DateTime? referenceTime,
  }) {
    final converter = FlowUnitPreferenceService();
    final convertedData = originalData
        .map(
          (point) => ForecastPoint(
            validTime: point.validTime,
            flow: converter.convertFlow(
              point.flow,
              originalUnits,
              preferredUnits,
            ),
          ),
        )
        .toList();

    return ForecastSeries(
      referenceTime: referenceTime,
      units: preferredUnits,
      data: convertedData,
    );
  }

  factory ForecastSeries.fromJson(Map<String, dynamic> json) {
    return ForecastSeries(
      referenceTime: json['referenceTime'] != null
          ? DateTime.parse(json['referenceTime'] as String)
          : null,
      units: json['units'] as String? ?? '',
      data: json['data'] != null
          ? (json['data'] as List<dynamic>)
                .map((e) => ForecastPoint.fromJson(e as Map<String, dynamic>))
                .toList()
          : [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'referenceTime': referenceTime?.toIso8601String(),
      'units': units,
      'data': data.map((e) => e.toJson()).toList(),
    };
  }

  bool get isEmpty => data.isEmpty;
  bool get isNotEmpty => data.isNotEmpty;

  // Get flow at specific time (or closest)
  double? getFlowAt(DateTime time) {
    if (data.isEmpty) return null;

    ForecastPoint? closest;
    Duration? minDiff;

    for (final point in data) {
      final diff = point.validTime.difference(time).abs();
      if (minDiff == null || diff < minDiff) {
        minDiff = diff;
        closest = point;
      }
    }

    return closest?.flow;
  }

  // Get flow for current hour bucket (not just closest time)
  double? getCurrentHourFlow() {
    if (data.isEmpty) return null;

    final now = DateTime.now();
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);

    // First, try to find exact current hour match
    for (final point in data) {
      final pointHour = DateTime(
        point.validTime.toLocal().year,
        point.validTime.toLocal().month,
        point.validTime.toLocal().day,
        point.validTime.toLocal().hour,
      );

      if (pointHour == currentHour) {
        return point.flow;
      }
    }

    // If no current hour found, look for next future hour
    for (final point in data) {
      final pointHour = DateTime(
        point.validTime.toLocal().year,
        point.validTime.toLocal().month,
        point.validTime.toLocal().day,
        point.validTime.toLocal().hour,
      );

      if (pointHour.isAfter(currentHour)) {
        return point.flow;
      }
    }

    // Fallback to closest time if no current/future hour found
    return getFlowAt(DateTime.now().toUtc());
  }

  @override
  String toString() =>
      'ForecastSeries{referenceTime: $referenceTime, units: $units, points: ${data.length}}';
}

class ForecastResponse {
  final ReachData reach;
  final ForecastSeries? analysisAssimilation;
  final ForecastSeries? shortRange;
  final Map<String, ForecastSeries> mediumRange; // mean, member1, member2, etc.
  final Map<String, ForecastSeries> longRange; // mean, member1, member2, etc.
  final ForecastSeries? mediumRangeBlend;

  ForecastResponse({
    required this.reach,
    this.analysisAssimilation,
    this.shortRange,
    required this.mediumRange,
    required this.longRange,
    this.mediumRangeBlend,
  });

  factory ForecastResponse.fromJson(Map<String, dynamic> json) {
    return ForecastResponse(
      reach: ReachData.fromNoaaApi(json['reach'] as Map<String, dynamic>),
      analysisAssimilation: _parseForecastSection(
        json['analysisAssimilation'],
        'analysis_assimilation',
      ),
      shortRange: _parseForecastSection(json['shortRange'], 'short_range'),
      mediumRange: _parseEnsembleForecast(json['mediumRange'], 'medium_range'),
      longRange: _parseEnsembleForecast(json['longRange'], 'long_range'),
      mediumRangeBlend: _parseForecastSection(
        json['mediumRangeBlend'],
        'medium_range_blend',
      ),
    );
  }

  // Enhanced parsing for single forecasts with series or mean data
  static ForecastSeries? _parseForecastSection(
    dynamic section,
    String forecastType,
  ) {
    if (section == null || section is! Map<String, dynamic>) {
      print('FORECAST_PARSER: No data for $forecastType');
      return null;
    }

    // STEP 1: Try 'series' data first (used by short_range)
    final series = section['series'];
    if (series != null && series is Map<String, dynamic>) {
      try {
        final forecastSeries = ForecastSeries.fromJson(series);
        if (forecastSeries.isNotEmpty) {
          print(
            'FORECAST_PARSER: Using series data for $forecastType (${forecastSeries.data.length} points)',
          );
          return forecastSeries;
        }
      } catch (e) {
        print('FORECAST_PARSER: Series data invalid for $forecastType: $e');
      }
    }

    // STEP 2: Try 'mean' data (used by medium_range/long_range sometimes)
    final mean = section['mean'];
    if (mean != null && mean is Map<String, dynamic>) {
      try {
        final forecastSeries = ForecastSeries.fromJson(mean);
        if (forecastSeries.isNotEmpty) {
          print(
            'FORECAST_PARSER: Using mean data for $forecastType (${forecastSeries.data.length} points)',
          );
          return forecastSeries;
        }
      } catch (e) {
        print('FORECAST_PARSER: Mean data invalid for $forecastType: $e');
      }
    }

    // STEP 3: Fall back to ensemble members dynamically
    final memberKeys = section.keys
        .where((key) => key.startsWith('member'))
        .toList();
    memberKeys.sort(); // member1, member2, etc.

    for (final memberKey in memberKeys) {
      final memberData = section[memberKey];
      if (memberData != null && memberData is Map<String, dynamic>) {
        try {
          final memberSeries = ForecastSeries.fromJson(memberData);
          if (memberSeries.isNotEmpty) {
            print(
              'FORECAST_PARSER: Using $memberKey data for $forecastType (${memberSeries.data.length} points)',
            );
            return memberSeries;
          }
        } catch (e) {
          print(
            'FORECAST_PARSER: $memberKey data invalid for $forecastType: $e',
          );
          continue; // Try next member
        }
      }
    }

    print(
      'FORECAST_PARSER: No valid data found for $forecastType (tried series, mean, and ${memberKeys.length} members)',
    );
    return null;
  }

  // Enhanced ensemble parsing to collect ALL available data
  static Map<String, ForecastSeries> _parseEnsembleForecast(
    dynamic section,
    String forecastType,
  ) {
    if (section == null || section is! Map<String, dynamic>) {
      print('FORECAST_PARSER: No ensemble data for $forecastType');
      return {};
    }

    final result = <String, ForecastSeries>{};

    // STEP 1: Try to get 'series' data and store as 'mean'
    final seriesData = section['series'];
    if (seriesData != null && seriesData is Map<String, dynamic>) {
      try {
        final series = ForecastSeries.fromJson(seriesData);
        if (series.isNotEmpty) {
          result['mean'] = series;
          print(
            'FORECAST_PARSER: Found series data for $forecastType as mean (${series.data.length} points)',
          );
        }
      } catch (e) {
        print('FORECAST_PARSER: Series data invalid for $forecastType: $e');
      }
    }

    // STEP 2: Try to get explicit 'mean' data (overrides series if both exist)
    final meanData = section['mean'];
    if (meanData != null && meanData is Map<String, dynamic>) {
      try {
        final mean = ForecastSeries.fromJson(meanData);
        if (mean.isNotEmpty) {
          result['mean'] = mean;
          print(
            'FORECAST_PARSER: Found explicit mean data for $forecastType (${mean.data.length} points)',
          );
        }
      } catch (e) {
        print('FORECAST_PARSER: Mean data invalid for $forecastType: $e');
      }
    }

    // STEP 3: Collect ALL ensemble members dynamically
    final memberKeys = section.keys
        .where((key) => key.startsWith('member'))
        .toList();
    memberKeys.sort(); // Ensure consistent ordering: member1, member2, etc.

    for (final memberKey in memberKeys) {
      final memberData = section[memberKey];
      if (memberData != null && memberData is Map<String, dynamic>) {
        try {
          final memberSeries = ForecastSeries.fromJson(memberData);
          if (memberSeries.isNotEmpty) {
            result[memberKey] = memberSeries;
          }
        } catch (e) {
          // Skip invalid members silently
          continue;
        }
      }
    }

    final memberCount = memberKeys.length;
    final validMemberCount = result.keys
        .where((k) => k.startsWith('member'))
        .length;

    print(
      'FORECAST_PARSER: Found ${result.length} valid series for $forecastType: ${result.keys.join(", ")} ($validMemberCount/$memberCount members valid)',
    );

    return result;
  }

  // Enhanced primary forecast getter with automatic fallback
  ForecastSeries? getPrimaryForecast(String forecastType) {
    switch (forecastType.toLowerCase()) {
      case 'analysis_assimilation':
        return analysisAssimilation;
      case 'short_range':
        return shortRange;
      case 'medium_range':
        // Try mean first, fall back to first available member
        if (mediumRange['mean']?.isNotEmpty == true) {
          return mediumRange['mean'];
        }
        // Dynamically find first available member
        final memberKeys = mediumRange.keys
            .where((k) => k.startsWith('member'))
            .toList();
        memberKeys.sort();
        for (final memberKey in memberKeys) {
          if (mediumRange[memberKey]?.isNotEmpty == true) {
            return mediumRange[memberKey];
          }
        }
        return null;
      case 'long_range':
        // Try mean first, fall back to first available member
        if (longRange['mean']?.isNotEmpty == true) {
          return longRange['mean'];
        }
        // Dynamically find first available member
        final memberKeys = longRange.keys
            .where((k) => k.startsWith('member'))
            .toList();
        memberKeys.sort();
        for (final memberKey in memberKeys) {
          if (longRange[memberKey]?.isNotEmpty == true) {
            return longRange[memberKey];
          }
        }
        return null;
      case 'medium_range_blend':
        return mediumRangeBlend;
      default:
        return null;
    }
  }

  // Get all ensemble members for medium/long range
  List<ForecastSeries> getEnsembleMembers(String forecastType) {
    final ensemble = forecastType.toLowerCase() == 'medium_range'
        ? mediumRange
        : longRange;

    return ensemble.entries
        .where((e) => e.key.startsWith('member'))
        .map((e) => e.value)
        .toList();
  }

  // Get all ensemble data including mean (for hydrographs)
  Map<String, ForecastSeries> getAllEnsembleData(String forecastType) {
    return forecastType.toLowerCase() == 'medium_range'
        ? Map.from(mediumRange)
        : Map.from(longRange);
  }

  // Get the latest flow value with automatic fallback
  double? getLatestFlow(String forecastType) {
    final forecast = getPrimaryForecast(forecastType);
    if (forecast == null || forecast.isEmpty) return null;

    // For short_range, use current hour logic instead of closest time
    if (forecastType.toLowerCase() == 'short_range') {
      return forecast.getCurrentHourFlow();
    }

    // For other forecast types, use existing closest time logic
    return forecast.getFlowAt(DateTime.now().toUtc());
  }

  // Get data source info for debugging
  String getDataSource(String forecastType) {
    switch (forecastType.toLowerCase()) {
      case 'medium_range':
        if (mediumRange['mean']?.isNotEmpty == true) return 'ensemble mean';
        final memberKeys = mediumRange.keys
            .where((k) => k.startsWith('member'))
            .toList();
        memberKeys.sort();
        for (final memberKey in memberKeys) {
          if (mediumRange[memberKey]?.isNotEmpty == true) return memberKey;
        }
        return 'no data';
      case 'long_range':
        if (longRange['mean']?.isNotEmpty == true) return 'ensemble mean';
        final memberKeys = longRange.keys
            .where((k) => k.startsWith('member'))
            .toList();
        memberKeys.sort();
        for (final memberKey in memberKeys) {
          if (longRange[memberKey]?.isNotEmpty == true) return memberKey;
        }
        return 'no data';
      default:
        final forecast = getPrimaryForecast(forecastType);
        return forecast?.isNotEmpty == true ? 'series data' : 'no data';
    }
  }

  @override
  String toString() {
    return 'ForecastResponse{reach: ${reach.displayName}, forecasts: ${_availableForecasts()}}';
  }

  List<String> _availableForecasts() {
    final available = <String>[];
    if (analysisAssimilation?.isNotEmpty == true) {
      available.add('analysis_assimilation');
    }
    if (shortRange?.isNotEmpty == true) available.add('short_range');
    if (mediumRange.isNotEmpty) available.add('medium_range');
    if (longRange.isNotEmpty) available.add('long_range');
    if (mediumRangeBlend?.isNotEmpty == true) {
      available.add('medium_range_blend');
    }
    return available;
  }
}
