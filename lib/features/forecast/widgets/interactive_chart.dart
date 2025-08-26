// lib/features/forecast/widgets/interactive_chart.dart

import 'package:flutter/cupertino.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'dart:math' as math;
import '../../../core/providers/reach_data_provider.dart';
import '../../../core/constants.dart';
import '../../../core/services/forecast_service.dart';
import '../../../core/services/flow_unit_preference_service.dart';

// Simple controller for chart interactions
class ChartController {
  VoidCallback? _resetZoom;

  void _setResetCallback(VoidCallback callback) {
    _resetZoom = callback;
  }

  void resetZoom() {
    _resetZoom?.call();
  }
}

class InteractiveChart extends StatefulWidget {
  final String reachId;
  final String forecastType;
  final bool showReturnPeriods;
  final bool showTooltips;
  final bool showEnsembleMembers; // Toggle for ensemble display
  final ReachDataProvider reachProvider;
  final ChartController? controller;

  const InteractiveChart({
    super.key,
    required this.reachId,
    required this.forecastType,
    required this.showReturnPeriods,
    required this.showTooltips,
    this.showEnsembleMembers = false, // Default to false
    required this.reachProvider,
    this.controller,
  });

  @override
  State<InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<InteractiveChart> {
  double _minX = 0;
  double _maxX = 0;
  double _minY = 0;
  double _maxY = 0;
  bool _isInitialized = false;
  List<ChartData> _chartData =
      []; // Keep for backward compatibility (mean line)
  List<ChartDataPoint> _forecastData = [];
  String _lastKnownUnit = 'CFS'; // Track unit changes

  // Store ensemble data for multiple series
  Map<String, List<ChartData>> _ensembleChartData = {};
  final ForecastService _forecastService = ForecastService();

  // Color palette for ensemble members
  static const List<Color> _ensembleColors = [
    CupertinoColors.systemOrange,
    CupertinoColors.systemPurple,
    CupertinoColors.systemTeal,
    CupertinoColors.systemIndigo,
    CupertinoColors.systemPink,
    CupertinoColors.systemYellow,
    CupertinoColors.systemBrown,
  ];

  // User interaction behaviors
  late TrackballBehavior _trackballBehavior;
  late CrosshairBehavior _crosshairBehavior;
  late ZoomPanBehavior _zoomPanBehavior;
  late TooltipBehavior _tooltipBehavior;

  // Get current flow units from preference service
  String _getCurrentFlowUnit() {
    final currentUnit = FlowUnitPreferenceService().currentFlowUnit;
    return currentUnit == 'CMS' ? 'CMS' : 'CFS';
  }

  // REMOVED: _convertFlowToCurrentUnit() - no longer needed!
  // The NoaaApiService already converts all forecast data to preferred units

  @override
  void initState() {
    super.initState();
    _lastKnownUnit = _getCurrentFlowUnit(); // Initialize unit tracking
    _initializeChart();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initializeBehaviors();

    // Set up controller callback if provided
    widget.controller?._setResetCallback(() {
      _zoomPanBehavior.reset();
    });
  }

  @override
  void didUpdateWidget(InteractiveChart oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Check for unit changes
    final currentUnit = _getCurrentFlowUnit();
    final unitChanged = currentUnit != _lastKnownUnit;

    if (oldWidget.forecastType != widget.forecastType ||
        oldWidget.showReturnPeriods != widget.showReturnPeriods ||
        oldWidget.showEnsembleMembers != widget.showEnsembleMembers ||
        unitChanged) {
      // React to unit changes

      if (unitChanged) {
        print(
          'INTERACTIVE_CHART: Unit changed from $_lastKnownUnit to $currentUnit - refreshing chart',
        );
        _lastKnownUnit = currentUnit; // Update tracked unit
      }

      _initializeChart();
    }
    if (oldWidget.showTooltips != widget.showTooltips || unitChanged) {
      // Update tooltips on unit change
      _initializeBehaviors();
    }
  }

  void _initializeBehaviors() {
    final currentUnit = _getCurrentFlowUnit(); // Get current unit

    // Trackball - Shows tooltip for nearest data point
    _trackballBehavior = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      lineColor: CupertinoColors.systemGrey,
      lineWidth: 1,
      lineDashArray: [8, 4],
      shouldAlwaysShow: false,
      hideDelay: 3000,
      tooltipDisplayMode: TrackballDisplayMode.nearestPoint,
      tooltipAlignment: ChartAlignment.near,
      tooltipSettings: InteractiveTooltip(
        enable: true,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderColor: CupertinoColors.separator.resolveFrom(context),
        borderWidth: 1,
        format: 'point.y $currentUnit', // Dynamic unit display
        textStyle: TextStyle(
          color: CupertinoColors.label.resolveFrom(context),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        canShowMarker: true,
      ),
      markerSettings: TrackballMarkerSettings(
        markerVisibility: TrackballVisibilityMode.visible,
        width: 8,
        height: 8,
        color: CupertinoColors.systemBlue,
        borderColor: CupertinoColors.white,
        borderWidth: 2,
      ),
    );

    // Crosshair - Shows axis values with cross lines
    _crosshairBehavior = CrosshairBehavior(
      enable: true,
      activationMode: ActivationMode.longPress,
      lineType: CrosshairLineType.both,
      lineColor: CupertinoColors.systemGrey2,
      lineWidth: 1,
      lineDashArray: [5, 5],
      shouldAlwaysShow: false,
      hideDelay: 3000,
    );

    // Enhanced zoom and pan behavior
    _zoomPanBehavior = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableSelectionZooming: true,
      enableMouseWheelZooming: true,
      enableDirectionalZooming: true,
      zoomMode: ZoomMode.xy,
      maximumZoomLevel: 0.01,
      selectionRectBorderWidth: 2,
      selectionRectBorderColor: CupertinoColors.systemBlue,
      selectionRectColor: CupertinoColors.systemBlue.withOpacity(0.2),
    );

    // Enhanced tooltip behavior
    _tooltipBehavior = TooltipBehavior(
      enable: widget.showTooltips,
      color: CupertinoColors.systemBackground.resolveFrom(context),
      borderColor: CupertinoColors.separator.resolveFrom(context),
      borderWidth: 1,
      opacity: 0.9,
      format: 'point.y $currentUnit', // Dynamic unit display
      textStyle: TextStyle(
        color: CupertinoColors.label.resolveFrom(context),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      animationDuration: 300,
      canShowMarker: true,
    );
  }

  void _initializeChart() {
    _extractChartData();

    // ONLY proceed if we actually have forecast data
    if (_forecastData.isEmpty && _ensembleChartData.isEmpty) {
      setState(() {
        _isInitialized = false; // Mark as not ready
      });
      return;
    }

    _calculateAxisBounds();

    setState(() {
      _isInitialized = true; // Now we're truly ready
    });
  }

  void _extractChartData() {
    if (!widget.reachProvider.hasData) {
      _chartData = [];
      _forecastData = [];
      _ensembleChartData = {};
      return;
    }

    // Check if we should load ensemble data
    if (widget.showEnsembleMembers &&
        (widget.forecastType == 'medium_range' ||
            widget.forecastType == 'long_range')) {
      _loadEnsembleData();
    } else {
      // Load single series (existing logic)
      _forecastData = _getForecastData();
      _chartData = _convertToChartData(_forecastData);
      _ensembleChartData = {}; // Clear ensemble data
    }
  }

  // FIXED: Load ensemble data using already-converted values
  void _loadEnsembleData() {
    final forecast = widget.reachProvider.currentForecast;
    if (forecast == null) {
      _ensembleChartData = {};
      _forecastData = [];
      _chartData = [];
      return;
    }

    // Use forecast service to get ensemble data
    final ensembleData = _forecastService.getEnsembleSeriesForChart(
      forecast,
      widget.forecastType,
    );

    if (ensembleData.isEmpty) {
      _ensembleChartData = {};
      _forecastData = [];
      _chartData = [];
      return;
    }

    // FIXED: Convert between different ChartData types WITHOUT unit conversion
    _ensembleChartData = {};
    for (final entry in ensembleData.entries) {
      final memberName = entry.key;
      final serviceChartData = entry.value;

      // FIXED: Use flow values directly (already converted by API service)
      final convertedData = serviceChartData.map((point) {
        return ChartData(point.x, point.y); // Use values directly
      }).toList();

      _ensembleChartData[memberName] = convertedData;
    }

    // FIXED: Convert between different ChartDataPoint types WITHOUT unit conversion
    final serviceReferenceData = _forecastService.getEnsembleReferenceData(
      forecast,
      widget.forecastType,
    );

    // FIXED: Use flow values directly (already converted by API service)
    _forecastData = serviceReferenceData.map((point) {
      return ChartDataPoint(
        time: point.time,
        flow: point.flow, // Use flow directly (already converted)
        confidence: point.confidence,
        metadata: point.metadata,
      );
    }).toList();

    // Clear single series data when showing ensemble
    _chartData = [];

    print(
      'INTERACTIVE_CHART: Loaded ${_ensembleChartData.length} ensemble series (using already-converted values)',
    );
  }

  // FIXED: Get forecast data using already-converted values
  List<ChartDataPoint> _getForecastData() {
    final forecast = widget.reachProvider.currentForecast;
    if (forecast == null) return [];

    // Use real API data instead of mock data
    if (widget.forecastType == 'short_range') {
      final forecastSeries = forecast.getPrimaryForecast('short_range');
      if (forecastSeries == null || forecastSeries.isEmpty) return [];

      // FIXED: Use ALL data points without conversion (already converted by API service)
      return forecastSeries.data.map((point) {
        return ChartDataPoint(
          time: point.validTime.toLocal(),
          flow: point.flow, // Use flow directly (already converted)
        );
      }).toList();
    }

    // FIXED: For other forecast types, use already-converted data
    final forecastSeries = forecast.getPrimaryForecast(widget.forecastType);
    if (forecastSeries == null || forecastSeries.isEmpty) return [];

    return forecastSeries.data.map((point) {
      return ChartDataPoint(
        time: point.validTime.toLocal(),
        flow: point.flow, // Use flow directly (already converted)
      );
    }).toList();
  }

  List<ChartData> _convertToChartData(List<ChartDataPoint> data) {
    if (data.isEmpty) return [];

    // Find the earliest time as reference point
    final earliestTime = data
        .map((d) => d.time)
        .reduce((a, b) => a.isBefore(b) ? a : b);

    return data.map((point) {
      // Convert to hours since the earliest time
      final hoursSinceStart =
          point.time.difference(earliestTime).inMinutes / 60.0;
      return ChartData(hoursSinceStart, point.flow); // Flow already converted
    }).toList();
  }

  void _calculateAxisBounds() {
    // Determine data source for bounds calculation
    List<ChartData> boundsData;
    if (_ensembleChartData.isNotEmpty) {
      // Use all ensemble data for bounds calculation
      boundsData = [];
      for (final series in _ensembleChartData.values) {
        boundsData.addAll(series);
      }
    } else {
      boundsData = _chartData;
    }

    if (boundsData.isEmpty) {
      _minX = 0;
      _maxX = 24;
      _minY = 0;
      _maxY = 500;
      return;
    }

    _minX = boundsData.map((data) => data.x).reduce(math.min);
    _maxX = boundsData.map((data) => data.x).reduce(math.max);
    _minY = boundsData.map((data) => data.y).reduce(math.min);
    _maxY = boundsData.map((data) => data.y).reduce(math.max);

    // Only include return periods in bounds when toggle is ON
    if (widget.showReturnPeriods && widget.reachProvider.hasData) {
      final reach = widget.reachProvider.currentReach;
      if (reach?.returnPeriods != null) {
        final currentUnit = _getCurrentFlowUnit();

        // Get return periods in current unit using reach method
        final convertedReturnPeriods = reach!.getReturnPeriodsInUnit(
          currentUnit,
        );
        if (convertedReturnPeriods != null &&
            convertedReturnPeriods.isNotEmpty) {
          // When return periods are ON, include them in bounds (expected scaling down)
          for (final value in convertedReturnPeriods.values) {
            if (value > _maxY) _maxY = value;
            if (value < _minY) _minY = value;
          }
          print(
            'DEBUG: Return periods included in bounds - Y: $_minY to $_maxY',
          );
        }
      }
    }

    // Add generous padding for better visualization
    final yRange = _maxY - _minY;
    final xRange = _maxX - _minX;

    // When return periods are OFF, give generous padding for flow data focus
    // When return periods are ON, use smaller padding since we want to see everything
    final paddingMultiplier = widget.showReturnPeriods ? 0.1 : 0.2;

    _minY = _minY - yRange * paddingMultiplier;
    _maxY = _maxY + yRange * paddingMultiplier;

    // Only force minimum to 0 if we're actually near 0
    if (_minY < 0 && _minY > -(yRange * 0.1)) {
      _minY = 0;
    }

    // X-axis padding
    _minX = _minX - xRange * 0.02;
    _maxX = _maxX + xRange * 0.02;

    final mode = widget.showReturnPeriods
        ? 'with return periods'
        : 'flow data only';
    print(
      'DEBUG: Chart bounds ($mode) - Y: $_minY to $_maxY (range: ${(_maxY - _minY).toStringAsFixed(1)})',
    );
  }

  // Build chart series based on current mode
  List<CartesianSeries> _buildChartSeries() {
    final seriesList = <CartesianSeries>[];

    if (_ensembleChartData.isNotEmpty) {
      // Ensemble mode: Show mean + members

      // Add member lines first (so they appear behind mean)
      for (final entry in _ensembleChartData.entries) {
        final memberName = entry.key;
        final memberData = entry.value;

        if (memberName.startsWith('member')) {
          seriesList.add(
            LineSeries<ChartData, double>(
              dataSource: memberData,
              xValueMapper: (ChartData data, _) => data.x,
              yValueMapper: (ChartData data, _) => data.y,
              name: memberName,
              color: _getEnsembleColor(memberName),
              // Muted member lines
              width: 1.5, // Thinner than mean
              markerSettings: const MarkerSettings(
                isVisible: false,
              ), // No markers for members
              enableTrackball: false, // Don't show trackball for members
            ),
          );
        }
      }

      // Add mean line last (appears on top)
      if (_ensembleChartData.containsKey('mean')) {
        final meanData = _ensembleChartData['mean']!;
        seriesList.add(
          LineSeries<ChartData, double>(
            dataSource: meanData,
            xValueMapper: (ChartData data, _) => data.x,
            yValueMapper: (ChartData data, _) => data.y,
            name: 'Mean',
            color: CupertinoColors.systemBlue, // Prominent mean line
            width: 3, // Thick mean line
            markerSettings: MarkerSettings(
              isVisible: meanData.length <= 20,
              shape: DataMarkerType.circle,
              width: 6,
              height: 6,
              color: CupertinoColors.systemBlue,
              borderWidth: 2,
              borderColor: CupertinoColors.systemBackground.resolveFrom(
                context,
              ),
            ),
            enableTrackball: true, // Only mean line shows trackball
          ),
        );
      }
    } else {
      // Single series mode (existing logic)
      seriesList.add(
        LineSeries<ChartData, double>(
          dataSource: _chartData,
          xValueMapper: (ChartData data, _) => data.x,
          yValueMapper: (ChartData data, _) => data.y,
          color: CupertinoColors.systemBlue,
          width: 3,
          markerSettings: MarkerSettings(
            isVisible: _chartData.length <= 20,
            shape: DataMarkerType.circle,
            width: 6,
            height: 6,
            color: CupertinoColors.systemBlue,
            borderWidth: 2,
            borderColor: CupertinoColors.systemBackground.resolveFrom(context),
          ),
          selectionBehavior: SelectionBehavior(
            enable: true,
            selectedColor: CupertinoColors.systemOrange,
            unselectedColor: CupertinoColors.systemBlue.withOpacity(0.5),
            selectedBorderColor: CupertinoColors.systemRed,
            selectedBorderWidth: 2,
            toggleSelection: true,
          ),
          enableTrackball: true,
        ),
      );
    }

    return seriesList;
  }

  Color _getEnsembleColor(String memberName) {
    // Extract member number from memberName (e.g., "member_01" -> 1)
    final memberNumber =
        int.tryParse(memberName.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    return _ensembleColors[memberNumber % _ensembleColors.length].withOpacity(
      0.7,
    );
  }

  Widget _buildEnsembleLegend() {
    if (!widget.showEnsembleMembers || _ensembleChartData.isEmpty) {
      return const SizedBox.shrink();
    }

    final memberNames =
        _ensembleChartData.keys
            .where((key) => key.startsWith('member'))
            .toList()
          ..sort();

    return Positioned(
      top: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.systemGrey.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ...memberNames.take(6).map((memberName) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 2,
                      decoration: BoxDecoration(
                        color: _getEnsembleColor(memberName),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      memberName.replaceAll('member', 'Member '),
                      style: TextStyle(
                        fontSize: 10,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  List<PlotBand> _buildPlotBands() {
    if (!widget.showReturnPeriods || !widget.reachProvider.hasData) {
      return [];
    }

    final reach = widget.reachProvider.currentReach;
    if (reach?.returnPeriods == null) return [];

    final currentUnit = _getCurrentFlowUnit();

    // Get return periods in current unit using reach method
    final convertedReturnPeriods = reach!.getReturnPeriodsInUnit(currentUnit);
    if (convertedReturnPeriods == null || convertedReturnPeriods.isEmpty) {
      return [];
    }

    final plotBands = <PlotBand>[];

    // Normal zone (chart min to 2yr)
    final twoYearFlow = convertedReturnPeriods[2];
    if (twoYearFlow != null) {
      plotBands.add(
        AppConstants.createFloodZonePlotBand(_minY, twoYearFlow, 'normal'),
      );
    }

    // Action zone (2yr to 5yr)
    final fiveYearFlow = convertedReturnPeriods[5];
    if (twoYearFlow != null && fiveYearFlow != null) {
      plotBands.add(
        AppConstants.createFloodZonePlotBand(
          twoYearFlow,
          fiveYearFlow,
          'action',
        ),
      );
    }

    // Moderate zone (5yr to 10yr)
    final tenYearFlow = convertedReturnPeriods[10];
    if (fiveYearFlow != null && tenYearFlow != null) {
      plotBands.add(
        AppConstants.createFloodZonePlotBand(
          fiveYearFlow,
          tenYearFlow,
          'moderate',
        ),
      );
    }

    // Major zone (10yr to 25yr)
    final twentyFiveYearFlow = convertedReturnPeriods[25];
    if (tenYearFlow != null && twentyFiveYearFlow != null) {
      plotBands.add(
        AppConstants.createFloodZonePlotBand(
          tenYearFlow,
          twentyFiveYearFlow,
          'major',
        ),
      );
    }

    // Extreme zone (25yr to chart max)
    if (twentyFiveYearFlow != null) {
      plotBands.add(
        AppConstants.createFloodZonePlotBand(
          twentyFiveYearFlow,
          _maxY,
          'extreme',
        ),
      );
    }

    print('DEBUG: Added ${plotBands.length} plot bands ($currentUnit)');
    return plotBands;
  }

  List<PlotBand> _buildReturnPeriodLines() {
    if (!widget.showReturnPeriods || !widget.reachProvider.hasData) {
      return [];
    }

    final reach = widget.reachProvider.currentReach;
    if (reach?.returnPeriods == null) return [];

    final currentUnit = _getCurrentFlowUnit();

    // Get return periods in current unit using reach method
    final convertedReturnPeriods = reach!.getReturnPeriodsInUnit(currentUnit);
    if (convertedReturnPeriods == null || convertedReturnPeriods.isEmpty) {
      return [];
    }

    final lines = <PlotBand>[];
    final sortedEntries = convertedReturnPeriods.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // Define which years to show
    final yearsToShow = [5, 10, 25];

    for (final entry in sortedEntries) {
      final year = entry.key;

      // Only show lines for specified years
      if (yearsToShow.contains(year)) {
        final flowValue = entry.value; // Already converted to current unit
        final label = AppConstants.getReturnPeriodLabel(year);

        // Create a line (start == end) with label
        lines.add(
          PlotBand(
            start: flowValue,
            end: flowValue,
            borderColor: CupertinoColors.label,
            borderWidth: 0,
            dashArray: [5, 5],
            text: "$label\n",
            textStyle: const TextStyle(
              color: CupertinoColors.label,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            horizontalTextAlignment: TextAnchor.end,
          ),
        );
      }
    }

    return lines;
  }

  double? _getNowLinePosition() {
    if (widget.forecastType != 'short_range' || _forecastData.isEmpty) {
      return null;
    }

    final now = DateTime.now();
    final earliestTime = _forecastData
        .map((d) => d.time)
        .reduce((a, b) => a.isBefore(b) ? a : b);

    return now.difference(earliestTime).inMinutes / 60.0;
  }

  @override
  Widget build(BuildContext context) {
    // DON'T render chart until we have actual forecast data
    if (!_isInitialized ||
        (_chartData.isEmpty && _ensembleChartData.isEmpty) ||
        _forecastData.isEmpty) {
      return _buildEmptyChart();
    }

    final nowPosition = _getNowLinePosition();
    final currentUnit = _getCurrentFlowUnit(); // Get current unit

    return Container(
      padding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          SfCartesianChart(
            primaryXAxis: NumericAxis(
              minimum: _minX,
              maximum: _maxX,
              interval: (_maxX - _minX) / 6,
              title: AxisTitle(
                text: _getTimeAxisLabel(),
                textStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              axisLabelFormatter: (AxisLabelRenderDetails details) {
                return ChartAxisLabel(
                  _formatTimeValue(details.value.toDouble()),
                  TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                );
              },
              // Enable interactive tooltip for crosshair
              interactiveTooltip: InteractiveTooltip(
                enable: true,
                borderColor: CupertinoColors.systemBlue,
                borderWidth: 1,
                format: '{value}',
                textStyle: TextStyle(
                  color: CupertinoColors.label.resolveFrom(context),
                  fontSize: 11,
                ),
              ),
              plotBands: nowPosition != null
                  ? [
                      PlotBand(
                        start: nowPosition,
                        end: nowPosition,
                        borderColor: CupertinoColors.systemBrown,
                        borderWidth: 1.7,
                        dashArray: [2, 6],
                        text: 'Now\n',
                        textStyle: const TextStyle(
                          color: CupertinoColors.systemBrown,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        verticalTextAlignment: TextAnchor.start,
                      ),
                    ]
                  : [],
            ),
            primaryYAxis: NumericAxis(
              minimum: _minY,
              maximum: _maxY,
              interval: (_maxY - _minY) / 6,
              title: AxisTitle(
                text: 'Flow ($currentUnit)', // Dynamic unit display
                textStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              axisLabelFormatter: (AxisLabelRenderDetails details) {
                return ChartAxisLabel(
                  _formatFlowValue(details.value.toDouble()),
                  TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                );
              },
              // Enable interactive tooltip for crosshair
              interactiveTooltip: InteractiveTooltip(
                enable: true,
                borderColor: CupertinoColors.systemBlue,
                borderWidth: 1,
                format: '{value} $currentUnit', // Dynamic unit display
                textStyle: TextStyle(
                  color: CupertinoColors.label.resolveFrom(context),
                  fontSize: 11,
                ),
              ),
              plotBands: [..._buildPlotBands(), ..._buildReturnPeriodLines()],
            ),
            series: _buildChartSeries(), // Use dynamic series building
            // User interaction behaviors
            trackballBehavior: _trackballBehavior,
            crosshairBehavior: _crosshairBehavior,
            zoomPanBehavior: _zoomPanBehavior,
            tooltipBehavior: _tooltipBehavior,

            // Event callbacks for enhanced interactions
            onTrackballPositionChanging: (TrackballArgs args) {
              // Customize trackball display
              final flow = args.chartPointInfo.chartPoint?.y;
              final time = args.chartPointInfo.chartPoint?.x;
              if (flow != null && time != null) {
                args.chartPointInfo.label =
                    '${_formatFlowValue(flow.toDouble())} $currentUnit\n${_formatTimeValue(time)}'; // Dynamic unit display
              }
            },

            onCrosshairPositionChanging: (CrosshairRenderArgs args) {
              // Customize crosshair tooltip based on axis
              if (args.orientation == AxisOrientation.vertical) {
                args.text = _formatTimeValue(args.value);
              } else {
                args.text =
                    '${_formatFlowValue(args.value)} $currentUnit'; // Dynamic unit display
              }
            },

            onTooltipRender: (TooltipArgs args) {
              // Enhanced tooltip formatting
              // You can customize args.text here if needed
              // args.text = 'Custom: ${args.text}';
            },

            onSelectionChanged: (SelectionArgs args) {
              // Handle data point selection
              print('Selection changed');
            },

            onZooming: (ZoomPanArgs args) {
              // Handle zoom events
              print('Chart is being zoomed');
            },

            onActualRangeChanged: (ActualRangeChangedArgs args) {
              // Handle axis range changes during zoom/pan
              print('Axis range changed');
            },
          ),
          _buildEnsembleLegend(),
        ],
      ),
    );
  }

  Widget _buildEmptyChart() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.chart_bar,
            size: 48,
            color: CupertinoColors.systemGrey.resolveFrom(context),
          ),
          const SizedBox(height: 16),
          Text(
            'No chart data available',
            style: TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Check back later for updated forecasts',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFlowValue(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    } else if (value >= 100) {
      return value.toStringAsFixed(0);
    } else {
      return value.toStringAsFixed(1);
    }
  }

  String _formatTimeValue(double hoursSinceStart) {
    // For short_range, we MUST have forecast data to show correct times
    if (widget.forecastType == 'short_range') {
      if (_forecastData.isEmpty) {
        // Data not ready - don't render anything
        return '';
      }

      final earliestTime = _forecastData
          .map((d) => d.time)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final actualTime = earliestTime.add(
        Duration(minutes: (hoursSinceStart * 60).round()),
      );

      return '${actualTime.hour.toString().padLeft(2, '0')}:${(actualTime.minute ~/ 30 * 30).toString().padLeft(2, '0')}';
    }

    // For other forecast types
    if (widget.forecastType == 'medium_range') {
      final days = (hoursSinceStart / 24).round();
      return '${days}d';
    } else {
      final days = (hoursSinceStart / 24).round();
      final weeks = (days / 7).round();
      if (weeks > 0) return '${weeks}w';
      return '${days}d';
    }
  }

  String _getTimeAxisLabel() {
    switch (widget.forecastType) {
      case 'short_range':
        return 'Time of Day';
      case 'medium_range':
        return 'Days from now';
      case 'long_range':
        return 'Weeks from now';
      default:
        return 'Time';
    }
  }
}

// Data models for chart
class ChartDataPoint {
  final DateTime time;
  final double flow; // Already in user's preferred unit from API service
  final double? confidence;
  final Map<String, dynamic>? metadata;

  const ChartDataPoint({
    required this.time,
    required this.flow,
    this.confidence,
    this.metadata,
  });
}

// Simple data class for chart points
class ChartData {
  final double x;
  final double
  y; // Flow value already in user's preferred unit from API service

  ChartData(this.x, this.y);
}
