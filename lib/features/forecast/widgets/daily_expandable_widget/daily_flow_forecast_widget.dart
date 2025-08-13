// lib/features/forecast/widgets/daily_expandable_widget/daily_flow_forecast_widget.dart

import 'package:flutter/cupertino.dart';
import 'package:rivrflow/core/models/reach_data.dart';
import 'package:rivrflow/core/services/flow_unit_preference_service.dart';
import '../../domain/entities/daily_flow_forecast.dart';
import '../../services/daily_forecast_processor.dart';
import 'daily_forecast_row.dart';

/// Main widget that displays daily flow forecasts in expandable rows
///
/// Processes ensemble forecast data into daily summaries and displays them
/// in a clean, card-style container with Cupertino styling. Handles loading,
/// error, and empty states with proper user feedback.
class DailyFlowForecastWidget extends StatefulWidget {
  /// The forecast response containing ensemble data
  final ForecastResponse? forecastResponse;

  /// Type of forecast to display ('medium_range' or 'long_range')
  final String forecastType;

  /// Optional refresh callback
  final VoidCallback? onRefresh;

  /// Whether to allow multiple rows expanded simultaneously
  final bool allowMultipleExpanded;

  /// Custom title override
  final String? customTitle;

  /// Height constraint for the widget
  final double? maxHeight;

  const DailyFlowForecastWidget({
    super.key,
    required this.forecastResponse,
    required this.forecastType,
    this.onRefresh,
    this.allowMultipleExpanded = false,
    this.customTitle,
    this.maxHeight,
  });

  @override
  State<DailyFlowForecastWidget> createState() =>
      _DailyFlowForecastWidgetState();
}

class _DailyFlowForecastWidgetState extends State<DailyFlowForecastWidget> {
  List<DailyFlowForecast> _dailyForecasts = [];
  Map<String, double> _flowBounds = {'min': 0, 'max': 100};
  int? _expandedIndex;
  bool _isProcessing = false;
  String? _errorMessage;
  String _lastKnownUnit = 'CFS'; // Track unit changes

  // Get current flow units from preference service
  String _getCurrentFlowUnit() {
    final currentUnit = FlowUnitPreferenceService().currentFlowUnit;
    return currentUnit == 'CMS' ? 'CMS' : 'CFS';
  }

  @override
  void initState() {
    super.initState();
    _lastKnownUnit = _getCurrentFlowUnit(); // Initialize unit tracking
    _processData();
  }

  @override
  void didUpdateWidget(DailyFlowForecastWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Check for unit changes
    final currentUnit = _getCurrentFlowUnit();
    final unitChanged = currentUnit != _lastKnownUnit;

    if (oldWidget.forecastResponse != widget.forecastResponse ||
        oldWidget.forecastType != widget.forecastType ||
        unitChanged) {
      // React to unit changes

      if (unitChanged) {
        print(
          'DAILY_WIDGET: Unit changed from $_lastKnownUnit to $currentUnit - reprocessing data',
        );
        _lastKnownUnit = currentUnit; // Update tracked unit
      }

      _processData();
    }
  }

  /// Process forecast data into daily summaries
  void _processData() {
    if (widget.forecastResponse == null) {
      setState(() {
        _errorMessage = 'No forecast data available';
        _isProcessing = false;
        _dailyForecasts = [];
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      // Get current unit for display purposes
      final currentUnit = _getCurrentFlowUnit();

      // Process the forecast data based on type
      List<DailyFlowForecast> dailyForecasts;

      if (widget.forecastType.toLowerCase() == 'medium_range') {
        dailyForecasts = DailyForecastProcessor.processMediumRange(
          forecastResponse: widget.forecastResponse!,
        );
      } else if (widget.forecastType.toLowerCase() == 'long_range') {
        dailyForecasts = DailyForecastProcessor.processLongRange(
          forecastResponse: widget.forecastResponse!,
        );
      } else {
        // Generic processing for custom forecast types
        final forecastData = widget.forecastType.toLowerCase() == 'medium_range'
            ? widget.forecastResponse!.mediumRange
            : widget.forecastResponse!.longRange;

        dailyForecasts = DailyForecastProcessor.processForecastData(
          forecastData: forecastData,
          reach: widget.forecastResponse!.reach,
          forecastType: widget.forecastType,
        );
      }

      // Calculate flow bounds for consistent scaling
      final flowBounds = DailyForecastProcessor.getFlowBounds(dailyForecasts);

      // Print processing summary for debugging
      DailyForecastProcessor.printProcessingSummary(
        dailyForecasts,
        currentUnit,
      );

      setState(() {
        _dailyForecasts = dailyForecasts;
        _flowBounds = flowBounds;
        _isProcessing = false;
      });
    } catch (e) {
      print('DAILY_WIDGET: Error processing forecast data: $e');
      setState(() {
        _errorMessage = 'Error processing forecast data: $e';
        _isProcessing = false;
      });
    }
  }

  /// Handle row expansion changes
  void _handleExpansionChanged(int index, bool isExpanded) {
    setState(() {
      if (widget.allowMultipleExpanded) {
        // Multiple expansion mode - not implemented in this version
        // Could track Set<int> of expanded indices
      } else {
        // Single expansion mode
        if (isExpanded) {
          _expandedIndex = index;
        } else if (_expandedIndex == index) {
          _expandedIndex = null;
        }
      }
    });
  }

  /// Check if a date represents today
  bool _isToday(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final checkDate = DateTime(date.year, date.month, date.day);
    return checkDate == today;
  }

  /// Get widget title
  String _getTitle() {
    if (widget.customTitle != null) return widget.customTitle!;

    final count = _dailyForecasts.length;
    final type = widget.forecastType.toLowerCase();

    if (type == 'medium_range') {
      return '$count-Day Forecast';
    } else if (type == 'long_range') {
      return '$count-Day Long Range Forecast';
    } else {
      return '$count-Day Flow Forecast';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);

    // Main container with card styling
    Widget content = Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          _buildHeader(context),

          // Content area
          if (_isProcessing)
            _buildLoadingState(context)
          else if (_errorMessage != null)
            _buildErrorState(context)
          else if (_dailyForecasts.isEmpty)
            _buildEmptyState(context)
          else
            _buildForecastList(context),
        ],
      ),
    );

    // Apply height constraint if specified
    if (widget.maxHeight != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: content,
      );
    }

    return content;
  }

  /// Build the header section
  Widget _buildHeader(BuildContext context) {
    final theme = CupertinoTheme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6
            .resolveFrom(context)
            .withOpacity(0.3),
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _getTitle(),
              style: theme.textTheme.navTitleTextStyle.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          // Data source indicator
          if (_dailyForecasts.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _dailyForecasts.first.isUsingMeanData
                    ? CupertinoColors.systemBlue.withOpacity(0.15)
                    : CupertinoColors.systemOrange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _dailyForecasts.first.isUsingMeanData ? 'Mean' : 'Member',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: _dailyForecasts.first.isUsingMeanData
                      ? CupertinoColors.systemBlue
                      : CupertinoColors.systemOrange,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Build loading state
  Widget _buildLoadingState(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 16),
            const SizedBox(height: 12),
            Text(
              'Processing forecast data...',
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build error state
  Widget _buildErrorState(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 48,
              color: CupertinoColors.systemRed.resolveFrom(context),
            ),
            const SizedBox(height: 12),
            Text(
              'Error Loading Data',
              style: CupertinoTheme.of(context).textTheme.navTitleTextStyle
                  .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            if (widget.onRefresh != null) ...[
              const SizedBox(height: 16),
              CupertinoButton(
                onPressed: widget.onRefresh,
                child: const Text('Try Again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Build empty state
  Widget _buildEmptyState(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.calendar,
              size: 48,
              color: CupertinoColors.systemGrey2.resolveFrom(context),
            ),
            const SizedBox(height: 12),
            Text(
              'No Forecast Data',
              style: CupertinoTheme.of(context).textTheme.navTitleTextStyle
                  .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'No daily forecast data is available for this location\nat the moment.',
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            if (widget.onRefresh != null) ...[
              const SizedBox(height: 16),
              CupertinoButton(
                onPressed: widget.onRefresh,
                child: const Text('Refresh'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Build the list of forecast rows
  Widget _buildForecastList(BuildContext context) {
    return Flexible(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: List.generate(_dailyForecasts.length, (index) {
            final forecast = _dailyForecasts[index];
            final isToday = _isToday(forecast.date);
            final isLastRow = index == _dailyForecasts.length - 1;
            final isExpanded = _expandedIndex == index;

            return DailyForecastRow(
              forecast: forecast,
              minFlowBound: _flowBounds['min']!,
              maxFlowBound: _flowBounds['max']!,
              isToday: isToday,
              reach: widget.forecastResponse?.reach,
              initiallyExpanded: isExpanded,
              onExpansionChanged: (expanded) =>
                  _handleExpansionChanged(index, expanded),
              isLastRow: isLastRow,
            );
          }),
        ),
      ),
    );
  }
}

/// Simplified version for quick display without expansion
class SimpleDailyFlowForecastWidget extends StatelessWidget {
  final ForecastResponse? forecastResponse;
  final String forecastType;
  final int? maxRows;
  final VoidCallback? onViewMore;

  const SimpleDailyFlowForecastWidget({
    super.key,
    required this.forecastResponse,
    required this.forecastType,
    this.maxRows = 5,
    this.onViewMore,
  });

  @override
  Widget build(BuildContext context) {
    if (forecastResponse == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        child: const Text('No forecast data available'),
      );
    }

    // Process data with manual unit conversion in DailyForecastProcessor
    List<DailyFlowForecast> dailyForecasts;
    if (forecastType.toLowerCase() == 'medium_range') {
      dailyForecasts = DailyForecastProcessor.processMediumRange(
        forecastResponse: forecastResponse!,
      );
    } else {
      dailyForecasts = DailyForecastProcessor.processLongRange(
        forecastResponse: forecastResponse!,
      );
    }

    if (dailyForecasts.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        child: const Text('No daily forecasts available'),
      );
    }

    // Limit rows if specified
    final displayForecasts = maxRows != null && dailyForecasts.length > maxRows!
        ? dailyForecasts.take(maxRows!).toList()
        : dailyForecasts;

    final flowBounds = DailyForecastProcessor.getFlowBounds(displayForecasts);

    return Column(
      children: [
        ...displayForecasts.asMap().entries.map((entry) {
          final forecast = entry.value;
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final forecastDate = DateTime(
            forecast.date.year,
            forecast.date.month,
            forecast.date.day,
          );
          final isToday = forecastDate == today;

          return CompactDailyForecastRow(
            forecast: forecast,
            minFlowBound: flowBounds['min']!,
            maxFlowBound: flowBounds['max']!,
            isToday: isToday,
            reach: forecastResponse?.reach,
            onTap: onViewMore,
          );
        }),

        // View more button
        if (maxRows != null &&
            dailyForecasts.length > maxRows! &&
            onViewMore != null)
          CupertinoButton(
            onPressed: onViewMore,
            child: Text('View ${dailyForecasts.length - maxRows!} more days'),
          ),
      ],
    );
  }
}
