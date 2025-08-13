// lib/features/forecast/pages/medium_range_detail_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/reach_data_provider.dart';
import '../widgets/forecast_detail_template.dart';
import '../widgets/flow_values_usage_guide.dart';
import '../widgets/daily_expandable_widget/daily_flow_forecast_widget.dart';

class MediumRangeDetailPage extends StatefulWidget {
  final String? reachId;

  const MediumRangeDetailPage({super.key, this.reachId});

  @override
  State<MediumRangeDetailPage> createState() => _MediumRangeDetailPageState();
}

class _MediumRangeDetailPageState extends State<MediumRangeDetailPage> {
  String? _reachId;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializePage();
  }

  Future<void> _initializePage() async {
    // Get reachId from widget or navigation arguments
    _reachId = widget.reachId;

    if (_reachId == null) {
      // Try to get from navigation arguments
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final args =
            ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
        if (args != null && args['reachId'] != null) {
          setState(() {
            _reachId = args['reachId'] as String;
          });
        }
        _loadReachData();
      });
    } else {
      _loadReachData();
    }
  }

  Future<void> _loadReachData() async {
    if (_reachId == null) return;

    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );

    // Load reach data if not already loaded or if different reach
    if (!reachProvider.hasData ||
        reachProvider.currentReach?.reachId != _reachId) {
      try {
        await reachProvider.loadReach(_reachId!);
      } catch (e) {
        // Error handling is managed by the provider
      }
    }

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  void _navigateToHydrograph() {
    if (_reachId == null) return;

    Navigator.pushNamed(
      context,
      '/hydrograph',
      arguments: {
        'reachId': _reachId,
        'forecastType': 'medium_range',
        'title': 'Daily Hydrograph',
      },
    );
  }

  /// Handle refresh for the daily forecast widget
  Future<void> _handleForecastRefresh() async {
    if (_reachId == null) return;

    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );

    try {
      await reachProvider.loadReach(_reachId!);
    } catch (e) {
      // Error handling is managed by the provider
      print('Error refreshing forecast data: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_reachId == null) {
      return _buildErrorPage('No reach selected');
    }

    if (!_isInitialized) {
      return _buildLoadingPage();
    }

    return Consumer<ReachDataProvider>(
      builder: (context, reachProvider, child) {
        return ForecastDetailTemplate(
          reachId: _reachId!,
          forecastType: 'medium_range',
          title: 'Daily Forecast',
          usageGuideOptions: FlowValuesUsageGuide.mediumRangeOptions(),
          onChartTap: _navigateToHydrograph,
          showCurrentFlow: false,

          // Custom timeline widget using our DailyFlowForecastWidget
          customTimelineWidget: _buildDailyForecastWidget(reachProvider),
          showTimelineSection: true,
          showTimelineTitle: false,
          // Keep existing additional content
          additionalContent: _buildMediumRangeSpecificContent(reachProvider),
        );
      },
    );
  }

  /// Build the new daily forecast widget
  Widget _buildDailyForecastWidget(ReachDataProvider reachProvider) {
    // Check if we have forecast data
    if (!reachProvider.hasData || reachProvider.currentForecast == null) {
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
                'Loading Daily Forecasts...',
                style: CupertinoTheme.of(context).textTheme.navTitleTextStyle
                    .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    return DailyFlowForecastWidget(
      forecastResponse: reachProvider.currentForecast,
      forecastType: 'medium_range',
      onRefresh: _handleForecastRefresh,
      allowMultipleExpanded: false,
      maxHeight: 600, // Reasonable height constraint for the page
    );
  }

  Widget _buildMediumRangeSpecificContent(ReachDataProvider reachProvider) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_buildDataSourceInfo(reachProvider)],
      ),
    );
  }

  Widget _buildDataSourceInfo(ReachDataProvider reachProvider) {
    // Enhanced data source info that reflects our new processing
    final currentForecast = reachProvider.currentForecast;
    String dataSourceDetail = 'NOAA National Water Model Medium Range Forecast';
    String updateInfo =
        'Updated every 6 hours • 10 days of forecast data available';

    // Add ensemble information if available
    if (currentForecast != null) {
      final ensembleInfo = currentForecast.mediumRange;
      if (ensembleInfo.containsKey('mean') &&
          ensembleInfo['mean']?.isNotEmpty == true) {
        updateInfo += ' • Using ensemble mean';
      } else {
        final memberCount = ensembleInfo.keys
            .where((k) => k.startsWith('member'))
            .length;
        if (memberCount > 0) {
          updateInfo +=
              ' • Using ensemble member data ($memberCount members available)';
        }
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemBlue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemBlue.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.info_circle,
                size: 16,
                color: CupertinoColors.systemBlue,
              ),
              const SizedBox(width: 8),
              Text(
                'Data Source',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            dataSourceDetail,
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            updateInfo,
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingPage() {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Medium Range Forecast'),
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CupertinoActivityIndicator(radius: 20),
              const SizedBox(height: 16),
              Text(
                'Loading forecast data...',
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
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Medium Range Forecast'),
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
