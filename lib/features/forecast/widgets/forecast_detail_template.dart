// lib/features/forecast/widgets/forecast_detail_template.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivrflow/core/services/flow_unit_preference_service.dart';
import 'package:rivrflow/features/forecast/widgets/horizontal_flow_timeline.dart';
import '../../../core/providers/reach_data_provider.dart';
import '../../../core/services/forecast_service.dart';
import 'current_flow_status_card.dart';
import 'flow_values_usage_guide.dart';

/// Enhanced forecast detail template that provides a consistent structure
/// while allowing each forecast type to use specialized widgets for optimal data display.
///
/// Specialized Timeline Widgets (to be developed):
/// - Short Range: HorizontalFlowTimeline - Hour cards + flow wave modes for 18 hours
/// - Medium Range: DailyFlowForecastWidgetWithHourly - Expandable daily rows for 10 days
/// - Long Range: LongRangeCalendar - Calendar grid with day cells for 30 days

class ForecastDetailTemplate extends StatefulWidget {
  // Required parameters
  final String reachId;
  final String forecastType;
  final String title;
  final List<UsageGuideOption> usageGuideOptions;

  // Existing optional parameters
  final VoidCallback? onChartTap;
  final Widget? additionalContent;
  final bool showCurrentFlow;
  final EdgeInsets? padding;

  // NEW: Custom widget parameters for enhanced flexibility
  final Widget? customHeaderWidget; // Optional custom header above usage guide
  final Widget?
  customTimelineWidget; // Replace FlowTimelineCards with specialized widget:
  // - HorizontalFlowTimeline (short range)
  // - DailyFlowForecastWidgetWithHourly (medium range)
  // - LongRangeCalendar (long range)
  final Widget?
  customChartPreview; // Replace ChartPreviewWidget with custom widget
  final Widget?
  customSummaryWidget; // Replace forecast summary with custom widget

  // NEW: Section visibility controls
  final bool showTimelineSection; // Show/hide entire timeline section
  final bool showChartSection; // Show/hide entire chart section
  final bool showForecastSummary; // Show/hide forecast summary section
  final bool showTimelineTitle; // Show/hide timeline section title

  // NEW: Section titles customization
  final String? timelineSectionTitle; // Custom title for timeline section:
  // - "Hourly Timeline" (short range)
  // - "10-Day Forecast" (medium range)
  // - "Monthly Calendar" (long range)
  final String? chartSectionTitle; // Custom title for chart section

  const ForecastDetailTemplate({
    super.key,
    // Required
    required this.reachId,
    required this.forecastType,
    required this.title,
    required this.usageGuideOptions,

    // Existing optional
    this.onChartTap,
    this.additionalContent,
    this.showCurrentFlow = true,
    this.padding,

    // Custom widgets
    this.customHeaderWidget,
    this.customTimelineWidget,
    this.customChartPreview,
    this.customSummaryWidget,

    // Section visibility
    this.showTimelineSection = true,
    this.showChartSection = true,
    this.showForecastSummary = true,
    this.showTimelineTitle =
        true, // Default to true to maintain existing behavior
    // Section titles
    this.timelineSectionTitle,
    this.chartSectionTitle,
  });

  @override
  State<ForecastDetailTemplate> createState() => _ForecastDetailTemplateState();
}

class _ForecastDetailTemplateState extends State<ForecastDetailTemplate> {
  bool _isRefreshing = false;
  final ForecastService _forecastService = ForecastService();

  @override
  void initState() {
    super.initState();
  }

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;

    setState(() {
      _isRefreshing = true;
    });

    try {
      final reachProvider = Provider.of<ReachDataProvider>(
        context,
        listen: false,
      );

      // Get current reach ID
      final currentReach = reachProvider.currentReach;
      if (currentReach == null) {
        print('FORECAST_TEMPLATE: No current reach for refresh');
        return;
      }

      final reachId = currentReach.reachId;
      print(
        'FORECAST_TEMPLATE: Refreshing ${widget.forecastType} for $reachId',
      );

      // Clear unit-dependent computed caches (flow values, categories)
      // but keep reach metadata cached
      reachProvider.clearUnitDependentCaches();

      // Call the appropriate forecast-specific refresh method
      // These methods will fetch fresh forecast data and merge with existing reach data
      bool success = false;
      switch (widget.forecastType.toLowerCase()) {
        case 'short_range':
          print('FORECAST_TEMPLATE: Refreshing hourly forecast data...');
          success = await reachProvider.loadHourlyForecast(reachId);
          break;

        case 'medium_range':
          print('FORECAST_TEMPLATE: Refreshing daily forecast data...');
          success = await reachProvider.loadDailyForecast(reachId);
          break;

        case 'long_range':
          print('FORECAST_TEMPLATE: Refreshing extended forecast data...');
          success = await reachProvider.loadExtendedForecast(reachId);
          break;

        case 'analysis_assimilation':
        case 'medium_range_blend':
          print(
            'FORECAST_TEMPLATE: Refreshing ${widget.forecastType} forecast data...',
          );
          success = await reachProvider.loadSpecificForecast(
            reachId,
            widget.forecastType,
          );
          break;

        default:
          print(
            'FORECAST_TEMPLATE: Unknown forecast type: ${widget.forecastType}, falling back to comprehensive refresh',
          );
          success = await reachProvider.refreshCurrentReach();
      }

      if (success) {
        print(
          'FORECAST_TEMPLATE: ✅ Successfully refreshed ${widget.forecastType} data',
        );
      } else {
        print(
          'FORECAST_TEMPLATE: ⚠️ Failed to refresh ${widget.forecastType} data',
        );
      }
    } catch (e) {
      print('FORECAST_TEMPLATE: ❌ Error refreshing ${widget.forecastType}: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  void _navigateToHydrograph() {
    Navigator.pushNamed(
      context,
      '/hydrograph',
      arguments: {
        'reachId': widget.reachId,
        'forecastType': widget.forecastType,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _isRefreshing ? null : _handleRefresh,
          child: _isRefreshing
              ? const CupertinoActivityIndicator(radius: 10)
              : const Icon(CupertinoIcons.refresh),
        ),
        backgroundColor: CupertinoColors.systemBackground.resolveFrom(context),
      ),
      child: SafeArea(
        child: Consumer<ReachDataProvider>(
          builder: (context, reachProvider, child) {
            if (reachProvider.isLoading && !reachProvider.hasData) {
              return _buildLoadingState();
            }

            if (reachProvider.errorMessage != null) {
              return _buildErrorState(reachProvider.errorMessage!);
            }

            if (!reachProvider.hasData) {
              return _buildEmptyState();
            }

            return _buildContent(reachProvider);
          },
        ),
      ),
    );
  }

  Widget _buildContent(ReachDataProvider reachProvider) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        // Current Flow Status (Mini Version)
        if (widget.showCurrentFlow)
          SliverToBoxAdapter(
            child: Padding(
              padding: widget.padding ?? const EdgeInsets.all(16),
              child: CurrentFlowStatusCard(
                expanded: false,
                onTap: _navigateToHydrograph,
              ),
            ),
          ),

        // Custom Header Widget (if provided)
        if (widget.customHeaderWidget != null)
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  widget.padding ?? const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  widget.customHeaderWidget!,
                ],
              ),
            ),
          ),

        // Timeline Section (customizable or hideable)
        // This section will use specialized widgets for each forecast type:
        // - Short Range: HorizontalFlowTimeline (hour cards + flow wave modes)
        // - Medium Range: DailyFlowForecastWidgetWithHourly (expandable daily rows)
        // - Long Range: LongRangeCalendar (calendar grid with day cells)
        if (widget.showTimelineSection)
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  widget.padding ?? const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Conditional spacing and title based on showTimelineTitle
                  if (widget.showTimelineTitle) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(_getTimelineSectionTitle()),
                  ] else ...[
                    const SizedBox(height: 12), // Reduced spacing when no title
                  ],

                  // Use custom timeline widget if provided, otherwise default
                  widget.customTimelineWidget ??
                      HorizontalFlowTimeline(reachId: widget.reachId),
                ],
              ),
            ),
          ),

        // Chart Preview Section (customizable or hideable)
        if (widget.showChartSection)
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  widget.padding ?? const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  // Use custom chart preview if provided, otherwise simple button
                  widget.customChartPreview ?? _buildChartButton(),
                ],
              ),
            ),
          ),

        // Forecast Summary Section (customizable or hideable)
        if (widget.showForecastSummary)
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  widget.padding ?? const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child:
                  widget.customSummaryWidget ??
                  _buildForecastSummary(reachProvider),
            ),
          ),

        // Additional Content (if provided) - always at the end
        if (widget.additionalContent != null)
          SliverToBoxAdapter(child: widget.additionalContent!),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

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

  String _getTimelineSectionTitle() {
    // Use custom title if provided, otherwise smart defaults based on forecast type
    if (widget.timelineSectionTitle != null) {
      return widget.timelineSectionTitle!;
    }

    switch (widget.forecastType) {
      case 'short_range':
        return 'Hourly Timeline';
      case 'medium_range':
        return 'Daily Forecast';
      case 'long_range':
        return 'Monthly Calendar';
      default:
        return 'Flow Timeline';
    }
  }

  String _getChartButtonText() {
    switch (widget.forecastType) {
      case 'short_range':
        return 'Hourly Flow Chart';
      case 'medium_range':
        return 'Daily Flow Chart';
      case 'long_range':
        return 'Extended Flow Chart';
      case 'analysis_assimilation':
        return 'Analysis Flow Chart';
      case 'medium_range_blend':
        return 'Blended Flow Chart';
      default:
        return 'Flow Chart';
    }
  }

  Widget _buildChartButton() {
    return CupertinoButton(
      onPressed: widget.onChartTap ?? _navigateToHydrograph,
      padding: EdgeInsets.zero,
      child: Container(
        width: double.infinity,
        height: 50,
        decoration: BoxDecoration(
          color: CupertinoColors.systemBlue.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: CupertinoColors.systemGrey4.resolveFrom(context),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _getChartButtonText(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.systemBackground.resolveFrom(context),
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                color: CupertinoColors.systemBackground.resolveFrom(context),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForecastSummary(ReachDataProvider reachProvider) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Forecast Summary',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 12),
          _buildSummaryMetrics(reachProvider),
        ],
      ),
    );
  }

  Widget _buildSummaryMetrics(ReachDataProvider reachProvider) {
    if (!reachProvider.hasData || reachProvider.currentForecast == null) {
      return _buildNoDataMetrics();
    }

    final forecast = reachProvider.currentForecast!;

    // Calculate real metrics from forecast data with unit conversion
    final peakFlow = _calculatePeakFlow(forecast);
    final currentTrend = _calculateCurrentTrend(forecast);
    final flowCategory = _forecastService.getFlowCategory(forecast);

    // Get current unit for display
    final unitService = FlowUnitPreferenceService();
    final currentUnit = unitService.currentFlowUnit;

    return Column(
      children: [
        _buildMetricRow(
          'Peak Flow',
          peakFlow != null
              ? '${peakFlow.toStringAsFixed(0)} $currentUnit'
              : 'N/A',
          CupertinoIcons.arrow_up,
        ),
        const SizedBox(height: 8),
        _buildMetricRow(
          'Current Trend',
          currentTrend,
          _getTrendIcon(currentTrend),
        ),
        const SizedBox(height: 8),
        _buildMetricRow(
          'Flow Level',
          flowCategory,
          _getCategoryIcon(flowCategory),
        ),
      ],
    );
  }

  Widget _buildNoDataMetrics() {
    return Column(
      children: [
        _buildMetricRow('Peak Flow', 'N/A', CupertinoIcons.arrow_up),
        const SizedBox(height: 8),
        _buildMetricRow('Current Trend', 'N/A', CupertinoIcons.arrow_right),
        const SizedBox(height: 8),
        _buildMetricRow('Flow Level', 'N/A', CupertinoIcons.drop),
        const SizedBox(height: 8),
        _buildMetricRow('Last Updated', 'N/A', CupertinoIcons.clock),
      ],
    );
  }

  double? _calculatePeakFlow(dynamic forecast) {
    try {
      // Get forecast data based on type
      final forecastSeries = forecast.getPrimaryForecast(widget.forecastType);
      if (forecastSeries == null || forecastSeries.isEmpty) return null;

      // Find the maximum flow value in the forecast period
      double maxFlow = forecastSeries.data.first.flow;
      for (final point in forecastSeries.data) {
        if (point.flow > maxFlow && point.flow > -9000) {
          // Filter out missing data
          maxFlow = point.flow;
        }
      }

      if (maxFlow <= -9000) return null;

      // ✅ FIXED: Convert from API units (CFS) to user preference
      final unitService = FlowUnitPreferenceService();
      final currentUnit = unitService.currentFlowUnit;

      return unitService.convertFlow(maxFlow, 'CFS', currentUnit);
    } catch (e) {
      print('Error calculating peak flow: $e');
      return null;
    }
  }

  String _calculateCurrentTrend(dynamic forecast) {
    try {
      final unitService = FlowUnitPreferenceService();
      final currentUnit = unitService.currentFlowUnit;

      // For short range, use hourly data to calculate trend
      if (widget.forecastType == 'short_range') {
        final hourlyData = _forecastService.getShortRangeHourlyData(forecast);
        if (hourlyData.length >= 3) {
          // Convert flow values to user preference for comparison
          final current = unitService.convertFlow(
            hourlyData[0].flow,
            'CFS',
            currentUnit,
          );
          final future1 = unitService.convertFlow(
            hourlyData[1].flow,
            'CFS',
            currentUnit,
          );
          final future2 = unitService.convertFlow(
            hourlyData[2].flow,
            'CFS',
            currentUnit,
          );

          final avgFuture = (future1 + future2) / 2;
          final change = avgFuture - current;

          // Use dynamic thresholds based on unit (CMS values are ~35x smaller)
          final threshold = currentUnit == 'CMS' ? 0.3 : 10.0;

          if (change > threshold) return 'Rising';
          if (change < -threshold) return 'Falling';
          return 'Stable';
        }
      }

      // For other forecast types, use first few data points
      final forecastSeries = forecast.getPrimaryForecast(widget.forecastType);
      if (forecastSeries != null && forecastSeries.data.length >= 3) {
        // Convert values for comparison
        final first = unitService.convertFlow(
          forecastSeries.data[0].flow,
          'CFS',
          currentUnit,
        );
        final third = unitService.convertFlow(
          forecastSeries.data[2].flow,
          'CFS',
          currentUnit,
        );
        final change = third - first;

        // Use dynamic thresholds based on unit
        final threshold = currentUnit == 'CMS' ? 0.6 : 20.0;

        if (change > threshold) return 'Rising';
        if (change < -threshold) return 'Falling';
        return 'Stable';
      }

      return 'Stable';
    } catch (e) {
      print('Error calculating trend: $e');
      return 'Unknown';
    }
  }

  IconData _getTrendIcon(String trend) {
    switch (trend.toLowerCase()) {
      case 'rising':
        return CupertinoIcons.arrow_up;
      case 'falling':
        return CupertinoIcons.arrow_down;
      case 'stable':
        return CupertinoIcons.arrow_right;
      default:
        return CupertinoIcons.minus;
    }
  }

  IconData _getCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'normal':
        return CupertinoIcons.drop;
      case 'elevated':
        return CupertinoIcons.drop_triangle;
      case 'high':
        return CupertinoIcons.exclamationmark_triangle;
      case 'flood risk':
        return CupertinoIcons.exclamationmark_triangle_fill;
      default:
        return CupertinoIcons.drop;
    }
  }

  Widget _buildMetricRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: CupertinoColors.systemBlue),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.secondaryLabel.resolveFrom(context), //
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CupertinoActivityIndicator(radius: 20),
          const SizedBox(height: 16),
          Text(
            'Loading ${widget.title.toLowerCase()}...',
            style: const TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 64,
              color: CupertinoColors.systemRed,
            ),
            const SizedBox(height: 16),
            const Text(
              'Unable to load forecast',
              style: TextStyle(
                fontSize: 18,
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
            const SizedBox(height: 24),
            CupertinoButton.filled(
              onPressed: _handleRefresh,
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.chart_bar,
              size: 64,
              color: CupertinoColors.systemGrey,
            ),
            const SizedBox(height: 16),
            Text(
              'No ${widget.title.toLowerCase()} data available',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Check back later for updated forecasts',
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.secondaryLabel,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            CupertinoButton(
              onPressed: _handleRefresh,
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}
