// lib/models/1_domain/features/forecast/daily_flow_forecast.dart

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';

/// Represents a single day's flow forecast data processed from ensemble forecasts
///
/// This model aggregates hourly ensemble data (primarily from 'mean', with fallback
/// to first available member) into daily summaries suitable for display in
/// expandable daily forecast widgets.
class DailyFlowForecast {
  /// The date this forecast represents (local date, time component ignored)
  final DateTime date;

  /// ✅ UPDATED: Minimum flow value for this day (in user's preferred unit: CFS or CMS)
  final double minFlow;

  /// ✅ UPDATED: Maximum flow value for this day (in user's preferred unit: CFS or CMS)
  final double maxFlow;

  /// ✅ UPDATED: Average flow value for this day (in user's preferred unit: CFS or CMS)
  final double avgFlow;

  /// ✅ UPDATED: Hourly flow data for this day (values in user's preferred unit: CFS or CMS)
  /// Key: DateTime (hour-level precision)
  /// Value: Flow in user's preferred unit
  final Map<DateTime, double> hourlyData;

  /// Flow category based on return period thresholds
  /// Values: 'Normal', 'Elevated', 'High', 'Flood Risk', 'Unknown'
  final String flowCategory;

  /// Data source identifier for debugging/display purposes
  /// Examples: 'mean', 'member01', 'member02', etc.
  final String dataSource;

  /// Optional: Confidence/uncertainty indicators could be added later
  /// final double? confidenceLevel;
  /// final double? uncertainty;

  const DailyFlowForecast({
    required this.date,
    required this.minFlow,
    required this.maxFlow,
    required this.avgFlow,
    required this.hourlyData,
    required this.flowCategory,
    required this.dataSource,
  });

  /// Creates a copy with updated values
  DailyFlowForecast copyWith({
    DateTime? date,
    double? minFlow,
    double? maxFlow,
    double? avgFlow,
    Map<DateTime, double>? hourlyData,
    String? flowCategory,
    String? dataSource,
  }) {
    return DailyFlowForecast(
      date: date ?? this.date,
      minFlow: minFlow ?? this.minFlow,
      maxFlow: maxFlow ?? this.maxFlow,
      avgFlow: avgFlow ?? this.avgFlow,
      hourlyData: hourlyData ?? this.hourlyData,
      flowCategory: flowCategory ?? this.flowCategory,
      dataSource: dataSource ?? this.dataSource,
    );
  }

  /// ✅ NEW: Get the current flow unit for display purposes
  String get currentUnit {
    final unitService = GetIt.I<IFlowUnitPreferenceService>();
    return unitService.currentFlowUnit;
  }

  /// ✅ NEW: Format flow value with current unit for display
  String formatFlowWithUnit(double flowValue) {
    final formattedValue = _formatFlow(flowValue);
    return '$formattedValue $currentUnit';
  }

  /// ✅ NEW: Get formatted min flow with unit
  String get formattedMinFlow => formatFlowWithUnit(minFlow);

  /// ✅ NEW: Get formatted max flow with unit
  String get formattedMaxFlow => formatFlowWithUnit(maxFlow);

  /// ✅ NEW: Get formatted average flow with unit
  String get formattedAvgFlow => formatFlowWithUnit(avgFlow);

  /// ✅ NEW: Private helper to format flow values consistently
  String _formatFlow(double flow) {
    if (flow >= 1000000) {
      return '${(flow / 1000000).toStringAsFixed(1)}M';
    } else if (flow >= 1000) {
      return '${(flow / 1000).toStringAsFixed(1)}K';
    } else if (flow >= 100) {
      return flow.toStringAsFixed(0);
    } else {
      return flow.toStringAsFixed(1);
    }
  }

  /// Get the color associated with this day's flow category
  /// Uses RIVR's standard Cupertino color scheme
  Color get categoryColor {
    switch (flowCategory.toLowerCase()) {
      case 'normal':
        return CupertinoColors.systemBlue;
      case 'elevated':
        return CupertinoColors.systemGreen;
      case 'high':
        return CupertinoColors.systemOrange;
      case 'flood risk':
        return CupertinoColors.systemRed;
      default:
        return CupertinoColors.systemGrey;
    }
  }

  /// Get appropriate icon for this day's flow category
  /// Uses RIVR's standard Cupertino icons
  IconData get categoryIcon {
    switch (flowCategory.toLowerCase()) {
      case 'normal':
        return CupertinoIcons.checkmark_circle_fill;
      case 'elevated':
        return CupertinoIcons.arrow_up_circle;
      case 'high':
        return CupertinoIcons.arrow_up_circle_fill;
      case 'flood risk':
        return CupertinoIcons.exclamationmark_triangle_fill;
      default:
        return CupertinoIcons.question_circle;
    }
  }

  /// Check if this forecast has hourly data available
  bool get hasHourlyData => hourlyData.isNotEmpty;

  /// Get the number of hours of data available
  int get hourlyDataCount => hourlyData.length;

  /// Get flow at a specific hour (or closest available)
  double? getFlowAt(DateTime targetTime) {
    if (hourlyData.isEmpty) return null;

    // Try exact match first
    final exactMatch = hourlyData[targetTime];
    if (exactMatch != null) return exactMatch;

    // Find closest hour
    DateTime? closestTime;
    Duration? minDifference;

    for (final dataTime in hourlyData.keys) {
      final difference = dataTime.difference(targetTime).abs();
      if (minDifference == null || difference < minDifference) {
        minDifference = difference;
        closestTime = dataTime;
      }
    }

    return closestTime != null ? hourlyData[closestTime] : null;
  }

  /// ✅ NEW: Get formatted flow at a specific hour with unit
  String? getFormattedFlowAt(DateTime targetTime) {
    final flow = getFlowAt(targetTime);
    return flow != null ? formatFlowWithUnit(flow) : null;
  }

  /// Get sorted list of hourly data entries for easy iteration
  List<MapEntry<DateTime, double>> get sortedHourlyData {
    final entries = hourlyData.entries.toList();
    entries.sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  /// Check if this is using ensemble mean data (preferred) or fallback member
  bool get isUsingMeanData => dataSource == 'mean';

  /// Get a user-friendly description of the data source
  String get dataSourceDescription {
    if (dataSource == 'mean') {
      return 'Ensemble Average';
    } else if (dataSource.startsWith('member')) {
      final memberNumber = dataSource.substring(6); // Remove 'member' prefix
      return 'Member $memberNumber';
    } else {
      return 'Unknown Source';
    }
  }

  /// Validation method to ensure data integrity
  bool get isValid {
    return minFlow >= 0 &&
        maxFlow >= minFlow &&
        avgFlow >= minFlow &&
        avgFlow <= maxFlow &&
        flowCategory.isNotEmpty &&
        dataSource.isNotEmpty;
  }

  /// ✅ UPDATED: String representation with current unit information
  @override
  String toString() {
    return 'DailyFlowForecast{date: ${date.toIso8601String().split('T')[0]}, '
        'flows: ${_formatFlow(minFlow)}-${_formatFlow(maxFlow)} (avg: ${_formatFlow(avgFlow)}) $currentUnit, '
        'category: $flowCategory, '
        'source: $dataSource, '
        'hourlyPoints: ${hourlyData.length}}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DailyFlowForecast &&
        other.date == date &&
        other.minFlow == minFlow &&
        other.maxFlow == maxFlow &&
        other.avgFlow == avgFlow &&
        other.flowCategory == flowCategory &&
        other.dataSource == dataSource;
  }

  @override
  int get hashCode {
    return Object.hash(
      date,
      minFlow,
      maxFlow,
      avgFlow,
      flowCategory,
      dataSource,
    );
  }
}

/// Collection of daily flow forecasts for a complete forecast period
///
/// Provides convenient methods for working with multiple days of forecast data
class DailyForecastCollection {
  final List<DailyFlowForecast> forecasts;
  final DateTime createdAt;
  final String sourceType; // 'medium_range', 'long_range', etc.

  const DailyForecastCollection({
    required this.forecasts,
    required this.createdAt,
    required this.sourceType,
  });

  /// ✅ NEW: Get the current flow unit for the collection
  String get currentUnit {
    final unitService = GetIt.I<IFlowUnitPreferenceService>();
    return unitService.currentFlowUnit;
  }

  /// Get forecast for a specific date
  DailyFlowForecast? getForecastForDate(DateTime date) {
    final targetDate = DateTime(date.year, date.month, date.day);
    return forecasts.where((f) {
      final forecastDate = DateTime(f.date.year, f.date.month, f.date.day);
      return forecastDate == targetDate;
    }).firstOrNull;
  }

  /// Get all forecasts sorted by date
  List<DailyFlowForecast> get sortedForecasts {
    final sorted = List<DailyFlowForecast>.from(forecasts);
    sorted.sort((a, b) => a.date.compareTo(b.date));
    return sorted;
  }

  /// ✅ UPDATED: Get overall flow bounds for the entire collection (values in current unit)
  Map<String, double> get flowBounds {
    if (forecasts.isEmpty) return {'min': 0.0, 'max': 100.0};

    double min = forecasts.first.minFlow;
    double max = forecasts.first.maxFlow;

    for (final forecast in forecasts) {
      if (forecast.minFlow < min) min = forecast.minFlow;
      if (forecast.maxFlow > max) max = forecast.maxFlow;
    }

    return {'min': min, 'max': max};
  }

  /// ✅ NEW: Get formatted flow bounds with unit information
  String get formattedFlowBounds {
    final bounds = flowBounds;
    final minFormatted = _formatFlow(bounds['min']!);
    final maxFormatted = _formatFlow(bounds['max']!);
    return '$minFormatted - $maxFormatted $currentUnit';
  }

  /// ✅ NEW: Private helper to format flow values consistently
  String _formatFlow(double flow) {
    if (flow >= 1000000) {
      return '${(flow / 1000000).toStringAsFixed(1)}M';
    } else if (flow >= 1000) {
      return '${(flow / 1000).toStringAsFixed(1)}K';
    } else if (flow >= 100) {
      return flow.toStringAsFixed(0);
    } else {
      return flow.toStringAsFixed(1);
    }
  }

  /// Check if collection is empty
  bool get isEmpty => forecasts.isEmpty;

  /// Check if collection has data
  bool get isNotEmpty => forecasts.isNotEmpty;

  /// Get the number of days in the forecast
  int get length => forecasts.length;

  /// Get date range covered by this collection
  Map<String, DateTime>? get dateRange {
    if (forecasts.isEmpty) return null;

    final sorted = sortedForecasts;
    return {'start': sorted.first.date, 'end': sorted.last.date};
  }

  /// ✅ UPDATED: String representation with unit information
  @override
  String toString() {
    return 'DailyForecastCollection{type: $sourceType, days: ${forecasts.length}, '
        'unit: $currentUnit, created: ${createdAt.toIso8601String()}}';
  }
}
