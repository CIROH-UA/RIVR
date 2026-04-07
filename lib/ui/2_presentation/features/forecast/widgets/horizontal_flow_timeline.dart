// lib/ui/2_presentation/features/forecast/widgets/horizontal_flow_timeline.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';

class HorizontalFlowTimeline extends StatefulWidget {
  final String reachId;
  final double height;
  final EdgeInsets? padding;

  const HorizontalFlowTimeline({
    super.key,
    required this.reachId,
    this.height = 140,
    this.padding,
  });

  @override
  State<HorizontalFlowTimeline> createState() => _HorizontalFlowTimelineState();
}

class _HorizontalFlowTimelineState extends State<HorizontalFlowTimeline> {
  ScrollController? _scrollController;
  String _lastKnownUnit = 'ft³/s';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _lastKnownUnit = _getCurrentFlowUnit();
  }

  @override
  void dispose() {
    _scrollController?.dispose();
    super.dispose();
  }

  // Get current flow unit display label from preference service
  String _getCurrentFlowUnit() {
    return GetIt.I<IFlowUnitPreferenceService>().getDisplayUnit();
  }

  // REMOVED: _convertFlowToCurrentUnit() - no longer needed!
  // The NoaaApiService already converts all forecast data to preferred units

  // Check for unit changes and rebuild if necessary
  @override
  void didUpdateWidget(HorizontalFlowTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);

    final currentUnit = _getCurrentFlowUnit();
    final unitChanged = currentUnit != _lastKnownUnit;

    if (unitChanged) {
      AppLogger.debug('FlowTimeline', 'Unit changed from $_lastKnownUnit to $currentUnit - rebuilding');
      _lastKnownUnit = currentUnit;
      // Force rebuild by calling setState
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReachDataProvider>(
      builder: (context, reachProvider, child) {
        if (reachProvider.isLoading) {
          return _buildLoadingState();
        }

        if (!reachProvider.hasData) {
          return _buildEmptyState();
        }

        final shortRangeData = _extractShortRangeData(reachProvider);

        if (shortRangeData.isEmpty) {
          return _buildNoDataState();
        }

        return _buildHourCards(context, shortRangeData, reachProvider);
      },
    );
  }

  Widget _buildHourCards(
    BuildContext context,
    List<HourlyFlowDataPoint> data,
    ReachDataProvider reachProvider,
  ) {
    return SizedBox(
      height: widget.height,
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: widget.padding ?? const EdgeInsets.symmetric(horizontal: 0),
        itemCount: data.length,
        itemBuilder: (context, index) {
          final dataPoint = data[index];
          final isFirst = index == 0;
          final isLast = index == data.length - 1;

          return Padding(
            padding: EdgeInsets.only(
              right: isLast ? 0 : 12,
              left: isFirst ? 0 : 0,
            ),
            child: _buildHourCard(context, dataPoint, reachProvider),
          );
        },
      ),
    );
  }

  // FIXED: Use flow data directly (already converted by API service)
  Widget _buildHourCard(
    BuildContext context,
    HourlyFlowDataPoint dataPoint,
    ReachDataProvider reachProvider,
  ) {
    // Flow is already converted by NoaaApiService, no need to convert again
    final flowCategory = _getFlowCategory(dataPoint.flow, reachProvider);
    final categoryColor = _getCategoryColor(flowCategory);
    final isCurrentHour = _isCurrentOrNearCurrentHour(dataPoint.validTime);
    final trendPercentage = _calculateTrendPercentage(dataPoint);
    final currentUnit = _getCurrentFlowUnit(); // Get current unit

    return Container(
      width: 100,
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrentHour
              ? CupertinoColors.systemBlue
              : CupertinoColors.separator.resolveFrom(context),
          width: isCurrentHour ? 2 : 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time header with current indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isCurrentHour ? 'Now' : _formatLocalTime(dataPoint.validTime),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isCurrentHour
                        ? CupertinoColors.systemBlue
                        : CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                if (isCurrentHour)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: CupertinoColors.systemBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 8),

            // FIXED: Flow value (already converted)
            Text(
              _formatFlow(dataPoint.flow),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),

            // Unit text with proper dark mode support
            Text(
              currentUnit,
              style: TextStyle(
                fontSize: 11,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),

            const SizedBox(height: 8),

            // Flow category indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: categoryColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                flowCategory,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: categoryColor,
                ),
              ),
            ),

            // Trend indicator with percentage
            const Spacer(),
            if (dataPoint.trend != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _getTrendIcon(dataPoint.trend!),
                    size: 12,
                    color: _getTrendColor(dataPoint.trend!),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    trendPercentage != null
                        ? '${trendPercentage.toStringAsFixed(0)}%'
                        : _formatTrend(dataPoint.trend!),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: _getTrendColor(dataPoint.trend!),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // FIXED: Data extraction method without conversion (data already converted by API service)
  List<HourlyFlowDataPoint> _extractShortRangeData(
    ReachDataProvider reachProvider,
  ) {
    final data = reachProvider.getShortRangeHourlyData();

    // FIXED: No conversion needed - data is already in user's preferred unit from API service
    return data.map((point) {
      return HourlyFlowDataPoint(
        validTime: point.validTime,
        flow: point.flow, // Already in correct unit from NoaaApiService
        trend: point.trend,
        trendPercentage: point.trendPercentage,
        confidence: point.confidence,
        metadata: point.metadata,
      );
    }).toList();
  }

  // FIXED: Flow category calculation (flow is already converted)
  String _getFlowCategory(
    double flow, // Already in user's preferred unit
    ReachDataProvider reachProvider,
  ) {
    if (!reachProvider.hasData) return 'Unknown';

    final reach = reachProvider.currentReach!;
    if (!reach.hasReturnPeriods) return 'Unknown';

    final currentUnit = _getCurrentFlowUnit();

    // Get return periods in the same unit as the flow
    final convertedReturnPeriods = reach.getReturnPeriodsInUnit(currentUnit, GetIt.I<IFlowUnitPreferenceService>());
    if (convertedReturnPeriods == null || convertedReturnPeriods.isEmpty) {
      return 'Unknown';
    }

    final periods = convertedReturnPeriods.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final period in periods) {
      if (flow < period.value) {
        if (period.key == 2) return 'Normal';
        if (period.key <= 5) return 'Elevated';
        return 'High';
      }
    }

    return 'Flood Risk';
  }

  Color _getCategoryColor(String category) {
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

  bool _isCurrentOrNearCurrentHour(DateTime dataTime) {
    final now = DateTime.now();
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);
    final dataHour = DateTime(
      dataTime.year,
      dataTime.month,
      dataTime.day,
      dataTime.hour,
    );

    return dataHour == currentHour; // Only match exact hour bucket
  }

  String _formatLocalTime(DateTime forecastTime) {
    // Convert to local device time if needed
    final localTime = forecastTime.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final forecastDay = DateTime(
      localTime.year,
      localTime.month,
      localTime.day,
    );

    if (forecastDay == today) {
      return '${localTime.hour.toString().padLeft(2, '0')}:00';
    } else if (forecastDay == today.add(const Duration(days: 1))) {
      return 'Tom\n${localTime.hour.toString().padLeft(2, '0')}:00';
    } else {
      return '${localTime.month}/${localTime.day}\n${localTime.hour.toString().padLeft(2, '0')}:00';
    }
  }

  double? _calculateTrendPercentage(HourlyFlowDataPoint dataPoint) {
    return dataPoint.trendPercentage;
  }

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

  IconData _getTrendIcon(FlowTrend trend) {
    switch (trend) {
      case FlowTrend.rising:
        return CupertinoIcons.arrow_up;
      case FlowTrend.falling:
        return CupertinoIcons.arrow_down;
      case FlowTrend.stable:
        return CupertinoIcons.arrow_right;
    }
  }

  Color _getTrendColor(FlowTrend trend) {
    switch (trend) {
      case FlowTrend.rising:
        return CupertinoColors.systemGreen;
      case FlowTrend.falling:
        return CupertinoColors.systemRed;
      case FlowTrend.stable:
        return CupertinoColors.systemGrey;
    }
  }

  String _formatTrend(FlowTrend trend) {
    switch (trend) {
      case FlowTrend.rising:
        return 'Rising';
      case FlowTrend.falling:
        return 'Falling';
      case FlowTrend.stable:
        return 'Stable';
    }
  }

  // Loading and error states
  Widget _buildLoadingState() {
    return SizedBox(
      height: widget.height,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: widget.padding ?? const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 6,
        itemBuilder: (context, index) {
          return Padding(
            padding: EdgeInsets.only(right: index == 5 ? 0 : 12),
            child: _buildLoadingCard(),
          );
        },
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      width: 100,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(child: CupertinoActivityIndicator(radius: 12)),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.chart_bar,
              size: 32,
              color: CupertinoColors.systemGrey,
            ),
            SizedBox(height: 8),
            Text(
              'No hourly data',
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

  Widget _buildNoDataState() {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 32,
              color: CupertinoColors.systemOrange,
            ),
            SizedBox(height: 8),
            Text(
              'No short range data available',
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
}

