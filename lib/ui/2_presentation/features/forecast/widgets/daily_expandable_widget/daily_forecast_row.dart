// lib/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/daily_forecast_row.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/flow_condition_icon.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/flow_range_bar.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/models/1_domain/features/forecast/daily_flow_forecast.dart';
import 'package:rivr/services/4_infrastructure/forecast/daily_forecast_processor.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/hourly_display/hourly_flow_display.dart';

/// An expandable row that displays daily flow forecast data
///
/// Collapsed: Shows date, flow icon, range bar, and min/max values
/// Expanded: Adds detailed statistics and hourly flow visualization
class DailyForecastRow extends StatefulWidget {
  /// The daily forecast data to display
  final DailyFlowForecast forecast;

  /// Minimum flow bound for range bar scaling
  final double minFlowBound;

  /// Maximum flow bound for range bar scaling
  final double maxFlowBound;

  /// Whether this forecast represents today
  final bool isToday;

  /// Optional reach data for enhanced categorization
  final ReachData? reach;

  /// Whether the row starts expanded
  final bool initiallyExpanded;

  /// Callback when expansion state changes
  final Function(bool isExpanded)? onExpansionChanged;

  /// Whether this is the last row (affects divider display)
  final bool isLastRow;

  const DailyForecastRow({
    super.key,
    required this.forecast,
    required this.minFlowBound,
    required this.maxFlowBound,
    this.isToday = false,
    this.reach,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.isLastRow = false,
  });

  @override
  State<DailyForecastRow> createState() => _DailyForecastRowState();
}

class _DailyForecastRowState extends State<DailyForecastRow>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _animationController;
  late Animation<double> _expandAnimation;
  String _lastKnownUnit = 'ft³/s';

  // Get current flow unit display label from preference service
  String _getCurrentFlowUnit() {
    return GetIt.I<IFlowUnitPreferenceService>().getDisplayUnit();
  }

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _lastKnownUnit = _getCurrentFlowUnit(); // ✅ NEW: Initialize unit tracking

    // Setup animation controller
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    // Set initial animation state
    if (_isExpanded) {
      _animationController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DailyForecastRow oldWidget) {
    super.didUpdateWidget(oldWidget);

    // ✅ NEW: Check for unit changes and rebuild if necessary
    final currentUnit = _getCurrentFlowUnit();
    final unitChanged = currentUnit != _lastKnownUnit;

    if (oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _isExpanded = widget.initiallyExpanded;
      if (_isExpanded) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    }

    if (unitChanged) {
      AppLogger.debug('DailyForecastRow', 'Unit changed from $_lastKnownUnit to $currentUnit - rebuilding');
      _lastKnownUnit = currentUnit;
      // Force rebuild by calling setState
      setState(() {});
    }
  }

  /// Toggle the expansion state
  void _toggleExpansion() {
    setState(() {
      _isExpanded = !_isExpanded;
    });

    if (_isExpanded) {
      _animationController.forward();
    } else {
      _animationController.reverse();
    }

    widget.onExpansionChanged?.call(_isExpanded);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Main row content (always visible)
        GestureDetector(
          onTap: _toggleExpansion,
          behavior: HitTestBehavior.opaque,
          child: _buildMainRow(context),
        ),

        // Expandable content
        SizeTransition(
          sizeFactor: _expandAnimation,
          child: _buildExpandedContent(context),
        ),

        // Divider (except for last row)
        if (!widget.isLastRow) _buildDivider(context),
      ],
    );
  }

  /// Build the main row content (collapsed view)
  Widget _buildMainRow(BuildContext context) {
    final theme = CupertinoTheme.of(context);

    // Get day label
    final dayLabel = DailyForecastProcessor.getDayLabel(
      widget.forecast.date,
      isToday: widget.isToday,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: _isExpanded
            ? CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.3)
            : null,
      ),
      child: Row(
        children: [
          // Day label
          SizedBox(
            width: 80,
            child: Text(
              dayLabel,
              style: theme.textTheme.textStyle.copyWith(
                fontSize: 16,
                fontWeight: widget.isToday ? FontWeight.bold : FontWeight.w600,
                color: widget.isToday
                    ? CupertinoColors.systemBlue.resolveFrom(context)
                    : CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Flow condition icon
          FlowConditionIcon(
            flowCategory: widget.forecast.flowCategory,
            size: widget.isToday ? 26 : 24,
            withBackground: true,
          ),

          const SizedBox(width: 16),

          // Flow values and range bar
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ✅ UPDATED: Min and max flow values with dynamic units
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildFlowValueWithUnit(
                      context,
                      widget.forecast.minFlow,
                      isToday: widget.isToday,
                    ),
                    _buildFlowValueWithUnit(
                      context,
                      widget.forecast.maxFlow,
                      isToday: widget.isToday,
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // Flow range bar
                FlowRangeBar(
                  forecast: widget.forecast,
                  minFlowBound: widget.minFlowBound,
                  maxFlowBound: widget.maxFlowBound,
                  height: 8.0,
                  reach: widget.reach,
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // Expansion indicator
          AnimatedRotation(
            turns: _isExpanded ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: Icon(
              CupertinoIcons.chevron_down,
              size: 16,
              color: CupertinoColors.systemGrey.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  /// ✅ NEW: Build flow value with unit label
  Widget _buildFlowValueWithUnit(
    BuildContext context,
    double flowValue, {
    bool isToday = false,
  }) {
    final currentUnit = _getCurrentFlowUnit();

    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: _formatFlow(flowValue),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isToday
                  ? CupertinoColors.systemBlue.resolveFrom(context)
                  : CupertinoColors.label.resolveFrom(context),
            ),
          ),
          TextSpan(
            text: ' $currentUnit',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: isToday
                  ? CupertinoColors.systemBlue
                        .resolveFrom(context)
                        .withValues(alpha: 0.7)
                  : CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  /// Build the expanded content
  Widget _buildExpandedContent(BuildContext context) {
    final theme = CupertinoTheme.of(context);

    return Container(
      width: double.infinity,
      color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Detailed statistics
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatFullDate(widget.forecast.date),
                      style: theme.textTheme.navTitleTextStyle.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Flow statistics
                _buildStatisticsGrid(context),
              ],
            ),
          ),

          // Hourly flow display
          if (widget.forecast.hasHourlyData)
            Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              decoration: BoxDecoration(
                color: CupertinoTheme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: HourlyFlowDisplay(
                forecast: widget.forecast,
                reach: widget.reach,
                height: 140,
              ),
            ),

          // Data source info
          if (widget.forecast.dataSource.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.info_circle,
                    size: 14,
                    color: CupertinoColors.systemGrey.resolveFrom(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Data source: ${widget.forecast.dataSourceDescription}',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.systemGrey.resolveFrom(context),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Build statistics grid
  Widget _buildStatisticsGrid(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _buildStatItem(context, 'Min Flow', widget.forecast.minFlow),
        ),
        Expanded(
          child: _buildStatItem(context, 'Max Flow', widget.forecast.maxFlow),
        ),
        Expanded(
          child: _buildStatItem(context, 'Avg Flow', widget.forecast.avgFlow),
        ),
      ],
    );
  }

  /// ✅ UPDATED: Build individual statistic item with correct unit display
  Widget _buildStatItem(BuildContext context, String label, double value) {
    final currentUnit = _getCurrentFlowUnit(); // Get current unit

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 8, height: 8),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_formatFlow(value)} $currentUnit', // ✅ UPDATED: Now dynamic
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ],
    );
  }

  /// Build divider between rows
  Widget _buildDivider(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      height: 0.5,
      color: CupertinoColors.separator.resolveFrom(context),
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
    } else {
      return flow.toStringAsFixed(1);
    }
  }

  /// Format full date for expanded view
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
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];

    final weekday = weekdays[date.weekday - 1];
    final month = months[date.month - 1];

    return '$weekday, $month ${date.day}, ${date.year}';
  }
}

/// ✅ UPDATED: Compact version with unit conversion support
class CompactDailyForecastRow extends StatelessWidget {
  final DailyFlowForecast forecast;
  final double minFlowBound;
  final double maxFlowBound;
  final bool isToday;
  final ReachData? reach;
  final VoidCallback? onTap;

  const CompactDailyForecastRow({
    super.key,
    required this.forecast,
    required this.minFlowBound,
    required this.maxFlowBound,
    this.isToday = false,
    this.reach,
    this.onTap,
  });

  // ✅ NEW: Get current flow units from preference service
  String _getCurrentFlowUnit() {
    final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;
    return currentUnit == 'CMS' ? 'CMS' : 'CFS';
  }

  @override
  Widget build(BuildContext context) {
    final currentUnit = _getCurrentFlowUnit();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            // Day label
            SizedBox(
              width: 60,
              child: Text(
                DailyForecastProcessor.getDayLabel(
                  forecast.date,
                  isToday: isToday,
                ),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Flow icon
            FlowConditionIcon(flowCategory: forecast.flowCategory, size: 20),

            const SizedBox(width: 12),

            // Range bar
            Expanded(
              child: CompactFlowRangeBar(
                forecast: forecast,
                minFlowBound: minFlowBound,
                maxFlowBound: maxFlowBound,
              ),
            ),

            const SizedBox(width: 8),

            // ✅ UPDATED: Max flow with unit
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: _formatFlow(forecast.maxFlow),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: CupertinoColors.label,
                    ),
                  ),
                  TextSpan(
                    text: ' $currentUnit',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w400,
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatFlow(double flow) {
    if (flow >= 1000) {
      return '${(flow / 1000).toStringAsFixed(1)}K';
    } else {
      return flow.toStringAsFixed(0);
    }
  }
}
