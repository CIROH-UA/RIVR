// lib/features/forecast/widgets/daily_expandable_widget/hourly_display/micro_bar_chart.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/core/models/reach_data.dart';
import 'package:get_it/get_it.dart';
import '../../../../../core/services/i_flow_unit_preference_service.dart';

/// A compact bar chart that displays hourly flow data with selection highlighting
///
/// Shows each hour as a small bar with colors based on flow categories.
/// Supports touch interaction for hour selection with Cupertino styling.
class MicroBarChart extends StatelessWidget {
  /// Hourly data to display (sorted by time) - values in user's preferred unit
  final List<MapEntry<DateTime, double>> hourlyData;

  /// Index of currently selected hour
  final int selectedIndex;

  /// Minimum flow value for scaling
  final double minValue;

  /// Maximum flow value for scaling
  final double maxValue;

  /// Optional reach data for flow categorization
  final ReachData? reach;

  /// Callback when a bar is tapped
  final Function(int index)? onBarTapped;

  /// Height of the chart
  final double height;

  /// Whether to show grid lines
  final bool showGridLines;

  const MicroBarChart({
    super.key,
    required this.hourlyData,
    required this.selectedIndex,
    required this.minValue,
    required this.maxValue,
    this.reach,
    this.onBarTapped,
    this.height = 60.0,
    this.showGridLines = true,
  });

  @override
  Widget build(BuildContext context) {
    if (hourlyData.isEmpty) {
      return _buildEmptyState(context);
    }

    // For single data point, show special layout
    if (hourlyData.length == 1) {
      return _buildSingleBar(context);
    }

    return GestureDetector(
      onTapDown: (details) => _handleTap(details, context),
      child: CustomPaint(
        painter: _MicroBarChartPainter(
          hourlyData: hourlyData,
          selectedIndex: selectedIndex,
          minValue: minValue,
          maxValue: maxValue,
          reach: reach,
          theme: CupertinoTheme.of(context),
          showGridLines: showGridLines,
        ),
        size: Size.fromHeight(height),
      ),
    );
  }

  /// Handle tap on chart to select bar
  void _handleTap(TapDownDetails details, BuildContext context) {
    if (onBarTapped == null || hourlyData.isEmpty) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = details.localPosition;
    final chartWidth = renderBox.size.width;

    // Calculate which bar was tapped
    final barWidth = chartWidth / hourlyData.length;
    final tappedIndex = (localPosition.dx / barWidth).floor();

    if (tappedIndex >= 0 && tappedIndex < hourlyData.length) {
      onBarTapped!(tappedIndex);
    }
  }

  /// Build empty state
  Widget _buildEmptyState(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          'No hourly data',
          style: TextStyle(
            color: CupertinoColors.systemGrey2.resolveFrom(context),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// Build single bar state
  Widget _buildSingleBar(BuildContext context) {
    final flow = hourlyData.first.value;
    final color = _getColorForFlow(flow);

    return Container(
      height: height,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
      child: Center(
        child: Container(
          width: 20,
          height: height * 0.8,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color, width: 1),
          ),
        ),
      ),
    );
  }

  /// Get color for flow value based on category
  Color _getColorForFlow(double flow) {
    if (reach?.hasReturnPeriods == true) {
      // Flow data is already in user's preferred unit
      final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
      final category = reach!.getFlowCategory(flow, currentUnit);
      return _getColorForCategory(category);
    } else {
      // Fallback to gradient based on relative value
      return _getGradientColor(flow);
    }
  }

  /// Get color for flow category
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

  /// Get gradient color based on relative flow value
  Color _getGradientColor(double flow) {
    if (maxValue <= minValue) return CupertinoColors.systemBlue;

    final normalizedValue = ((flow - minValue) / (maxValue - minValue)).clamp(
      0.0,
      1.0,
    );

    if (normalizedValue < 0.25) {
      return CupertinoColors.systemBlue;
    } else if (normalizedValue < 0.5) {
      return CupertinoColors.systemGreen;
    } else if (normalizedValue < 0.75) {
      return CupertinoColors.systemOrange;
    } else {
      return CupertinoColors.systemRed;
    }
  }
}

/// Custom painter for the micro bar chart
class _MicroBarChartPainter extends CustomPainter {
  final List<MapEntry<DateTime, double>> hourlyData;
  final int selectedIndex;
  final double minValue;
  final double maxValue;
  final ReachData? reach;
  final CupertinoThemeData theme;
  final bool showGridLines;

  _MicroBarChartPainter({
    required this.hourlyData,
    required this.selectedIndex,
    required this.minValue,
    required this.maxValue,
    this.reach,
    required this.theme,
    required this.showGridLines,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (hourlyData.isEmpty) return;

    final barWidth = size.width / hourlyData.length;
    final maxBarHeight = size.height - 4; // Leave space for padding

    // Draw grid lines
    if (showGridLines) {
      _drawGridLines(canvas, size, maxBarHeight);
    }

    // Draw bars
    for (int i = 0; i < hourlyData.length; i++) {
      final flow = hourlyData[i].value;
      final isSelected = i == selectedIndex;

      // Calculate normalized height
      final normValue = maxValue > minValue
          ? ((flow - minValue) / (maxValue - minValue)).clamp(0.0, 1.0)
          : 0.5;
      final barHeight = (normValue * maxBarHeight).clamp(2.0, maxBarHeight);

      // Calculate position
      final left = i * barWidth + (barWidth * 0.15); // 15% padding on each side
      final width = barWidth * 0.7; // Bar takes 70% of available width
      final top = size.height - barHeight;
      final bottom = size.height;

      // Create bar rectangle
      final rect = Rect.fromLTRB(left, top, left + width, bottom);

      // Get bar color
      final Color barColor = _getColorForFlow(flow);

      // Create paint
      final paint = Paint()
        ..color = isSelected
            ? barColor.withValues(alpha: 1.0)
            : barColor.withValues(alpha: 0.7)
        ..style = PaintingStyle.fill;

      // Draw bar with rounded corners
      final borderRadius = Radius.circular(2.0);
      final rrect = RRect.fromRectAndRadius(rect, borderRadius);
      canvas.drawRRect(rrect, paint);

      // Draw selection highlight
      if (isSelected) {
        final highlightPaint = Paint()
          ..color = theme.brightness == Brightness.dark
              ? CupertinoColors.white.withValues(alpha: 0.3)
              : CupertinoColors.black.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;

        final highlightRect = Rect.fromLTRB(
          left - 1,
          top - 1,
          left + width + 1,
          bottom,
        );
        final highlightRRect = RRect.fromRectAndRadius(
          highlightRect,
          const Radius.circular(3.0),
        );
        canvas.drawRRect(highlightRRect, highlightPaint);
      }
    }
  }

  /// Draw subtle grid lines for reference
  void _drawGridLines(Canvas canvas, Size size, double maxBarHeight) {
    final gridPaint = Paint()
      ..color =
          (theme.brightness == Brightness.dark
                  ? CupertinoColors.systemGrey4
                  : CupertinoColors.systemGrey5)
              .withValues(alpha: 0.5)
      ..strokeWidth = 0.5;

    // Draw horizontal lines at 25%, 50%, 75% heights
    final linePositions = [0.25, 0.5, 0.75];

    for (final position in linePositions) {
      final y = size.height - (maxBarHeight * position);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  /// Get color for flow value
  Color _getColorForFlow(double flow) {
    if (reach?.hasReturnPeriods == true) {
      // Flow data is already in user's preferred unit
      final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
      final category = reach!.getFlowCategory(flow, currentUnit);
      return _getColorForCategory(category);
    } else {
      return _getGradientColor(flow);
    }
  }

  /// Get color for category
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

  /// Get gradient color based on value
  Color _getGradientColor(double flow) {
    if (maxValue <= minValue) return CupertinoColors.systemBlue;

    final normalizedValue = ((flow - minValue) / (maxValue - minValue)).clamp(
      0.0,
      1.0,
    );

    if (normalizedValue < 0.25) {
      return CupertinoColors.systemBlue;
    } else if (normalizedValue < 0.5) {
      return CupertinoColors.systemGreen;
    } else if (normalizedValue < 0.75) {
      return CupertinoColors.systemOrange;
    } else {
      return CupertinoColors.systemRed;
    }
  }

  @override
  bool shouldRepaint(_MicroBarChartPainter oldDelegate) {
    return oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.hourlyData != hourlyData ||
        oldDelegate.minValue != minValue ||
        oldDelegate.maxValue != maxValue;
  }
}

/// Interactive version that handles its own selection state
class InteractiveMicroBarChart extends StatefulWidget {
  final List<MapEntry<DateTime, double>> hourlyData;
  final double minValue;
  final double maxValue;
  final ReachData? reach;
  final Function(int index, DateTime time, double flow)? onSelectionChanged;
  final int? initialSelectedIndex;

  const InteractiveMicroBarChart({
    super.key,
    required this.hourlyData,
    required this.minValue,
    required this.maxValue,
    this.reach,
    this.onSelectionChanged,
    this.initialSelectedIndex,
  });

  @override
  State<InteractiveMicroBarChart> createState() =>
      _InteractiveMicroBarChartState();
}

class _InteractiveMicroBarChartState extends State<InteractiveMicroBarChart> {
  late int selectedIndex;

  @override
  void initState() {
    super.initState();
    selectedIndex = widget.initialSelectedIndex ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return MicroBarChart(
      hourlyData: widget.hourlyData,
      selectedIndex: selectedIndex,
      minValue: widget.minValue,
      maxValue: widget.maxValue,
      reach: widget.reach,
      onBarTapped: (index) {
        setState(() {
          selectedIndex = index;
        });

        if (widget.onSelectionChanged != null &&
            index >= 0 &&
            index < widget.hourlyData.length) {
          final entry = widget.hourlyData[index];
          widget.onSelectionChanged!(index, entry.key, entry.value);
        }
      },
    );
  }
}
