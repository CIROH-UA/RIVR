// lib/features/forecast/widgets/daily_expandable_widget/flow_condition_icon.dart

import 'package:flutter/cupertino.dart';

/// Simple icon widget that displays an appropriate icon based on flow category
///
/// Uses RIVR's standard Cupertino design system with consistent colors and icons
/// for flow condition visualization across the app.
class FlowConditionIcon extends StatelessWidget {
  /// The flow category to display an icon for
  /// Expected values: 'Normal', 'Elevated', 'High', 'Flood Risk', 'Unknown'
  final String flowCategory;

  /// Size of the icon in logical pixels
  final double size;

  /// Whether to display a circular background behind the icon
  final bool withBackground;

  /// Optional color override (if null, uses category-based color)
  final Color? color;

  const FlowConditionIcon({
    super.key,
    required this.flowCategory,
    this.size = 24.0,
    this.withBackground = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final iconData = _getIconForCategory(flowCategory);
    final iconColor = color ?? _getColorForCategory(flowCategory);

    final icon = Icon(iconData, color: iconColor, size: size);

    if (withBackground) {
      return Container(
        width: size * 1.5,
        height: size * 1.5,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Center(child: icon),
      );
    }

    return icon;
  }

  /// Get the appropriate Cupertino icon for a flow category
  IconData _getIconForCategory(String category) {
    switch (category.toLowerCase()) {
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

  /// Get the appropriate Cupertino color for a flow category
  /// Uses RIVR's standard color scheme
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

/// Specialized version with preset styling for daily forecast rows
///
/// Pre-configured for optimal display in expandable daily forecast widgets
class DailyForecastFlowIcon extends StatelessWidget {
  final String flowCategory;
  final bool isToday;

  const DailyForecastFlowIcon({
    super.key,
    required this.flowCategory,
    this.isToday = false,
  });

  @override
  Widget build(BuildContext context) {
    return FlowConditionIcon(
      flowCategory: flowCategory,
      size: isToday ? 26.0 : 24.0, // Slightly larger for today
      withBackground: true,
    );
  }
}

/// Compact version for use in tight spaces or lists
class CompactFlowIcon extends StatelessWidget {
  final String flowCategory;

  const CompactFlowIcon({super.key, required this.flowCategory});

  @override
  Widget build(BuildContext context) {
    return FlowConditionIcon(
      flowCategory: flowCategory,
      size: 16.0,
      withBackground: false,
    );
  }
}
