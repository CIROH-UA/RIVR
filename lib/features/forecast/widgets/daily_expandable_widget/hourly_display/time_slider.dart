// lib/features/forecast/widgets/daily_expandable_widget/hourly_display/time_slider.dart

import 'package:flutter/cupertino.dart';

/// A custom time slider for selecting hours in hourly flow data
///
/// Provides smooth Cupertino-style interaction for hour selection with
/// time labels and intelligent formatting.
class HourlyTimeSlider extends StatelessWidget {
  /// Number of hours available
  final int hourCount;

  /// Current selected value (0 to hourCount-1)
  final double currentValue;

  /// Callback when slider value changes
  final ValueChanged<double> onChanged;

  /// List of DateTime objects representing each hour
  final List<DateTime> hourLabels;

  /// Height of the slider area
  final double height;

  /// Whether to show time markers below slider
  final bool showTimeMarkers;

  const HourlyTimeSlider({
    super.key,
    required this.hourCount,
    required this.currentValue,
    required this.onChanged,
    required this.hourLabels,
    this.height = 60.0,
    this.showTimeMarkers = true,
  });

  @override
  Widget build(BuildContext context) {
    // Handle edge cases
    if (hourCount <= 1 || hourLabels.isEmpty) {
      return _buildEmptyState(context);
    }

    return SizedBox(
      height: height,
      child: Column(
        children: [
          // Main slider
          Expanded(
            child: CupertinoSlider(
              min: 0,
              max: (hourCount - 1).toDouble(),
              divisions: hourCount - 1,
              value: currentValue.clamp(0, (hourCount - 1).toDouble()),
              onChanged: onChanged,
              activeColor: CupertinoColors.systemBlue,
              thumbColor: CupertinoColors.systemBlue,
            ),
          ),

          // Time markers
          if (showTimeMarkers)
            SizedBox(height: 20, child: _buildTimeMarkers(context)),
        ],
      ),
    );
  }

  /// Build empty state for insufficient data
  Widget _buildEmptyState(BuildContext context) {
    return SizedBox(
      height: height,
      child: Center(
        child: Text(
          hourCount == 1
              ? 'Single hour of data available'
              : 'No hourly data available',
          style: TextStyle(
            color: CupertinoColors.systemGrey2.resolveFrom(context),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// Build time markers below the slider
  Widget _buildTimeMarkers(BuildContext context) {
    if (hourLabels.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: _buildMarkerWidgets(context, constraints.maxWidth),
        );
      },
    );
  }

  /// Build individual marker widgets
  List<Widget> _buildMarkerWidgets(BuildContext context, double totalWidth) {
    final markers = <Widget>[];

    // Calculate how many markers we can reasonably show
    final availableSpace = totalWidth;
    final minMarkerSpacing = 60.0; // Minimum space between markers
    final maxMarkers = (availableSpace / minMarkerSpacing).floor().clamp(
      2,
      hourLabels.length,
    );

    if (maxMarkers < 2) {
      // Not enough space for proper markers
      return [
        Positioned(left: 0, child: _buildMarkerText(context, hourLabels.first)),
        Positioned(right: 0, child: _buildMarkerText(context, hourLabels.last)),
      ];
    }

    // Always show first and last
    markers.add(
      Positioned(left: 0, child: _buildMarkerText(context, hourLabels.first)),
    );

    markers.add(
      Positioned(right: 0, child: _buildMarkerText(context, hourLabels.last)),
    );

    // Add middle markers if we have space
    if (maxMarkers > 2) {
      final middleCount = maxMarkers - 2;
      final interval = (hourLabels.length - 1) / (middleCount + 1);

      for (int i = 1; i <= middleCount; i++) {
        final index = (interval * i).round();
        if (index > 0 && index < hourLabels.length - 1) {
          final position = (index / (hourLabels.length - 1)) * totalWidth;

          markers.add(
            Positioned(
              left: position - 20, // Center the 40px wide text
              child: SizedBox(
                width: 40,
                child: _buildMarkerText(context, hourLabels[index]),
              ),
            ),
          );
        }
      }
    }

    return markers;
  }

  /// Build text widget for time marker
  Widget _buildMarkerText(BuildContext context, DateTime time) {
    return Text(
      _formatTimeMarker(time),
      style: TextStyle(
        fontSize: 10,
        color: CupertinoColors.systemGrey.resolveFrom(context),
        fontWeight: FontWeight.w500,
      ),
      textAlign: TextAlign.center,
    );
  }

  /// Format time for marker display
  String _formatTimeMarker(DateTime time) {
    final hour = time.hour;

    // Use 12-hour format
    if (hour == 0) {
      return '12 AM';
    } else if (hour < 12) {
      return '$hour AM';
    } else if (hour == 12) {
      return '12 PM';
    } else {
      return '${hour - 12} PM';
    }
  }
}

/// Enhanced time slider with current time indicator
class EnhancedHourlyTimeSlider extends StatelessWidget {
  final int hourCount;
  final double currentValue;
  final ValueChanged<double> onChanged;
  final List<DateTime> hourLabels;
  final double height;

  /// Optional current time to highlight
  final DateTime? currentTime;

  /// Whether this forecast represents today
  final bool isToday;

  const EnhancedHourlyTimeSlider({
    super.key,
    required this.hourCount,
    required this.currentValue,
    required this.onChanged,
    required this.hourLabels,
    this.height = 70.0,
    this.currentTime,
    this.isToday = false,
  });

  @override
  Widget build(BuildContext context) {
    if (hourCount <= 1 || hourLabels.isEmpty) {
      return HourlyTimeSlider(
        hourCount: hourCount,
        currentValue: currentValue,
        onChanged: onChanged,
        hourLabels: hourLabels,
        height: height,
      );
    }

    return SizedBox(
      height: height,
      child: Column(
        children: [
          // Slider with current time indicator
          Expanded(
            child: Stack(
              children: [
                // Main slider
                CupertinoSlider(
                  min: 0,
                  max: (hourCount - 1).toDouble(),
                  divisions: hourCount - 1,
                  value: currentValue.clamp(0, (hourCount - 1).toDouble()),
                  onChanged: onChanged,
                  activeColor: CupertinoColors.systemBlue,
                  thumbColor: CupertinoColors.systemBlue,
                ),

                // Current time indicator
                if (isToday && currentTime != null)
                  _buildCurrentTimeIndicator(context),
              ],
            ),
          ),

          // Time markers with current time highlight
          SizedBox(height: 25, child: _buildEnhancedTimeMarkers(context)),
        ],
      ),
    );
  }

  /// Build current time indicator
  Widget _buildCurrentTimeIndicator(BuildContext context) {
    if (currentTime == null || hourLabels.isEmpty) {
      return const SizedBox.shrink();
    }

    // Find the closest hour index to current time
    int closestIndex = 0;
    Duration minDifference = Duration(hours: 24);

    for (int i = 0; i < hourLabels.length; i++) {
      final difference = hourLabels[i].difference(currentTime!).abs();
      if (difference < minDifference) {
        minDifference = difference;
        closestIndex = i;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final position =
            (closestIndex / (hourLabels.length - 1)) * constraints.maxWidth;

        return Positioned(
          left: position - 1,
          top: 8,
          child: Container(
            width: 2,
            height: 16,
            decoration: BoxDecoration(
              color: CupertinoColors.systemRed,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      },
    );
  }

  /// Build enhanced time markers with current time highlight
  Widget _buildEnhancedTimeMarkers(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final List<Widget> markers = [];
        final totalWidth = constraints.maxWidth;

        // Show start, middle, and end times
        markers.add(
          Positioned(
            left: 0,
            child: _buildEnhancedMarkerText(context, hourLabels.first, false),
          ),
        );

        if (hourLabels.length > 2) {
          final middleIndex = hourLabels.length ~/ 2;
          final middlePosition =
              (middleIndex / (hourLabels.length - 1)) * totalWidth;

          markers.add(
            Positioned(
              left: middlePosition - 20,
              child: SizedBox(
                width: 40,
                child: _buildEnhancedMarkerText(
                  context,
                  hourLabels[middleIndex],
                  false,
                ),
              ),
            ),
          );
        }

        markers.add(
          Positioned(
            right: 0,
            child: _buildEnhancedMarkerText(context, hourLabels.last, false),
          ),
        );

        // Add current time marker if today
        if (isToday && currentTime != null) {
          markers.add(_buildCurrentTimeMarker(context, totalWidth));
        }

        return Stack(children: markers);
      },
    );
  }

  /// Build current time marker
  Widget _buildCurrentTimeMarker(BuildContext context, double totalWidth) {
    // Find position for current time
    int closestIndex = 0;
    Duration minDifference = Duration(hours: 24);

    for (int i = 0; i < hourLabels.length; i++) {
      final difference = hourLabels[i].difference(currentTime!).abs();
      if (difference < minDifference) {
        minDifference = difference;
        closestIndex = i;
      }
    }

    final position = (closestIndex / (hourLabels.length - 1)) * totalWidth;

    return Positioned(
      left: position - 15,
      child: SizedBox(
        width: 30,
        child: Text(
          'Now',
          style: TextStyle(
            fontSize: 9,
            color: CupertinoColors.systemRed,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// Build enhanced marker text
  Widget _buildEnhancedMarkerText(
    BuildContext context,
    DateTime time,
    bool isCurrentTime,
  ) {
    return Text(
      _formatTimeMarker(time),
      style: TextStyle(
        fontSize: 10,
        color: isCurrentTime
            ? CupertinoColors.systemRed
            : CupertinoColors.systemGrey.resolveFrom(context),
        fontWeight: isCurrentTime ? FontWeight.bold : FontWeight.w500,
      ),
      textAlign: TextAlign.center,
    );
  }

  /// Format time for marker display
  String _formatTimeMarker(DateTime time) {
    final hour = time.hour;

    if (hour == 0) {
      return '12 AM';
    } else if (hour < 12) {
      return '$hour AM';
    } else if (hour == 12) {
      return '12 PM';
    } else {
      return '${hour - 12} PM';
    }
  }
}
