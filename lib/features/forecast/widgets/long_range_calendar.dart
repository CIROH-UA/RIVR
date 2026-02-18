// lib/features/forecast/widgets/long_range_calendar.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/core/services/app_logger.dart';
import '../../../core/providers/reach_data_provider.dart';
import '../domain/entities/daily_flow_forecast.dart';
import '../services/daily_forecast_processor.dart';
import 'calendar_day_cell.dart';
import 'calendar_day_detail_sheet.dart';

/// Calendar widget that displays long range flow forecasts in a monthly grid layout
///
/// Shows flow data for each day with color coding based on flow categories.
/// Supports month navigation when forecast data spans multiple months.
/// Uses existing data pipeline from ReachDataProvider and DailyForecastProcessor.
class LongRangeCalendar extends StatefulWidget {
  /// Reach ID for loading forecast data
  final String reachId;

  /// Custom height for the calendar (optional)
  final double? height;

  /// Padding around the calendar
  final EdgeInsets? padding;

  const LongRangeCalendar({
    super.key,
    required this.reachId,
    this.height,
    this.padding,
  });

  @override
  State<LongRangeCalendar> createState() => _LongRangeCalendarState();
}

class _LongRangeCalendarState extends State<LongRangeCalendar> {
  late DateTime _currentMonth;
  Map<DateTime, DailyFlowForecast> _forecastMap = {};
  bool _hasMultipleMonths = false;
  DateTime? _dataStartDate;
  DateTime? _dataEndDate;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReachDataProvider>(
      builder: (context, reachProvider, child) {
        if (reachProvider.isLoading) {
          return _buildLoadingState();
        }

        if (reachProvider.errorMessage != null) {
          return _buildErrorState(reachProvider.errorMessage!);
        }

        if (!reachProvider.hasData || reachProvider.currentForecast == null) {
          return _buildNoDataState();
        }

        // Process long range forecast data
        _processLongRangeData(reachProvider);

        return _buildCalendar();
      },
    );
  }

  /// Process long range forecast data into daily forecasts
  void _processLongRangeData(ReachDataProvider reachProvider) {
    try {
      final forecasts = DailyForecastProcessor.processLongRange(
        forecastResponse: reachProvider.currentForecast!,
      );

      if (forecasts.isEmpty) {
        _forecastMap = {};
        return;
      }

      // Update forecast data
      _forecastMap = {
        for (final forecast in forecasts)
          DateTime(forecast.date.year, forecast.date.month, forecast.date.day):
              forecast,
      };

      // Determine date range and multi-month support
      _dataStartDate = forecasts.first.date;
      _dataEndDate = forecasts.last.date;
      _hasMultipleMonths =
          _dataStartDate!.month != _dataEndDate!.month ||
          _dataStartDate!.year != _dataEndDate!.year;

      // Set current month to first month with data if not already set to a data month
      final hasDataInCurrentMonth = forecasts.any(
        (f) =>
            f.date.year == _currentMonth.year &&
            f.date.month == _currentMonth.month,
      );

      if (!hasDataInCurrentMonth) {
        _currentMonth = DateTime(
          _dataStartDate!.year,
          _dataStartDate!.month,
          1,
        );
      }
    } catch (e) {
      AppLogger.error('LongRangeCalendar', 'Error processing forecast data', e);
      _forecastMap = {};
    }
  }

  /// Build the main calendar widget
  Widget _buildCalendar() {
    return Container(
      padding: widget.padding ?? const EdgeInsets.all(16),
      child: Column(
        children: [
          // Calendar header with month/year and navigation
          _buildCalendarHeader(),

          const SizedBox(height: 16),

          // Weekday headers
          _buildWeekdayHeaders(),

          const SizedBox(height: 8),

          // Calendar grid
          _buildCalendarGrid(),
        ],
      ),
    );
  }

  /// Build calendar header with month/year and navigation arrows
  Widget _buildCalendarHeader() {
    final monthYear = _formatMonthYear(_currentMonth);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Previous month button
        CupertinoButton(
          padding: const EdgeInsets.all(8),
          onPressed: _hasMultipleMonths ? _goToPreviousMonth : null,
          child: Icon(
            CupertinoIcons.chevron_left,
            color: _hasMultipleMonths
                ? CupertinoColors.systemBlue
                : CupertinoColors.systemGrey3,
            size: 20,
          ),
        ),

        // Month and year
        Text(
          monthYear,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),

        // Next month button
        CupertinoButton(
          padding: const EdgeInsets.all(8),
          onPressed: _hasMultipleMonths ? _goToNextMonth : null,
          child: Icon(
            CupertinoIcons.chevron_right,
            color: _hasMultipleMonths
                ? CupertinoColors.systemBlue
                : CupertinoColors.systemGrey3,
            size: 20,
          ),
        ),
      ],
    );
  }

  /// Build weekday headers (Sun, Mon, Tue, etc.)
  Widget _buildWeekdayHeaders() {
    const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

    return Row(
      children: weekdays
          .map(
            (day) => Expanded(
              child: Center(
                child: Text(
                  day,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  /// Build the calendar grid with day cells
  Widget _buildCalendarGrid() {
    final calendarDays = _generateCalendarDays(_currentMonth);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 1.0,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: calendarDays.length,
      itemBuilder: (context, index) {
        final calendarDay = calendarDays[index];
        return _buildCalendarDay(calendarDay);
      },
    );
  }

  /// Build individual calendar day
  Widget _buildCalendarDay(CalendarDay calendarDay) {
    final forecast = _forecastMap[calendarDay.date];

    if (forecast == null) {
      // No forecast data for this day - show empty cell
      return _buildEmptyDayCell(calendarDay);
    }

    return CalendarDayCell(
      forecast: forecast,
      onTap: () => _showDayDetails(forecast),
      isToday: _isToday(calendarDay.date),
      isCurrentMonth: calendarDay.isCurrentMonth,
      cellSize: 50,
      // Units will be handled by CalendarDayCell if it displays flow values
    );
  }

  /// Build empty day cell for days without forecast data
  Widget _buildEmptyDayCell(CalendarDay calendarDay) {
    return Container(
      width: 50,
      height: 50,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: calendarDay.isCurrentMonth
            ? CupertinoColors.systemGrey6.resolveFrom(context)
            : CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          calendarDay.date.day.toString(),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: calendarDay.isCurrentMonth
                ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                : CupertinoColors.tertiaryLabel
                      .resolveFrom(context)
                      .withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  /// Generate calendar days for the given month (includes prev/next month days)
  List<CalendarDay> _generateCalendarDays(DateTime month) {
    final List<CalendarDay> days = [];

    // First day of the month
    final firstDayOfMonth = DateTime(month.year, month.month, 1);

    // First day of the calendar (might be from previous month)
    final firstDayOfCalendar = firstDayOfMonth.subtract(
      Duration(days: firstDayOfMonth.weekday % 7),
    );

    // Generate 42 days (6 weeks) for the calendar
    for (int i = 0; i < 42; i++) {
      final date = firstDayOfCalendar.add(Duration(days: i));
      final isCurrentMonth =
          date.month == month.month && date.year == month.year;

      days.add(
        CalendarDay(
          date: DateTime(date.year, date.month, date.day),
          isCurrentMonth: isCurrentMonth,
        ),
      );
    }

    return days;
  }

  /// Show day details modal
  void _showDayDetails(DailyFlowForecast forecast) {
    showCalendarDayDetailSheet(context, forecast);
  }

  /// Navigate to previous month
  void _goToPreviousMonth() {
    if (!_hasMultipleMonths || _dataStartDate == null) return;

    final newMonth = DateTime(_currentMonth.year, _currentMonth.month - 1, 1);

    // Don't go before the first month with data
    if (newMonth.isBefore(
      DateTime(_dataStartDate!.year, _dataStartDate!.month, 1),
    )) {
      return;
    }

    setState(() {
      _currentMonth = newMonth;
    });
  }

  /// Navigate to next month
  void _goToNextMonth() {
    if (!_hasMultipleMonths || _dataEndDate == null) return;

    final newMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 1);

    // Don't go past the last month with data
    if (newMonth.isAfter(
      DateTime(_dataEndDate!.year, _dataEndDate!.month, 1),
    )) {
      return;
    }

    setState(() {
      _currentMonth = newMonth;
    });
  }

  /// Check if date is today
  bool _isToday(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return date == today;
  }

  /// Format month and year for header
  String _formatMonthYear(DateTime date) {
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

    return '${months[date.month - 1]} ${date.year}';
  }

  /// Build loading state
  Widget _buildLoadingState() {
    return Container(
      height: widget.height ?? 400,
      padding: widget.padding ?? const EdgeInsets.all(16),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CupertinoActivityIndicator(radius: 16),
            SizedBox(height: 12),
            Text(
              'Loading calendar data...',
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build error state
  Widget _buildErrorState(String error) {
    return Container(
      height: widget.height ?? 400,
      padding: widget.padding ?? const EdgeInsets.all(16),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 48,
              color: CupertinoColors.systemRed,
            ),
            const SizedBox(height: 16),
            const Text(
              'Unable to load calendar',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: const TextStyle(
                fontSize: 14,
                color: CupertinoColors.secondaryLabel,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Build no data state
  Widget _buildNoDataState() {
    return Container(
      height: widget.height ?? 400,
      padding: widget.padding ?? const EdgeInsets.all(16),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.calendar,
              size: 48,
              color: CupertinoColors.systemGrey,
            ),
            SizedBox(height: 16),
            Text(
              'No calendar data available',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Long range forecast data is not available for this reach.',
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.tertiaryLabel,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper class for calendar day information
class CalendarDay {
  final DateTime date;
  final bool isCurrentMonth;

  const CalendarDay({required this.date, required this.isCurrentMonth});
}
