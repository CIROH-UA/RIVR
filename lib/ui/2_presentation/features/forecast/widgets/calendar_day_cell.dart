// lib/ui/2_presentation/features/forecast/widgets/calendar_day_cell.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/models/1_domain/features/forecast/daily_flow_forecast.dart';

/// Individual calendar day cell that displays date and flow information
///
/// Shows the day number, highest flow value for that day, and uses color coding
/// based on flow category. Handles tap gestures to show detailed flow information.
class CalendarDayCell extends StatefulWidget {
  /// The daily forecast data for this calendar day
  final DailyFlowForecast forecast;

  /// Callback when the cell is tapped
  final VoidCallback? onTap;

  /// Whether this day is today (highlights differently)
  final bool isToday;

  /// Whether this day is in the current month (affects opacity)
  final bool isCurrentMonth;

  /// Size of the calendar cell
  final double cellSize;

  const CalendarDayCell({
    super.key,
    required this.forecast,
    this.onTap,
    this.isToday = false,
    this.isCurrentMonth = true,
    this.cellSize = 50.0,
  });

  @override
  State<CalendarDayCell> createState() => _CalendarDayCellState();
}

class _CalendarDayCellState extends State<CalendarDayCell> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final categoryColor = AppConstants.getFlowCategoryColor(
      widget.forecast.flowCategory,
    );
    final dayNumber = widget.forecast.date.day;
    final formattedFlow = _formatFlow(widget.forecast.maxFlow);

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: Container(
        width: widget.cellSize,
        height: widget.cellSize,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: _getCellBackgroundColor(categoryColor),
          borderRadius: BorderRadius.circular(8),
          border: _getCellBorder(),
          boxShadow: _isPressed
              ? []
              : [
                  BoxShadow(
                    color: CupertinoColors.systemGrey.withValues(alpha: 0.1),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
        ),
        child: _isPressed
            ? _buildPressedContent(dayNumber, formattedFlow, categoryColor)
            : _buildNormalContent(dayNumber, formattedFlow, categoryColor),
      ),
    );
  }

  /// Build normal cell content
  Widget _buildNormalContent(
    int dayNumber,
    String formattedFlow,
    Color categoryColor,
  ) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Day number
          Text(
            dayNumber.toString(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _getTextColor(categoryColor),
            ),
          ),

          const SizedBox(height: 2),

          // Flow value
          Text(
            formattedFlow,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: _getTextColor(categoryColor).withValues(alpha: 0.9),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Build pressed cell content (slightly different styling)
  Widget _buildPressedContent(
    int dayNumber,
    String formattedFlow,
    Color categoryColor,
  ) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Day number
          Text(
            dayNumber.toString(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: _getTextColor(categoryColor),
            ),
          ),

          const SizedBox(height: 2),

          // Flow value
          Text(
            formattedFlow,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: _getTextColor(categoryColor),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Get the background color for the cell based on flow category and state
  Color _getCellBackgroundColor(Color categoryColor) {
    if (!widget.isCurrentMonth) {
      // Muted color for days outside current month
      return categoryColor.withValues(alpha: 0.5);
    }

    if (_isPressed) {
      // Slightly darker when pressed
      return categoryColor.withValues(alpha: 0.4);
    }

    if (widget.isToday) {
      // More vibrant for today
      return categoryColor.withValues(alpha: 1.0);
    }

    // Normal state
    return categoryColor.withValues(alpha: 0.9);
  }

  /// Get the border for the cell
  Border? _getCellBorder() {
    if (widget.isToday) {
      return Border.all(color: CupertinoColors.black.withValues(alpha: .4), width: 2);
    }

    if (!widget.isCurrentMonth) {
      return Border.all(
        color: CupertinoColors.separator.resolveFrom(context),
        width: 0.5,
      );
    }

    return null;
  }

  /// Get the appropriate text color based on background
  Color _getTextColor(Color backgroundColor) {
    if (!widget.isCurrentMonth) {
      return CupertinoColors.secondaryLabel.resolveFrom(context);
    }

    // Use dark text for light backgrounds, light text for dark backgrounds
    final luminance = backgroundColor.computeLuminance();

    if (luminance > 0.5) {
      return CupertinoColors.label.resolveFrom(context);
    } else {
      return CupertinoColors.white;
    }
  }

  /// Format flow value for display in the small cell
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
