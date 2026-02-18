// lib/features/forecast/widgets/flow_values_usage_guide.dart

import 'package:flutter/cupertino.dart';

/// Educational widget that guides users on different planning horizons
/// for interpreting NOAA National Water Model forecast data.
/// This is not a filter - all options show the same complete forecast dataset.
/// Options are based on official NOAA forecast durations and intended use cases.
class FlowValuesUsageGuide extends StatelessWidget {
  final List<UsageGuideOption> options;
  final String selectedValue;
  final ValueChanged<String> onChanged;
  final EdgeInsets? padding;

  const FlowValuesUsageGuide({
    super.key,
    required this.options,
    required this.selectedValue,
    required this.onChanged,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    // Create a map for the segmented control
    final Map<String, Widget> segmentWidgets = {};

    for (final option in options) {
      segmentWidgets[option.value] = _buildSegmentContent(option);
    }

    return Container(
      padding: padding ?? const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title for the usage guide
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Educational Usage Guide',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
            ),
          ),

          // Segmented Control
          SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<String>(
              children: segmentWidgets,
              groupValue: selectedValue,
              onValueChanged: (String? value) {
                if (value != null) {
                  onChanged(value);
                }
              },
              backgroundColor: CupertinoColors.systemGrey5.resolveFrom(context),
              thumbColor: CupertinoColors.systemBackground.resolveFrom(context),
              padding: const EdgeInsets.all(4),
            ),
          ),

          // Selected option description
          if (_getSelectedOption() != null) ...[
            const SizedBox(height: 12),
            _buildDescription(_getSelectedOption()!),
          ],
        ],
      ),
    );
  }

  Widget _buildSegmentContent(UsageGuideOption option) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            option.displayName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          if (option.subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              option.subtitle!,
              style: const TextStyle(
                fontSize: 11,
                color: CupertinoColors.secondaryLabel,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDescription(UsageGuideOption option) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.systemBlue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: CupertinoColors.systemBlue.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            option.icon ?? CupertinoIcons.clock,
            size: 16,
            color: CupertinoColors.systemBlue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              option.description,
              style: const TextStyle(
                fontSize: 14,
                color: CupertinoColors.label,
              ),
            ),
          ),
        ],
      ),
    );
  }

  UsageGuideOption? _getSelectedOption() {
    try {
      return options.firstWhere((option) => option.value == selectedValue);
    } catch (e) {
      return null;
    }
  }

  // Static factory methods for common forecast types
  static List<UsageGuideOption> shortRangeOptions() {
    return [
      UsageGuideOption(
        value: '6h',
        displayName: '6H',
        subtitle: 'Hours',
        description: 'Emergency response - Immediate safety decisions',
        icon: CupertinoIcons.exclamationmark_triangle,
        dataPoints: 6,
        intervalMinutes: 60,
      ),
      UsageGuideOption(
        value: '12h',
        displayName: '12H',
        subtitle: 'Hours',
        description: 'Daily operations - Near-term activity planning',
        icon: CupertinoIcons.sun_max,
        dataPoints: 12,
        intervalMinutes: 60,
      ),
      UsageGuideOption(
        value: '18h',
        displayName: '18H',
        subtitle: 'Hours',
        description: 'Complete forecast - Full short-range planning horizon',
        icon: CupertinoIcons.calendar,
        dataPoints: 18,
        intervalMinutes: 60,
      ),
    ];
  }

  static List<UsageGuideOption> mediumRangeOptions() {
    return [
      UsageGuideOption(
        value: '3d',
        displayName: '3D',
        subtitle: 'Days',
        description: 'Weekend planning - Short trip preparation',
        icon: CupertinoIcons.calendar,
        dataPoints: 3,
        intervalMinutes: 1440, // 24 hours
      ),
      UsageGuideOption(
        value: '7d',
        displayName: '7D',
        subtitle: 'Days',
        description:
            'Water management - Weekly operations and resource planning',
        icon: CupertinoIcons.calendar_today,
        dataPoints: 7,
        intervalMinutes: 1440,
      ),
      UsageGuideOption(
        value: '10d',
        displayName: '10D',
        subtitle: 'Days',
        description: 'Extended planning - Full medium-range forecast horizon',
        icon: CupertinoIcons.calendar_badge_plus,
        dataPoints: 10,
        intervalMinutes: 1440,
      ),
    ];
  }

  static List<UsageGuideOption> longRangeOptions() {
    return [
      UsageGuideOption(
        value: '1w',
        displayName: '1W',
        subtitle: 'Week',
        description: 'First week outlook - Highest long-range confidence',
        icon: CupertinoIcons.calendar,
        dataPoints: 7,
        intervalMinutes: 1440,
      ),
      UsageGuideOption(
        value: '2w',
        displayName: '2W',
        subtitle: 'Weeks',
        description: 'Two-week planning - Moderate confidence trends',
        icon: CupertinoIcons.calendar_today,
        dataPoints: 14,
        intervalMinutes: 1440,
      ),
      UsageGuideOption(
        value: '30d',
        displayName: '30D',
        subtitle: 'Days',
        description: 'Seasonal outlook - Full long-range forecast horizon',
        icon: CupertinoIcons.chart_bar,
        dataPoints: 30,
        intervalMinutes: 1440,
      ),
    ];
  }
}

/// Represents a usage guide option that explains how to interpret
/// forecast data for a specific planning horizon.
class UsageGuideOption {
  final String value; // '6h', '12h', '18h', '3d', '7d', etc.
  final String displayName; // '6H', '12H', '18H', '3D', '7D', etc.
  final String? subtitle; // 'Hours', 'Days', 'Weeks'
  final String description; // Detailed description for help text
  final IconData? icon; // Optional icon for the option
  final int dataPoints; // Expected number of data points (for reference)
  final int intervalMinutes; // Minutes between data points (for reference)

  const UsageGuideOption({
    required this.value,
    required this.displayName,
    this.subtitle,
    required this.description,
    this.icon,
    required this.dataPoints,
    required this.intervalMinutes,
  });

  // Helper methods for reference (not used for filtering)
  Duration get totalDuration {
    return Duration(minutes: dataPoints * intervalMinutes);
  }

  Duration get intervalDuration {
    return Duration(minutes: intervalMinutes);
  }

  bool get isHourly => intervalMinutes <= 60;
  bool get isDaily =>
      intervalMinutes >= 1440 && intervalMinutes < 10080; // 1 day to 1 week
  bool get isWeekly => intervalMinutes >= 10080; // 1 week or more

  String get intervalDisplayName {
    if (isHourly) return 'Hourly';
    if (isDaily) return 'Daily';
    if (isWeekly) return 'Weekly';
    return 'Custom';
  }

  @override
  String toString() {
    return 'UsageGuideOption(value: $value, displayName: $displayName, dataPoints: $dataPoints)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UsageGuideOption && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;
}
