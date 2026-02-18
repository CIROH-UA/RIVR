// lib/features/forecast/pages/hydrograph_page.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:rivr/core/services/app_logger.dart';
import 'package:screenshot/screenshot.dart';
import 'package:rivr/features/forecast/utils/export_functionality.dart';
import '../../../core/providers/reach_data_provider.dart';
import '../../../core/services/forecast_service.dart'
    hide ChartDataPoint; // NEW: Add forecast service import
import '../widgets/interactive_chart.dart' hide ChartDataPoint;
import '../widgets/flood_categories_info_sheet.dart';

class HydrographPage extends StatefulWidget {
  final String? reachId;
  final String? forecastType;
  final String? title;

  const HydrographPage({
    super.key,
    this.reachId,
    this.forecastType,
    this.title,
  });

  @override
  State<HydrographPage> createState() => _HydrographPageState();
}

class _HydrographPageState extends State<HydrographPage> {
  String? _reachId;
  String? _forecastType;
  String? _pageTitle;
  bool _isInitialized = false;
  bool _showReturnPeriods = true;
  bool _showEnsembleMembers = false; // NEW: Add ensemble toggle state
  final bool _showTooltips = true;

  // Add ChartController to control chart interactions
  final ChartController _chartController = ChartController();

  // Add ScreenshotController for chart export
  final ScreenshotController _screenshotController = ScreenshotController();

  // NEW: Add forecast service
  final ForecastService _forecastService = ForecastService();

  @override
  void initState() {
    super.initState();
    _initializePage();
  }

  Future<void> _initializePage() async {
    // Get parameters from widget or navigation arguments
    _reachId = widget.reachId;
    _forecastType = widget.forecastType;
    _pageTitle = widget.title;

    if (_reachId == null || _forecastType == null) {
      // Try to get from navigation arguments
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final args =
            ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
        if (args != null) {
          setState(() {
            _reachId = args['reachId'] as String?;
            _forecastType = args['forecastType'] as String?;
            _pageTitle = args['title'] as String?;
          });
        }
        _loadData();
      });
    } else {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    if (_reachId == null || _forecastType == null) return;

    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );

    // Load reach data if not already available
    if (!reachProvider.hasData ||
        reachProvider.currentReach?.reachId != _reachId) {
      try {
        await reachProvider.loadReach(_reachId!);
      } catch (e) {
        // Error handling managed by provider
      }
    }

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  Future<void> _handleRefresh() async {
    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );
    await reachProvider.refreshCurrentReach();
  }

  void _toggleReturnPeriods() {
    setState(() {
      _showReturnPeriods = !_showReturnPeriods;
    });
  }

  // NEW: Add ensemble toggle method
  void _toggleEnsembleMembers() {
    setState(() {
      _showEnsembleMembers = !_showEnsembleMembers;
    });

    // Optional: Add haptic feedback
    HapticFeedback.lightImpact();
  }

  void _resetZoom() {
    // Call the reset method on the chart
    _chartController.resetZoom();
    HapticFeedback.lightImpact();
  }

  void _exportChart() {
    HapticFeedback.mediumImpact();

    showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        title: const Text('Export Chart'),
        message: const Text('Choose export option'),
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _shareChartImage();
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.share, size: 18),
                SizedBox(width: 8),
                Text('Share Chart'),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _saveChartToGallery();
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.photo, size: 18),
                SizedBox(width: 8),
                Text('Save to Photos'),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _exportDataAsCSV();
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.doc_text, size: 18),
                SizedBox(width: 8),
                Text('Export Data (CSV)'),
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  Future<void> _shareChartImage() async {
    try {
      final reachProvider = Provider.of<ReachDataProvider>(
        context,
        listen: false,
      );
      final reach = reachProvider.currentReach;

      if (reach == null) {
        ExportFunctionality.showErrorMessage(
          context,
          'No reach data available',
        );
        return;
      }

      // Use the new screenshot-based method
      await ExportFunctionality.shareChartImageFromController(
        screenshotController: _screenshotController,
        reachName: reach.displayName,
        forecastType: _forecastType!,
        context: context,
      );
    } catch (e) {
      ExportFunctionality.showErrorMessage(context, e.toString());
    }
  }

  Future<void> _saveChartToGallery() async {
    try {
      final reachProvider = Provider.of<ReachDataProvider>(
        context,
        listen: false,
      );
      final reach = reachProvider.currentReach;

      if (reach == null) {
        ExportFunctionality.showErrorMessage(
          context,
          'No reach data available',
        );
        return;
      }

      // Use the new screenshot-based method
      await ExportFunctionality.saveChartImageFromController(
        screenshotController: _screenshotController,
        reachName: reach.displayName,
        forecastType: _forecastType!,
        context: context,
      );
    } catch (e) {
      ExportFunctionality.showErrorMessage(context, e.toString());
    }
  }

  Future<void> _exportDataAsCSV() async {
    try {
      final reachProvider = Provider.of<ReachDataProvider>(
        context,
        listen: false,
      );
      final reach = reachProvider.currentReach;
      final forecast = reachProvider.currentForecast;

      if (reach == null || forecast == null) {
        ExportFunctionality.showErrorMessage(
          context,
          'No data available for export',
        );
        return;
      }

      // UPDATED: Check if we're showing ensemble data and export accordingly
      if (_showEnsembleMembers &&
          (widget.forecastType == 'medium_range' ||
              widget.forecastType == 'long_range')) {
        // Export ensemble data
        await _exportEnsembleDataAsCSV(reach, forecast);
      } else {
        // Export single series data (existing logic)
        await _exportSingleSeriesAsCSV(reach, forecast);
      }
    } catch (e) {
      ExportFunctionality.showErrorMessage(context, e.toString());
    }
  }

  Future<void> _exportSingleSeriesAsCSV(reach, forecast) async {
    // Get the forecast data
    final forecastSeries = forecast.getPrimaryForecast(_forecastType!);
    if (forecastSeries == null || forecastSeries.isEmpty) {
      ExportFunctionality.showErrorMessage(
        context,
        'No forecast data available',
      );
      return;
    }

    // Proper type checking and error handling
    try {
      final List<ChartDataPoint> chartData = [];

      // Check if data is the correct type and convert safely
      if (forecastSeries.data is List<dynamic>) {
        // Handle the case where data is List<dynamic>
        final dynamicList = forecastSeries.data as List<dynamic>;

        for (final item in dynamicList) {
          try {
            // Try to access the fields we need
            if (item is Map<String, dynamic>) {
              final validTimeStr = item['validTime'];
              final flowValue = item['flow'];

              if (validTimeStr != null && flowValue != null) {
                final validTime = DateTime.parse(validTimeStr.toString());
                final flow = (flowValue as num).toDouble();

                chartData.add(
                  ChartDataPoint(time: validTime.toLocal(), flow: flow),
                );
              }
            } else if (item != null) {
              // Try to access as ForecastPoint properties
              final dynamic validTime = (item as dynamic).validTime;
              final dynamic flow = (item as dynamic).flow;

              if (validTime != null && flow != null) {
                chartData.add(
                  ChartDataPoint(
                    time: (validTime as DateTime).toLocal(),
                    flow: (flow as num).toDouble(),
                  ),
                );
              }
            }
          } catch (itemError) {
            AppLogger.error('HydrographPage', 'Error processing forecast point', itemError);
            // Skip this item and continue
            continue;
          }
        }
      } else {
        // Handle the expected case where data is List<ForecastPoint>
        for (final point in forecastSeries.data) {
          chartData.add(
            ChartDataPoint(time: point.validTime.toLocal(), flow: point.flow),
          );
        }
      }

      if (chartData.isEmpty) {
        ExportFunctionality.showErrorMessage(
          context,
          'No valid forecast data points found',
        );
        return;
      }

      // Get return periods for flood categories
      final returnPeriods = reach.returnPeriods;

      await ExportFunctionality.exportDataAsCSV(
        chartData: chartData,
        reachName: reach.displayName,
        forecastType: _forecastType!,
        returnPeriods: returnPeriods,
      );
    } catch (e) {
      AppLogger.error('HydrographPage', 'Error in _exportSingleSeriesAsCSV', e);
      ExportFunctionality.showErrorMessage(
        context,
        'Failed to export data: ${e.toString()}',
      );
    }
  }

  Future<void> _exportEnsembleDataAsCSV(reach, forecast) async {
    try {
      // Get ensemble data using our service
      final ensembleData = _forecastService.getEnsembleReferenceData(
        forecast,
        _forecastType!,
      );

      if (ensembleData.isEmpty) {
        ExportFunctionality.showErrorMessage(
          context,
          'No ensemble data available',
        );
        return;
      }

      // Convert to ChartDataPoint format with error handling
      final List<ChartDataPoint> chartData = [];

      for (final point in ensembleData) {
        try {
          chartData.add(
            ChartDataPoint(
              time: point.time,
              flow: point.flow,
              metadata: point.metadata,
            ),
          );
        } catch (e) {
          AppLogger.error('HydrographPage', 'Error processing ensemble point', e);
          // Skip this point and continue
          continue;
        }
      }

      if (chartData.isEmpty) {
        ExportFunctionality.showErrorMessage(
          context,
          'No valid ensemble data points found',
        );
        return;
      }

      // Get return periods for flood categories
      final returnPeriods = reach.returnPeriods;

      // Export with special naming for ensemble data
      await ExportFunctionality.exportDataAsCSV(
        chartData: chartData,
        reachName: reach.displayName,
        forecastType: '${_forecastType!}_ensemble',
        returnPeriods: returnPeriods,
      );
    } catch (e) {
      AppLogger.error('HydrographPage', 'Error in _exportEnsembleDataAsCSV', e);
      ExportFunctionality.showErrorMessage(
        context,
        'Failed to export ensemble data: ${e.toString()}',
      );
    }
  }

  void _showFloodCategoriesInfo() {
    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );
    final reach = reachProvider.currentReach;
    final returnPeriods = reach?.returnPeriods;

    showCupertinoModalPopup(
      context: context,
      builder: (context) =>
          FloodCategoriesInfoSheet(returnPeriods: returnPeriods),
    );
  }

  void _showChartInfo() {
    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );
    final reach = reachProvider.currentReach;
    final hasReturnPeriods =
        reach?.returnPeriods != null && reach!.returnPeriods!.isNotEmpty;

    showCupertinoModalPopup(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(reach?.displayName ?? 'Chart Information'),
        message: Text(_buildChartInfoMessage()),
        actions: [
          if (hasReturnPeriods)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(context);
                _showFloodCategoriesInfo();
              },
              child: const Text('Flood Risk Categories'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ),
    );
  }

  String _buildChartInfoMessage() {
    final typeNames = {
      'short_range': 'Hourly (Short Range)',
      'medium_range': 'Daily (Medium Range)',
      'long_range': 'Extended (Long Range)',
    };

    final typeName = typeNames[_forecastType] ?? _forecastType?.toUpperCase();

    // UPDATED: Show different message based on ensemble toggle
    final displayMode = _showEnsembleMembers
        ? 'All Ensemble Members + Mean'
        : 'Mean Forecast Only';

    return '$typeName Forecast\nShowing: $displayMode\nData Source: NOAA National Water Model';
  }

  @override
  Widget build(BuildContext context) {
    if (_reachId == null || _forecastType == null) {
      return _buildErrorPage('Missing required parameters');
    }

    if (!_isInitialized) {
      return _buildLoadingPage();
    }

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_pageTitle ?? 'Hydrograph'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _showChartInfo,
              child: const Icon(CupertinoIcons.info_circle),
            ),
          ],
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

            return _buildChartContent(reachProvider);
          },
        ),
      ),
    );
  }

  Widget _buildChartContent(ReachDataProvider reachProvider) {
    return Column(
      children: [
        // Main Chart Area (wrapped with Screenshot widget)
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: CupertinoColors.systemBackground.resolveFrom(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: CupertinoColors.separator.resolveFrom(context),
                width: 0.5,
              ),
            ),
            child: Screenshot(
              controller: _screenshotController,
              child: InteractiveChart(
                controller: _chartController,
                reachId: _reachId!,
                forecastType: _forecastType!,
                showReturnPeriods: _showReturnPeriods,
                showTooltips: _showTooltips,
                showEnsembleMembers:
                    _showEnsembleMembers, // NEW: Pass ensemble state
                reachProvider: reachProvider,
              ),
            ),
          ),
        ),

        // Chart Controls (moved below chart)
        _buildChartControls(
          reachProvider,
        ), // NEW: Pass reachProvider for ensemble check
        // Chart Legend/Info (at bottom)
        _buildChartLegend(reachProvider),
      ],
    );
  }

  // UPDATED: Add ensemble toggle to chart controls
  Widget _buildChartControls(ReachDataProvider reachProvider) {
    // Check if ensemble data is available using our new method
    final forecast = reachProvider.currentForecast;
    final hasEnsemble =
        forecast != null &&
        _forecastService.hasMultipleEnsembleMembers(forecast, _forecastType!) &&
        (_forecastType == 'medium_range' || _forecastType == 'long_range');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Return Periods Toggle
          Expanded(
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: _showReturnPeriods
                  ? CupertinoColors.systemBlue
                  : CupertinoColors.systemGrey5.resolveFrom(context),
              onPressed: _toggleReturnPeriods,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Show checkmark when toggled ON, nothing when OFF
                  if (_showReturnPeriods)
                    const Icon(
                      CupertinoIcons.checkmark,
                      size: 16,
                      color: CupertinoColors.white,
                    ),
                  // Add spacing only when checkmark is shown
                  if (_showReturnPeriods) const SizedBox(width: 6),
                  Text(
                    'Risk Zones',
                    style: TextStyle(
                      fontSize: 13,
                      color: _showReturnPeriods
                          ? CupertinoColors.white
                          : CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // NEW: Ensemble Members Toggle (only show for medium/long range with ensemble data)
          if (hasEnsemble)
            Expanded(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: _showEnsembleMembers
                    ? CupertinoColors.systemOrange
                    : CupertinoColors.systemGrey5.resolveFrom(context),
                onPressed: _toggleEnsembleMembers,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_showEnsembleMembers)
                      const Icon(
                        CupertinoIcons.checkmark,
                        size: 16,
                        color: CupertinoColors.white,
                      ),
                    if (_showEnsembleMembers) const SizedBox(width: 6),
                    Text(
                      'All Members',
                      style: TextStyle(
                        fontSize: 13,
                        color: _showEnsembleMembers
                            ? CupertinoColors.white
                            : CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(width: 8),

          // Reset Zoom Button
          CupertinoButton(
            padding: const EdgeInsets.all(8),
            color: CupertinoColors.systemGrey5.resolveFrom(context),
            onPressed: _resetZoom,
            child: Icon(
              CupertinoIcons.zoom_out,
              size: 16,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),

          const SizedBox(width: 8),

          // Export Button
          CupertinoButton(
            padding: const EdgeInsets.all(8),
            color: CupertinoColors.systemGrey5.resolveFrom(context),
            onPressed: _exportChart,
            child: Icon(
              CupertinoIcons.share,
              size: 16,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartLegend(ReachDataProvider reachProvider) {
    final reach = reachProvider.currentReach;
    if (reach == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Chart Legend
          Row(
            children: [
              _buildLegendItem('Flow Data', CupertinoColors.systemBlue),
              const SizedBox(width: 16),
              if (_showReturnPeriods)
                _buildLegendItem('Risk Zones', CupertinoColors.systemRed),
              // NEW: Show ensemble legend when enabled
              if (_showEnsembleMembers) ...[
                const SizedBox(width: 16),
                _buildLegendItem(
                  'Ensemble Members',
                  CupertinoColors.systemPurple,
                ),
              ],
              const Spacer(),
            ],
          ),

          const SizedBox(height: 8),

          // Data Info
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Icon(
                CupertinoIcons.location,
                size: 12,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              const SizedBox(width: 4),
              Text(
                reach.displayName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CupertinoActivityIndicator(radius: 20),
          SizedBox(height: 16),
          Text(
            'Loading chart data...',
            style: TextStyle(
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
              'Unable to load chart',
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
            const Text(
              'No chart data available',
              style: TextStyle(
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

  Widget _buildLoadingPage() {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_pageTitle ?? 'Hydrograph'),
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CupertinoActivityIndicator(radius: 20),
              const SizedBox(height: 16),
              Text(
                'Loading hydrograph...',
                style: TextStyle(
                  fontSize: 16,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorPage(String error) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_pageTitle ?? 'Hydrograph'),
      ),
      child: SafeArea(
        child: Center(
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
                  'Unable to load hydrograph',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  error,
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                CupertinoButton.filled(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
