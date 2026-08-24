// lib/services/4_infrastructure/forecast/forecast_values.dart

import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/forecast_chart_data.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';

/// Pure derivations over a [ForecastResponse] (ADR 0011 Phase 3).
///
/// These are the value helpers `ForecastService` used to own, extracted so the
/// UI can derive display values WITHOUT depending on `IForecastService` —
/// guard 1 of the phase: `lib/ui/` holds no reference to the fetch layer.
/// `ForecastService` delegates here, so there is exactly one implementation of
/// each rule (ADR 0002 / decision 13) and no service-side TTL caches: every
/// function is a pure computation an already-rendered frame can afford, and
/// the entries they derive from live in the ONE cache (`RiverDataCache`).
///
/// Flow values are already in the user's preferred unit — converted at the API
/// layer on fetch and re-converted at decode when the preference changes.
class ForecastValues {
  const ForecastValues._();

  /// Current flow for display: the latest value of the highest-priority series
  /// that has one (short → medium → long).
  static double? currentFlow(
    ForecastResponse forecast, {
    String? preferredType,
  }) {
    final types = preferredType != null
        ? [preferredType, 'short_range', 'medium_range', 'long_range']
        : ['short_range', 'medium_range', 'long_range'];

    for (final type in types) {
      final flow = forecast.getLatestFlow(type);
      if (flow != null && flow > -9000) return flow;
    }
    return null;
  }

  /// Flow category against the reach's return periods, via the one canonical
  /// classifier chain.
  static String flowCategory(
    ForecastResponse forecast,
    IFlowUnitPreferenceService unitService, {
    String? preferredType,
  }) {
    final flow = currentFlow(forecast, preferredType: preferredType);
    if (flow == null) return 'Unknown';
    return forecast.reach
        .getFlowCategory(flow, unitService.currentFlowUnit, unitService);
  }

  static List<String> availableForecastTypes(ForecastResponse forecast) {
    final available = <String>[];
    if (forecast.shortRange?.isNotEmpty == true) available.add('short_range');
    if (forecast.mediumRange.isNotEmpty) available.add('medium_range');
    if (forecast.longRange.isNotEmpty) available.add('long_range');
    if (forecast.analysisAssimilation?.isNotEmpty == true) {
      available.add('analysis_assimilation');
    }
    if (forecast.mediumRangeBlend?.isNotEmpty == true) {
      available.add('medium_range_blend');
    }
    return available;
  }

  static bool hasEnsembleData(ForecastResponse forecast) =>
      forecast.mediumRange.length > 1 || forecast.longRange.length > 1;

  static bool hasMultipleEnsembleMembers(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);
    return ensembleData.keys.where((k) => k.startsWith('member')).length > 1;
  }

  /// Hourly short-range points from the current hour forward, with trends.
  static List<HourlyFlowDataPoint> shortRangeHourlyData(
    ForecastResponse forecast,
  ) {
    final shortRange = forecast.shortRange;
    if (shortRange == null || shortRange.isEmpty) return [];

    final now = DateTime.now();
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);

    final futureData = shortRange.data.where((point) {
      final local = point.validTime.toLocal();
      final pointHour = DateTime(local.year, local.month, local.day, local.hour);
      return pointHour.isAtSameMomentAs(currentHour) ||
          pointHour.isAfter(currentHour);
    }).toList();

    return _withTrends(futureData, confidenceDecay: true);
  }

  /// Every short-range hour, past included — charts need the full window.
  static List<HourlyFlowDataPoint> allShortRangeHourlyData(
    ForecastResponse forecast,
  ) {
    final shortRange = forecast.shortRange;
    if (shortRange == null || shortRange.isEmpty) return [];
    return _withTrends(shortRange.data, confidenceDecay: false);
  }

  static List<HourlyFlowDataPoint> _withTrends(
    List<ForecastPoint> points, {
    required bool confidenceDecay,
  }) {
    final out = <HourlyFlowDataPoint>[];
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      FlowTrend? trend;
      double? trendPercentage;
      if (i > 0) {
        final previousFlow = points[i - 1].flow;
        final change = point.flow - previousFlow;
        // 5-unit threshold for trend detection (works for both CFS and CMS).
        if (change.abs() > 5) {
          trend = change > 0 ? FlowTrend.rising : FlowTrend.falling;
          trendPercentage = ((change / previousFlow) * 100).abs();
        } else {
          trend = FlowTrend.stable;
          trendPercentage = 0.0;
        }
      }
      out.add(HourlyFlowDataPoint(
        validTime: point.validTime.toLocal(),
        flow: point.flow,
        trend: trend,
        trendPercentage: trendPercentage,
        confidence: confidenceDecay ? 0.95 - (i * 0.02) : 0.95,
      ));
    }
    return out;
  }

  /// Ensemble members as chart series keyed by member name, x = hours from the
  /// earliest point.
  static Map<String, List<ChartData>> ensembleSeriesForChart(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);
    final chartSeries = <String, List<ChartData>>{};

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
      final series = entry.value;
      if (series.isEmpty) continue;
      chartSeries[entry.key] = series.data.map((point) {
        final hoursDiff =
            point.validTime.toLocal().difference(earliestTime!).inHours.toDouble();
        return ChartData(hoursDiff, point.flow);
      }).toList();
    }
    return chartSeries;
  }

  /// First available ensemble series as (time, flow) points — chart bounds.
  static List<ChartDataPoint> ensembleReferenceData(
    ForecastResponse forecast,
    String forecastType,
  ) {
    final ensembleData = forecast.getAllEnsembleData(forecastType);
    for (final entry in ensembleData.entries) {
      final series = entry.value;
      if (series.isNotEmpty) {
        return series.data
            .map((p) =>
                ChartDataPoint(time: p.validTime.toLocal(), flow: p.flow))
            .toList();
      }
    }
    return [];
  }
}
