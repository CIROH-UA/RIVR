// lib/models/1_domain/shared/hourly_flow_data.dart
//
// Data models for hourly flow data points.
// Extracted from horizontal_flow_timeline.dart to break circular
// dependency between core layer and feature widgets.

enum FlowTrend { rising, falling, stable }

class HourlyFlowDataPoint {
  final DateTime validTime;
  final double
      flow; // Already converted to user's preferred unit by NoaaApiService
  final FlowTrend? trend;
  final double? trendPercentage; // Percentage change from previous hour
  final double? confidence;
  final Map<String, dynamic>? metadata;

  const HourlyFlowDataPoint({
    required this.validTime,
    required this.flow,
    this.trend,
    this.trendPercentage,
    this.confidence,
    this.metadata,
  });

  @override
  String toString() {
    return 'HourlyFlowDataPoint(time: $validTime, flow: ${flow.toStringAsFixed(1)}, trend: $trend, change: ${trendPercentage?.toStringAsFixed(1)}%)';
  }
}
