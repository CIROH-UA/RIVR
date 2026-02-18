// lib/features/forecast/widgets/daily_expandable_widget/flow_range_bar.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/core/models/reach_data.dart';
import 'package:get_it/get_it.dart';
import '../../../../../core/services/i_flow_unit_preference_service.dart';
import '../../domain/entities/daily_flow_forecast.dart';

/// A horizontal bar that visually represents the flow range for a day
///
/// Shows min-max flow range with category-based gradient colors.
/// Uses Cupertino design patterns with smooth animations and clean styling.
class FlowRangeBar extends StatelessWidget {
  /// The daily forecast data to visualize
  final DailyFlowForecast forecast;

  /// Minimum flow bound for scaling (from entire forecast collection)
  final double minFlowBound;

  /// Maximum flow bound for scaling (from entire forecast collection)
  final double maxFlowBound;

  /// Height of the bar in logical pixels
  final double height;

  /// Optional reach data for enhanced flow categorization
  final ReachData? reach;

  /// Corner radius for the bar
  final double borderRadius;

  const FlowRangeBar({
    super.key,
    required this.forecast,
    required this.minFlowBound,
    required this.maxFlowBound,
    this.height = 8.0,
    this.reach,
    this.borderRadius = 4.0,
  });

  @override
  Widget build(BuildContext context) {
    // Handle edge cases
    final range = maxFlowBound - minFlowBound;
    if (range <= 0 || forecast.minFlow == forecast.maxFlow) {
      return _buildEmptyBar(context);
    }

    // Calculate normalized positions (0-1) for min and max flow
    final normalizedMin = ((forecast.minFlow - minFlowBound) / range).clamp(
      0.0,
      1.0,
    );
    final normalizedMax = ((forecast.maxFlow - minFlowBound) / range).clamp(
      0.0,
      1.0,
    );

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final minPos = normalizedMin * totalWidth;
          final maxPos = normalizedMax * totalWidth;
          final rangeWidth = maxPos - minPos;

          return Stack(
            children: [
              // Background track
              Container(
                width: totalWidth,
                height: height,
                color: CupertinoColors.systemGrey5.resolveFrom(context),
              ),

              // Range bar with gradient
              if (rangeWidth > 0)
                Positioned(
                  left: minPos,
                  width: rangeWidth,
                  child: _buildRangeBar(),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Build the colored range bar with gradient based on flow categories
  Widget _buildRangeBar() {
    final minColor = _getColorForFlow(forecast.minFlow);
    final maxColor = _getColorForFlow(forecast.maxFlow);

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          colors: [minColor, maxColor],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        // Add subtle shadow for depth
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.1),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );
  }

  /// Build empty bar for edge cases
  Widget _buildEmptyBar(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: CupertinoColors.systemGrey4.resolveFrom(context),
      ),
    );
  }

  /// Get color for a specific flow value based on category
  Color _getColorForFlow(double flow) {
    if (reach?.hasReturnPeriods == true) {
      // Use reach-specific flow categorization if available
      final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
      final category = reach!.getFlowCategory(flow, currentUnit);
      return _getColorForCategory(category);
    } else {
      // Fallback to forecast's overall category
      return _getColorForCategory(forecast.flowCategory);
    }
  }

  /// Get Cupertino color for flow category
  Color _getColorForCategory(String category) {
    switch (category.toLowerCase()) {
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
}

/// Enhanced flow range bar with additional visual indicators
///
/// Includes current flow marker and enhanced styling for detailed views
class DetailedFlowRangeBar extends StatelessWidget {
  final DailyFlowForecast forecast;
  final double minFlowBound;
  final double maxFlowBound;
  final double height;
  final ReachData? reach;

  /// Optional current flow value to display as a marker
  final double? currentFlow;

  /// Show average flow as a marker
  final bool showAverage;

  const DetailedFlowRangeBar({
    super.key,
    required this.forecast,
    required this.minFlowBound,
    required this.maxFlowBound,
    this.height = 12.0,
    this.reach,
    this.currentFlow,
    this.showAverage = true,
  });

  @override
  Widget build(BuildContext context) {
    final range = maxFlowBound - minFlowBound;
    if (range <= 0) return const SizedBox.shrink();

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;

          return Stack(
            children: [
              // Base flow range bar
              FlowRangeBar(
                forecast: forecast,
                minFlowBound: minFlowBound,
                maxFlowBound: maxFlowBound,
                height: height,
                reach: reach,
                borderRadius: height / 2,
              ),

              // Average flow marker
              if (showAverage)
                _buildFlowMarker(
                  flow: forecast.avgFlow,
                  totalWidth: totalWidth,
                  range: range,
                  color: CupertinoColors.white,
                  size: 2.0,
                ),

              // Current flow marker (if provided)
              if (currentFlow != null)
                _buildFlowMarker(
                  flow: currentFlow!,
                  totalWidth: totalWidth,
                  range: range,
                  color: CupertinoColors.black,
                  size: 3.0,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFlowMarker({
    required double flow,
    required double totalWidth,
    required double range,
    required Color color,
    required double size,
  }) {
    final normalizedPos = ((flow - minFlowBound) / range).clamp(0.0, 1.0);
    final xPos = (normalizedPos * totalWidth).clamp(
      size / 2,
      totalWidth - size / 2,
    );

    return Positioned(
      left: xPos - size / 2,
      top: 0,
      child: Container(
        width: size,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(size / 2),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.black.withValues(alpha: 0.3),
              blurRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact version for use in lists or tight spaces
class CompactFlowRangeBar extends StatelessWidget {
  final DailyFlowForecast forecast;
  final double minFlowBound;
  final double maxFlowBound;

  const CompactFlowRangeBar({
    super.key,
    required this.forecast,
    required this.minFlowBound,
    required this.maxFlowBound,
  });

  @override
  Widget build(BuildContext context) {
    return FlowRangeBar(
      forecast: forecast,
      minFlowBound: minFlowBound,
      maxFlowBound: maxFlowBound,
      height: 6.0,
      borderRadius: 3.0,
    );
  }
}
