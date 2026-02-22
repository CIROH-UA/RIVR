// lib/features/forecast/widgets/daily_expandable_widget/hourly_display/flow_value_indicator.dart

import 'package:flutter/cupertino.dart';

/// A circular indicator that displays the flow value for a selected hour
///
/// Shows flow value, time, and visual styling based on flow category.
/// Uses Cupertino design patterns with clean, accessible layout.
class FlowValueIndicator extends StatelessWidget {
  /// The flow value to display
  final double? flowValue;

  /// The time this flow value represents
  final DateTime? time;

  /// Flow category for color styling
  final String? flowCategory;

  /// Size of the circular container
  final double size;

  /// Optional color override
  final Color? borderColor;

  /// Flow units (CFS, CMS, etc.)
  final String units;

  const FlowValueIndicator({
    super.key,
    this.flowValue,
    this.time,
    this.flowCategory,
    this.size = 80.0,
    this.borderColor,
    this.units = 'ft³/s',
  });

  @override
  Widget build(BuildContext context) {
    // If no flow value, show placeholder
    if (flowValue == null || time == null) {
      return _buildEmptyIndicator(context);
    }

    // Get styling based on flow category
    final Color indicatorBorderColor =
        borderColor ?? _getColorForCategory(flowCategory);
    final String formattedFlow = _formatFlow(flowValue!);
    final String timeStr = _formatTime(time!);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        border: Border.all(color: indicatorBorderColor, width: 3.0),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Flow value
            Text(
              formattedFlow,
              style: CupertinoTheme.of(context).textTheme.navTitleTextStyle
                  .copyWith(
                    fontSize: _getFlowTextSize(),
                    fontWeight: FontWeight.bold,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),

            // Unit label - NOW DYNAMIC
            Text(
              units,
              style: TextStyle(
                fontSize: _getUnitTextSize(),
                fontWeight: FontWeight.w500,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),

            const SizedBox(height: 2),

            // Time
            Text(
              timeStr,
              style: TextStyle(
                fontSize: _getTimeTextSize(),
                fontWeight: FontWeight.w500,
                color: CupertinoColors.label.resolveFrom(context),
              ),
              textAlign: TextAlign.center,
            ),

            // Flow category (if available and space permits)
            if (flowCategory != null && size >= 90)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  flowCategory!,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: indicatorBorderColor,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Build empty placeholder indicator
  Widget _buildEmptyIndicator(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        border: Border.all(
          color: CupertinoColors.systemGrey4.resolveFrom(context),
          width: 2.0,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.clock,
              color: CupertinoColors.systemGrey2.resolveFrom(context),
              size: size * 0.3,
            ),
            const SizedBox(height: 4),
            Text(
              'No Data',
              style: TextStyle(
                fontSize: size * 0.12,
                color: CupertinoColors.systemGrey2.resolveFrom(context),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Format flow value for display
  String _formatFlow(double flow) {
    if (flow >= 1000000) {
      return '${(flow / 1000000).toStringAsFixed(1)}M';
    } else if (flow >= 1000) {
      return '${(flow / 1000).toStringAsFixed(1)}K';
    } else if (flow >= 100) {
      return flow.toStringAsFixed(0);
    } else if (flow >= 10) {
      return flow.toStringAsFixed(1);
    } else {
      return flow.toStringAsFixed(2);
    }
  }

  /// Format time for display
  String _formatTime(DateTime time) {
    final hour = time.hour;
    final minute = time.minute;

    // Use 12-hour format with AM/PM
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final period = hour < 12 ? 'AM' : 'PM';

    if (minute == 0) {
      return '$displayHour $period';
    } else {
      return '$displayHour:${minute.toString().padLeft(2, '0')} $period';
    }
  }

  /// Get color for flow category
  Color _getColorForCategory(String? category) {
    if (category == null) return CupertinoColors.systemGrey;

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

  /// Get responsive text size for flow value
  double _getFlowTextSize() {
    if (size >= 100) return 18;
    if (size >= 80) return 16;
    if (size >= 60) return 14;
    return 12;
  }

  /// Get responsive text size for unit label
  double _getUnitTextSize() {
    if (size >= 100) return 12;
    if (size >= 80) return 10;
    return 8;
  }

  /// Get responsive text size for time
  double _getTimeTextSize() {
    if (size >= 100) return 12;
    if (size >= 80) return 10;
    return 8;
  }
}

/// Compact version for smaller displays
class CompactFlowValueIndicator extends StatelessWidget {
  final double? flowValue;
  final DateTime? time;
  final String? flowCategory;
  final String units;

  const CompactFlowValueIndicator({
    super.key,
    this.flowValue,
    this.time,
    this.flowCategory,
    this.units = 'ft³/s',
  });

  @override
  Widget build(BuildContext context) {
    return FlowValueIndicator(
      flowValue: flowValue,
      time: time,
      flowCategory: flowCategory,
      size: 60.0,
      units: units,
    );
  }
}

/// Large version for detailed displays
class LargeFlowValueIndicator extends StatelessWidget {
  final double? flowValue;
  final DateTime? time;
  final String? flowCategory;
  final String units;

  const LargeFlowValueIndicator({
    super.key,
    this.flowValue,
    this.time,
    this.flowCategory,
    this.units = 'ft³/s',
  });

  @override
  Widget build(BuildContext context) {
    return FlowValueIndicator(
      flowValue: flowValue,
      time: time,
      flowCategory: flowCategory,
      size: 100.0,
      units: units,
    );
  }
}
