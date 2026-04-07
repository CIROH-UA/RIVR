// lib/models/1_domain/shared/reach_data.dart

import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';

class ReachData {
  // NOAA reach info
  final String reachId;
  final String riverName;
  final double latitude;
  final double longitude;

  // Location context (from geocoding)
  final String? city;
  final String? state;

  // Available forecast types (from reaches API 'streamflow' array)
  final List<String> availableForecasts;

  // Return periods (from separate return-period API - always in CMS)
  final Map<int, double>? returnPeriods;
  final String returnPeriodUnit = 'cms';

  // Routing info (from reaches API)
  final List<String>? upstreamReaches;
  final List<String>? downstreamReaches;

  // User customization
  final String? customName;

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
      isPartiallyLoaded: false,
    );
  }

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

  String get formattedLocation =>
      city != null && state != null ? '$city, $state' : '';

  String get formattedLocationSubtitle {
    if (city != null && state != null) {
      return '$city, $state';
    }
    return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
  }

  bool get hasReturnPeriods =>
      returnPeriods != null && returnPeriods!.isNotEmpty;

  bool get hasLocationData =>
      latitude != 0.0 && longitude != 0.0 && riverName != 'Unknown';

  bool isCacheStale({Duration maxAge = const Duration(days: 180)}) {
    return DateTime.now().difference(cachedAt) > maxAge;
  }

  /// Get return periods converted to specified unit.
  Map<int, double>? getReturnPeriodsInUnit(
    String targetUnit,
    IFlowUnitPreferenceService converter,
  ) {
    if (returnPeriods == null) return null;

    return returnPeriods!.map(
      (year, cmsValue) =>
          MapEntry(year, converter.convertFlow(cmsValue, 'CMS', targetUnit)),
    );
  }

  /// Get flood risk category based on NOAA return periods.
  String getFlowCategory(
    double flowValue,
    String flowUnit,
    IFlowUnitPreferenceService converter,
  ) {
    if (!hasReturnPeriods) return 'Unknown';

    final periods = getReturnPeriodsInUnit(flowUnit, converter);
    if (periods == null) return 'Unknown';

    final threshold2yr = periods[2];
    final threshold5yr = periods[5];
    final threshold10yr = periods[10];
    final threshold25yr = periods[25];

    if (threshold2yr != null && flowValue < threshold2yr) return 'Normal';
    if (threshold5yr != null && flowValue < threshold5yr) return 'Action';
    if (threshold10yr != null && flowValue < threshold10yr) return 'Moderate';
    if (threshold25yr != null && flowValue < threshold25yr) return 'Major';
    return 'Extreme';
  }

  /// Get next return period threshold above the given flow value.
  MapEntry<int, double>? getNextThreshold(
    double flowValue,
    String flowUnit,
    IFlowUnitPreferenceService converter,
  ) {
    if (!hasReturnPeriods) return null;

    // Convert flow to CMS for comparison with return periods (always in CMS)
    final flowCms = converter.convertFlow(flowValue, flowUnit, 'CMS');
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

  @override
  String toString() => 'ForecastPoint{validTime: $validTime, flow: $flow}';
}

class ForecastSeries {
  final DateTime? referenceTime;
  final String units;
  final List<ForecastPoint> data;

  ForecastSeries({
    this.referenceTime,
    required this.units,
    required this.data,
  });

  /// Convert this series to a different unit.
  ///
  /// Returns a new [ForecastSeries] with all data points converted.
  /// If units already match, returns a copy without re-converting.
  ForecastSeries convertToUnit(
    String targetUnit,
    IFlowUnitPreferenceService converter,
  ) {
    final normalizedCurrent = converter.normalizeUnit(units);
    final normalizedTarget = converter.normalizeUnit(targetUnit);

    if (normalizedCurrent == normalizedTarget) {
      return ForecastSeries(
        referenceTime: referenceTime,
        units: targetUnit,
        data: data,
      );
    }

    final convertedData = data
        .map(
          (point) => ForecastPoint(
            validTime: point.validTime,
            flow: converter.convertFlow(point.flow, units, targetUnit),
          ),
        )
        .toList();

    return ForecastSeries(
      referenceTime: referenceTime,
      units: targetUnit,
      data: convertedData,
    );
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

  // Get flow for current hour bucket
  double? getCurrentHourFlow() {
    if (data.isEmpty) return null;

    final now = DateTime.now();
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);

    // Try to find exact current hour match
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

    // Fallback to closest time
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
  final Map<String, ForecastSeries> mediumRange;
  final Map<String, ForecastSeries> longRange;
  final ForecastSeries? mediumRangeBlend;

  ForecastResponse({
    required this.reach,
    this.analysisAssimilation,
    this.shortRange,
    required this.mediumRange,
    required this.longRange,
    this.mediumRangeBlend,
  });

  // Primary forecast getter with automatic fallback
  ForecastSeries? getPrimaryForecast(String forecastType) {
    switch (forecastType.toLowerCase()) {
      case 'analysis_assimilation':
        return analysisAssimilation;
      case 'short_range':
        return shortRange;
      case 'medium_range':
        if (mediumRange['mean']?.isNotEmpty == true) {
          return mediumRange['mean'];
        }
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
        if (longRange['mean']?.isNotEmpty == true) {
          return longRange['mean'];
        }
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

  List<ForecastSeries> getEnsembleMembers(String forecastType) {
    final ensemble = forecastType.toLowerCase() == 'medium_range'
        ? mediumRange
        : longRange;

    return ensemble.entries
        .where((e) => e.key.startsWith('member'))
        .map((e) => e.value)
        .toList();
  }

  Map<String, ForecastSeries> getAllEnsembleData(String forecastType) {
    return forecastType.toLowerCase() == 'medium_range'
        ? Map.from(mediumRange)
        : Map.from(longRange);
  }

  double? getLatestFlow(String forecastType) {
    final forecast = getPrimaryForecast(forecastType);
    if (forecast == null || forecast.isEmpty) return null;

    if (forecastType.toLowerCase() == 'short_range') {
      return forecast.getCurrentHourFlow();
    }

    return forecast.getFlowAt(DateTime.now().toUtc());
  }

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
