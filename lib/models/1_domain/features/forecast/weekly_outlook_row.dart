// lib/models/1_domain/features/forecast/weekly_outlook_row.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/utils/forecast_trend.dart';

/// One favorite river's week-ahead summary, as shown on the Weekly Outlook page.
///
/// Pure data: computed by the weekly-outlook service from a reach's forecast
/// series + return periods, then rendered as a Digest-List row.
class OutlookRow {
  final String reachId;
  final ForecastSource source;
  final String displayName;

  /// Display unit label for [peakFlow] (e.g. 'ft³/s', 'm³/s').
  final String unit;

  /// Upcoming median flows, earliest-first — drives the sparkline.
  final List<double> sparkline;

  final FlowTrend trend;

  /// Highest flow still ahead this week and when it crests (local time).
  final double? peakFlow;
  final DateTime? peakTime;

  /// Flood category the peak falls in (e.g. 'Normal', 'Elevated'), plus its
  /// severity index (0 = lowest; -1 when it can't be classified).
  final String category;
  final int categoryIndex;

  const OutlookRow({
    required this.reachId,
    required this.source,
    required this.displayName,
    required this.unit,
    required this.sparkline,
    required this.trend,
    required this.peakFlow,
    required this.peakTime,
    required this.category,
    required this.categoryIndex,
  });

  /// How much this river "deserves" the top of the digest. Elevated/flood
  /// categories dominate; among equals, a rising river beats a steady or
  /// receding one. Higher = shown first.
  int get newsworthiness {
    final catScore = categoryIndex.clamp(0, 99) * 100;
    final trendScore = trend.isRising ? 30 : (trend.isSteady ? 10 : 5);
    return catScore + trendScore;
  }

  /// Sort comparator: most newsworthy first, breaking ties by higher peak.
  static int byNewsworthiness(OutlookRow a, OutlookRow b) {
    final byScore = b.newsworthiness.compareTo(a.newsworthiness);
    if (byScore != 0) return byScore;
    return (b.peakFlow ?? 0).compareTo(a.peakFlow ?? 0);
  }
}
