// lib/core/models/forecast_chart_data.dart

/// Ensemble statistics at a single time point (min/max/mean across members)
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

/// Time-based chart data point with optional metadata
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

/// Simple x,y coordinate data for chart rendering
class ChartData {
  final double x;
  final double y;

  ChartData(this.x, this.y);
}
