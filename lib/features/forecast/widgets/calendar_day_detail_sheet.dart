// lib/features/forecast/widgets/calendar_day_detail_sheet.dart

import 'package:flutter/cupertino.dart';
import '../../../core/constants.dart';
import 'package:get_it/get_it.dart';
import '../../../core/services/i_flow_unit_preference_service.dart';
import '../domain/entities/daily_flow_forecast.dart';

/// Modal bottom sheet that displays detailed flow information for a selected calendar day
///
/// Shows comprehensive flow data including daily summary, flow category, and hourly breakdown.
/// Follows Cupertino design patterns consistent with the rest of the app.
class CalendarDayDetailSheet extends StatefulWidget {
  /// The daily forecast data to display
  final DailyFlowForecast forecast;

  const CalendarDayDetailSheet({super.key, required this.forecast});

  @override
  State<CalendarDayDetailSheet> createState() => _CalendarDayDetailSheetState();
}

class _CalendarDayDetailSheetState extends State<CalendarDayDetailSheet> {
  // Get current flow units from preference service
  String _getCurrentFlowUnit() {
    final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
    return currentUnit == 'CMS' ? 'CMS' : 'CFS';
  }

  @override
  Widget build(BuildContext context) {
    final dayLabel = _getFullDayName(widget.forecast.date);

    return CupertinoPopupSurface(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.55,
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
        ),
        child: Column(
          children: [
            // Header
            _buildHeader(dayLabel),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),

                    // Flow summary card
                    _buildFlowSummaryCard(),

                    const SizedBox(height: 24),

                    // Hourly breakdown section
                    if (widget.forecast.hasHourlyData) ...[
                      _buildSectionHeader('Hourly Flow Data'),
                      const SizedBox(height: 12),
                      _buildHourlyDataSection(),
                    ] else ...[
                      _buildNoHourlyDataMessage(),
                    ],

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build the header section with date and close button
  Widget _buildHeader(String dayLabel) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dayLabel,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                Text(
                  _formatFullDate(widget.forecast.date),
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(context),
            child: const Icon(
              CupertinoIcons.xmark_circle_fill,
              color: CupertinoColors.systemGrey3,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  /// Build the flow summary card with category, min/max/avg flows
  Widget _buildFlowSummaryCard() {
    final categoryColor = AppConstants.getFlowCategoryColor(
      widget.forecast.flowCategory,
    );
    final categoryIcon = AppConstants.getFlowCategoryIcon(
      widget.forecast.flowCategory,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: categoryColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: categoryColor.withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Flow category header
          Row(
            children: [
              Icon(categoryIcon, color: categoryColor, size: 20),
              const SizedBox(width: 8),
              Text(
                widget.forecast.flowCategory,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: categoryColor,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Flow statistics
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildFlowStat('Min', widget.forecast.minFlow),
              _buildFlowStat('Avg', widget.forecast.avgFlow),
              _buildFlowStat('Max', widget.forecast.maxFlow),
            ],
          ),

          // Data source info
          const SizedBox(height: 12),
          Text(
            'Data Source: ${widget.forecast.dataSourceDescription}',
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  /// Build individual flow statistic with correct unit
  Widget _buildFlowStat(String label, double value) {
    final currentUnit = _getCurrentFlowUnit();

    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${value.toStringAsFixed(0)} $currentUnit',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ],
    );
  }

  /// Build section header
  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: CupertinoColors.label.resolveFrom(context),
      ),
    );
  }

  /// Build hourly data section with scrollable hour cards
  Widget _buildHourlyDataSection() {
    final sortedHourlyData = widget.forecast.sortedHourlyData;

    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: sortedHourlyData.length,
        itemBuilder: (context, index) {
          final entry = sortedHourlyData[index];
          final isFirst = index == 0;
          final isLast = index == sortedHourlyData.length - 1;

          return Padding(
            padding: EdgeInsets.only(
              left: isFirst ? 0 : 8,
              right: isLast ? 0 : 0,
            ),
            child: _buildHourlyCard(entry.key, entry.value),
          );
        },
      ),
    );
  }

  /// Build individual hourly flow card with correct unit
  Widget _buildHourlyCard(DateTime time, double flow) {
    final isCurrentHour = _isCurrentHour(time);
    final categoryColor = AppConstants.getFlowCategoryColor(
      widget.forecast.flowCategory,
    );
    final currentUnit = _getCurrentFlowUnit();

    return Container(
      width: 80,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCurrentHour
            ? categoryColor.withValues(alpha: 0.2)
            : CupertinoColors.tertiarySystemBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(8),
        border: isCurrentHour
            ? Border.all(color: categoryColor.withValues(alpha: 0.8), width: 1.5)
            : Border.all(
                color: CupertinoColors.separator.resolveFrom(context),
                width: 0.5,
              ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Time
          Text(
            _formatHourTime(time),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isCurrentHour
                  ? categoryColor
                  : CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),

          const SizedBox(height: 8),

          // Flow value
          Text(
            _formatFlow(flow),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: isCurrentHour
                  ? categoryColor
                  : CupertinoColors.label.resolveFrom(context),
            ),
          ),

          // Unit label
          Text(
            currentUnit,
            style: TextStyle(
              fontSize: 10,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  /// Build message when no hourly data is available
  Widget _buildNoHourlyDataMessage() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(
            CupertinoIcons.clock,
            size: 48,
            color: CupertinoColors.systemGrey.resolveFrom(context),
          ),
          const SizedBox(height: 12),
          Text(
            'No Hourly Data Available',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Only daily summary data is available for this forecast.',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Get full day name (Monday, Tuesday, etc.)
  String _getFullDayName(DateTime date) {
    const dayNames = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];

    return dayNames[date.weekday - 1]; // weekday is 1-7, array is 0-6
  }

  /// Check if the given time is the current hour
  bool _isCurrentHour(DateTime time) {
    final now = DateTime.now();
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);
    final timeHour = DateTime(time.year, time.month, time.day, time.hour);
    return timeHour == currentHour;
  }

  /// Format the full date for header display
  String _formatFullDate(DateTime date) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  /// Format hour time for hourly cards
  String _formatHourTime(DateTime time) {
    final hour = time.hour;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour$period';
  }

  /// Format flow value for display
  String _formatFlow(double flow) {
    if (flow >= 1000000) {
      return '${(flow / 1000000).toStringAsFixed(1)}M';
    } else if (flow >= 1000) {
      return '${(flow / 1000).toStringAsFixed(1)}K';
    } else if (flow >= 100) {
      return flow.toStringAsFixed(0);
    } else {
      return flow.toStringAsFixed(1);
    }
  }
}

/// Helper function to show the calendar day detail sheet
void showCalendarDayDetailSheet(
  BuildContext context,
  DailyFlowForecast forecast,
) {
  showCupertinoModalPopup<void>(
    context: context,
    builder: (BuildContext context) =>
        CalendarDayDetailSheet(forecast: forecast),
  );
}
