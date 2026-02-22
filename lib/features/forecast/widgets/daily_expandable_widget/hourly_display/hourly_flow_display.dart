// lib/features/forecast/widgets/daily_expandable_widget/hourly_display/hourly_flow_display.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/core/models/reach_data.dart';
import 'package:rivr/features/forecast/widgets/daily_expandable_widget/hourly_display/flow_value_indicator.dart';
import 'package:rivr/features/forecast/widgets/daily_expandable_widget/hourly_display/micro_bar_chart.dart';
import 'package:rivr/features/forecast/widgets/daily_expandable_widget/hourly_display/time_slider.dart';
import 'package:get_it/get_it.dart';
import '../../../../../core/services/i_flow_unit_preference_service.dart';
import '../../../domain/entities/daily_flow_forecast.dart';

/// Main widget that displays hourly flow data for a selected day
///
/// Provides interactive visualization of hourly flow data with a time slider,
/// bar chart, and detailed flow value indicator. Uses Cupertino design patterns
/// for smooth iOS-style interactions.
class HourlyFlowDisplay extends StatefulWidget {
  /// The daily forecast containing hourly data to display
  final DailyFlowForecast forecast;

  /// Optional reach data for enhanced flow categorization
  final ReachData? reach;

  /// Height of the display widget
  final double height;

  /// Whether to show the time slider (default: true)
  final bool showTimeSlider;

  const HourlyFlowDisplay({
    super.key,
    required this.forecast,
    this.reach,
    this.height = 120.0,
    this.showTimeSlider = true,
  });

  @override
  State<HourlyFlowDisplay> createState() => _HourlyFlowDisplayState();
}

class _HourlyFlowDisplayState extends State<HourlyFlowDisplay> {
  late int _selectedHourIndex;
  late List<MapEntry<DateTime, double>> _sortedHourlyData;

  // Value range for the chart
  double _minFlow = 0;
  double _maxFlow = 100;

  // Currently selected flow data
  DateTime? _selectedTime;
  double? _selectedFlow;
  String? _selectedCategory;

  // Get current flow unit display label from preference service
  String _getCurrentFlowUnit() {
    return GetIt.I<IFlowUnitPreferenceService>().getDisplayUnit();
  }

  @override
  void initState() {
    super.initState();
    _processHourlyData();
    _setInitialPosition();
  }

  @override
  void didUpdateWidget(HourlyFlowDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.forecast != widget.forecast) {
      _processHourlyData();
      _setInitialPosition();
    }
  }

  /// Process the hourly data for display
  void _processHourlyData() {
    // Convert map to sorted list for easier access
    _sortedHourlyData = widget.forecast.sortedHourlyData;

    // Calculate min and max flow values for the chart
    if (_sortedHourlyData.isNotEmpty) {
      _minFlow = _sortedHourlyData
          .map((e) => e.value)
          .reduce((a, b) => a < b ? a : b);
      _maxFlow = _sortedHourlyData
          .map((e) => e.value)
          .reduce((a, b) => a > b ? a : b);

      // Add a small buffer (5%) for visual clarity
      final range = _maxFlow - _minFlow;
      if (range > 0) {
        _minFlow = (_minFlow - (range * 0.05)).clamp(0, double.infinity);
        _maxFlow = _maxFlow + (range * 0.05);
      }
    }
  }

  /// Set the initial slider position intelligently
  void _setInitialPosition() {
    if (_sortedHourlyData.isEmpty) {
      _selectedHourIndex = 0;
      _selectedTime = null;
      _selectedFlow = null;
      _selectedCategory = null;
      return;
    }

    // Try to find the current hour if viewing today's forecast
    final now = DateTime.now();
    final isToday = _isToday(widget.forecast.date);

    if (isToday) {
      // Find the closest hour to current time
      final currentHour = now.hour;
      int closestIndex = 0;
      int smallestDifference = 24;

      for (int i = 0; i < _sortedHourlyData.length; i++) {
        final hour = _sortedHourlyData[i].key.hour;
        final difference = (hour - currentHour).abs();

        if (difference < smallestDifference) {
          smallestDifference = difference;
          closestIndex = i;
        }
      }

      _selectedHourIndex = closestIndex;
    } else {
      // For other days, start with the highest flow hour
      int highestFlowIndex = 0;
      double highestFlow = _sortedHourlyData[0].value;

      for (int i = 1; i < _sortedHourlyData.length; i++) {
        if (_sortedHourlyData[i].value > highestFlow) {
          highestFlow = _sortedHourlyData[i].value;
          highestFlowIndex = i;
        }
      }

      _selectedHourIndex = highestFlowIndex;
    }

    _updateSelectedValues();
  }

  /// Update the selected values based on the selected hour index
  void _updateSelectedValues() {
    if (_selectedHourIndex < 0 ||
        _selectedHourIndex >= _sortedHourlyData.length) {
      _selectedTime = null;
      _selectedFlow = null;
      _selectedCategory = null;
      return;
    }

    _selectedTime = _sortedHourlyData[_selectedHourIndex].key;
    _selectedFlow = _sortedHourlyData[_selectedHourIndex].value;

    // Get flow category for the selected hour
    if (widget.reach?.hasReturnPeriods == true && _selectedFlow != null) {
      final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
      _selectedCategory = widget.reach!.getFlowCategory(
        _selectedFlow!,
        currentUnit,
      );
    } else {
      _selectedCategory = widget.forecast.flowCategory;
    }
  }

  /// Called when the slider value changes
  void _onSliderChanged(double value) {
    final newIndex = value.round();

    if (newIndex != _selectedHourIndex &&
        newIndex >= 0 &&
        newIndex < _sortedHourlyData.length) {
      setState(() {
        _selectedHourIndex = newIndex;
        _updateSelectedValues();
      });
    }
  }

  /// Check if a date represents today
  bool _isToday(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final checkDate = DateTime(date.year, date.month, date.day);
    return checkDate == today;
  }

  @override
  Widget build(BuildContext context) {
    // Handle no hourly data
    if (_sortedHourlyData.isEmpty) {
      return _buildNoDataState();
    }

    // Handle single data point
    if (_sortedHourlyData.length == 1) {
      return _buildSingleDataPointState();
    }

    final currentUnit = _getCurrentFlowUnit();

    // NEW LAYOUT: Row with Column (chart/slider/time) + FlowValueIndicator
    return Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0),
      child: Row(
        children: [
          // LEFT SIDE: Column with chart, slider, and time values
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Bar chart (takes most space)
                Expanded(
                  child: MicroBarChart(
                    hourlyData: _sortedHourlyData,
                    selectedIndex: _selectedHourIndex,
                    minValue: _minFlow,
                    maxValue: _maxFlow,
                    reach: widget.reach,
                    onBarTapped: (index) {
                      setState(() {
                        _selectedHourIndex = index;
                        _updateSelectedValues();
                      });
                    },
                  ),
                ),

                // Slider (if enabled)
                if (widget.showTimeSlider)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: HourlyTimeSlider(
                      hourCount: _sortedHourlyData.length,
                      currentValue: _selectedHourIndex.toDouble(),
                      onChanged: _onSliderChanged,
                      hourLabels: _sortedHourlyData.map((e) => e.key).toList(),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(width: 10), // Space between chart column and indicator
          // RIGHT SIDE: Flow value indicator (now has much more space!)
          Column(
            children: [
              FlowValueIndicator(
                flowValue: _selectedFlow,
                time: _selectedTime,
                flowCategory: _selectedCategory,
                size: 100.0,
                units: currentUnit, // Pass dynamic units
              ),
              Spacer(),
            ],
          ),
        ],
      ),
    );
  }

  /// Build state for when no hourly data is available
  Widget _buildNoDataState() {
    return Container(
      height: widget.height,
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.clock,
              color: CupertinoColors.systemGrey2,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              'No hourly data available for this day',
              style: TextStyle(
                color: CupertinoColors.systemGrey2,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Build state for when only one hour of data is available
  Widget _buildSingleDataPointState() {
    final entry = _sortedHourlyData.first;
    final time = entry.key;
    final flow = entry.value;
    final currentUnit = _getCurrentFlowUnit();

    String? category;
    if (widget.reach?.hasReturnPeriods == true) {
      final flowUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
      category = widget.reach!.getFlowCategory(flow, flowUnit);
    } else {
      category = widget.forecast.flowCategory;
    }

    return Container(
      height: widget.height,
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Single data point display
          Expanded(
            child: Center(
              child: FlowValueIndicator(
                flowValue: flow,
                time: time,
                flowCategory: category,
                size: 120.0, // Updated size for single data point
                units: currentUnit, // Pass dynamic units
              ),
            ),
          ),

          // Info text
          Text(
            'Only one hour of data available',
            style: TextStyle(color: CupertinoColors.systemGrey2, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
