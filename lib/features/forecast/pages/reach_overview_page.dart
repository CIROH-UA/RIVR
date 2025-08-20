// lib/features/forecast/pages/reach_overview_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivrflow/core/models/reach_data.dart';
import '../../../core/providers/reach_data_provider.dart';
import '../widgets/current_flow_status_card.dart';
import '../widgets/forecast_category_grid.dart';

class ReachOverviewPage extends StatefulWidget {
  final String? reachId;

  const ReachOverviewPage({super.key, this.reachId});

  @override
  State<ReachOverviewPage> createState() => _ReachOverviewPageState();
}

class _ReachOverviewPageState extends State<ReachOverviewPage> {
  bool _isInitialized = false;
  String? _currentLoadingReachId; // Track which reach we're loading

  @override
  void initState() {
    super.initState();
    // Defer loading until after the build is complete
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadReachData();
    });
  }

  @override
  void didUpdateWidget(ReachOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Handle reachId changes (when navigating to different river)
    if (oldWidget.reachId != widget.reachId) {
      _loadReachData();
    }
  }

  // Progressive loading with immediate state clearing
  Future<void> _loadReachData() async {
    if (widget.reachId == null) return;

    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );

    // CRITICAL FIX: Immediately clear wrong river data when switching
    if (reachProvider.currentReach?.reachId != widget.reachId) {
      print('OVERVIEW_PAGE: Switching rivers, clearing current display');
      reachProvider.clearCurrentReach();
      setState(() {
        _isInitialized = false;
        _currentLoadingReachId = widget.reachId;
      });
    }

    try {
      // PHASE 1: Load overview data first (fast - shows name, location, current flow)
      print('OVERVIEW_PAGE: Starting Phase 1 - Overview data');
      final overviewSuccess = await reachProvider.loadOverviewData(
        widget.reachId!,
      );

      if (!overviewSuccess) {
        print('OVERVIEW_PAGE: Failed to load overview data');
        return;
      }

      // Mark as initialized after overview loads (shows basic info immediately)
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }

      // PHASE 2: Progressive forecast category loading
      print('OVERVIEW_PAGE: Starting Phase 2 - Progressive forecast loading');
      await _loadForecastCategoriesProgressively(widget.reachId!);

      // PHASE 3: Load supplementary data (return periods, enhanced categorization)
      print('OVERVIEW_PAGE: Starting Phase 3 - Supplementary data');
      await reachProvider.loadSupplementaryData(widget.reachId!);

      print('OVERVIEW_PAGE: All loading phases completed');
    } catch (e) {
      print('OVERVIEW_PAGE: Error in loading sequence: $e');
    }
  }

  // Progressive forecast category loading
  Future<void> _loadForecastCategoriesProgressively(String reachId) async {
    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );

    // Load forecast categories one by one so they appear progressively
    // This provides better user experience - they see data as it becomes available

    // Load Hourly forecast (short-range) first - usually fastest
    print('OVERVIEW_PAGE: Loading hourly forecast...');
    await reachProvider.loadHourlyForecast(reachId);

    // Small delay to allow UI to update and show the hourly category
    await Future.delayed(const Duration(milliseconds: 100));

    // Load Daily forecast (medium-range) second
    print('OVERVIEW_PAGE: Loading daily forecast...');
    await reachProvider.loadDailyForecast(reachId);

    // Small delay to allow UI to update and show the daily category
    await Future.delayed(const Duration(milliseconds: 100));

    // Load Extended forecast (long-range) third
    print('OVERVIEW_PAGE: Loading extended forecast...');
    await reachProvider.loadExtendedForecast(reachId);

    print('OVERVIEW_PAGE: Progressive forecast loading completed');
  }

  // Comprehensive refresh for all forecast categories
  Future<void> _handleRefresh() async {
    if (widget.reachId == null) return;

    print('OVERVIEW_PAGE: Starting comprehensive refresh');
    final reachProvider = Provider.of<ReachDataProvider>(
      context,
      listen: false,
    );

    // Use comprehensive refresh instead of basic refresh
    await reachProvider.comprehensiveRefresh(widget.reachId!);
    print('OVERVIEW_PAGE: Comprehensive refresh completed');
  }

  void _navigateToForecastDetail(String forecastType) {
    if (widget.reachId == null) return;

    // Route to the correct detail page based on forecast type
    String routeName;
    switch (forecastType) {
      case 'short_range':
        routeName = '/short-range-detail';
        break;
      case 'medium_range':
        routeName = '/medium-range-detail';
        break;
      case 'long_range':
        routeName = '/long-range-detail';
        break;
      default:
        // Fallback to short range if unknown type
        routeName = '/short-range-detail';
        break;
    }

    Navigator.pushNamed(
      context,
      routeName,
      arguments: {'reachId': widget.reachId, 'forecastType': forecastType},
    );
  }

  void _navigateToHydrograph(String forecastType) {
    if (widget.reachId == null) return;

    Navigator.pushNamed(
      context,
      '/hydrograph',
      arguments: {'reachId': widget.reachId, 'forecastType': forecastType},
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reachId == null) {
      return CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(
          middle: Text('River Forecast'),
        ),
        child: _buildErrorState('No reach selected'),
      );
    }

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Flow Forecast Overview'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _handleRefresh,
          child: Consumer<ReachDataProvider>(
            builder: (context, reachProvider, child) {
              // Extra safety check - don't show data if IDs don't match
              if (reachProvider.currentReach?.reachId != widget.reachId &&
                  reachProvider.currentReach != null) {
                // Force another clear if we somehow have mismatched data
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  reachProvider.clearCurrentReach();
                });
                return _buildInitialLoadingState();
              }
              // Show loading indicator when any loading is happening
              final isAnyLoading =
                  reachProvider.isLoading ||
                  reachProvider.isLoadingOverview ||
                  reachProvider.isLoadingSupplementary ||
                  reachProvider.isLoadingHourly ||
                  reachProvider.isLoadingDaily ||
                  reachProvider.isLoadingExtended;

              return isAnyLoading
                  ? const CupertinoActivityIndicator(radius: 10)
                  : const Icon(CupertinoIcons.refresh);
            },
          ),
        ),
      ),
      child: Consumer<ReachDataProvider>(
        builder: (context, reachProvider, child) {
          // Handle different loading and error states
          if (!_isInitialized && reachProvider.isLoadingOverview) {
            return _buildInitialLoadingState();
          }

          if (reachProvider.errorMessage != null) {
            return _buildErrorState(reachProvider.errorMessage!);
          }

          if (!reachProvider.hasOverviewData) {
            return _buildEmptyState();
          }

          // Progressive content display based on loading phase
          return _buildProgressiveContent(reachProvider);
        },
      ),
    );
  }

  // Progressive content that shows data as it becomes available
  Widget _buildProgressiveContent(ReachDataProvider reachProvider) {
    final reach = reachProvider.currentReach!;

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          // Station Header - Shows immediately after Phase 1
          SliverToBoxAdapter(child: _buildStationHeader(reach, reachProvider)),

          // Hero Flow Status Card - Shows immediately after Phase 1
          SliverToBoxAdapter(child: _buildFlowStatusSection(reachProvider)),

          // Forecast Categories Grid - Your original design with loading improvements
          SliverToBoxAdapter(
            child: _buildForecastCategoriesSection(reachProvider),
          ),

          // Station Metadata - Enhanced progressively
          SliverToBoxAdapter(
            child: _buildStationMetadata(reach, reachProvider),
          ),

          // Technical Info Section - Coordinates and Reach ID at bottom
          SliverToBoxAdapter(child: _buildTechnicalInfoSection(reach)),

          // Add some bottom padding
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  // Uses cached formatter and shows loading states
  Widget _buildStationHeader(ReachData reach, ReachDataProvider reachProvider) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            CupertinoColors.systemBlue.resolveFrom(context).withOpacity(0.1),
            CupertinoColors.systemBackground.resolveFrom(context),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main title - Shows immediately
          Text(
            reach.displayName,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),

          const SizedBox(height: 8),

          // Use cached formatted location (fixes subtitle issue)
          Text(
            reachProvider.getFormattedLocation(),
            style: TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  // Progressive flow status section with loading states
  Widget _buildFlowStatusSection(ReachDataProvider reachProvider) {
    return Column(
      children: [
        CurrentFlowStatusCard(
          expanded: true,
          onTap: () => _navigateToHydrograph('short_range'),
        ),
      ],
    );
  }

  // Forecast categories design with loading improvements
  Widget _buildForecastCategoriesSection(ReachDataProvider reachProvider) {
    // Check if we should show the shimmer loading or your actual ForecastCategoryGrid
    if (reachProvider.loadingPhase == 'overview' &&
        !reachProvider.hasSupplementaryData) {
      // Show your original loading shimmer for forecast categories during Phase 2
      return _buildForecastCategoriesShimmer();
    }

    // Show your original ForecastCategoryGrid design
    return ForecastCategoryGrid(onCategoryTap: _navigateToForecastDetail);
  }

  // Loading shimmer for forecast categories
  Widget _buildForecastCategoriesShimmer() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Forecast Categories',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: List.generate(4, (index) => _buildCategoryShimmer()),
          ),
        ],
      ),
    );
  }

  // Category shimmer design
  Widget _buildCategoryShimmer() {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(child: CupertinoActivityIndicator(radius: 12)),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStationMetadata(
    ReachData reach,
    ReachDataProvider reachProvider,
  ) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Station Information',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),

          const SizedBox(height: 12),

          _buildMetadataRow('Data Source', 'NOAA National Water Model'),

          _buildMetadataRow(
            'Available Forecasts',
            reachProvider.getAvailableForecastTypes().length.toString(),
          ),

          if (reachProvider.hasEnsembleData())
            _buildMetadataRow('Ensemble Data', 'Available'),

          // Progressive display - only show when return periods are loaded
          if (reachProvider.hasSupplementaryData && reach.hasReturnPeriods)
            _buildMetadataRow(
              'Return Periods',
              '${reach.returnPeriods!.length} periods available',
            )
          else if (reachProvider.isLoadingSupplementary)
            _buildMetadataRow('Return Periods', 'Loading...'),

          _buildMetadataRow('Update Frequency', 'Every 6 hours'),

          if (reach.upstreamReaches?.isNotEmpty == true)
            _buildMetadataRow(
              'Upstream Reaches',
              reach.upstreamReaches!.length.toString(),
            ),

          if (reach.downstreamReaches?.isNotEmpty == true)
            _buildMetadataRow(
              'Downstream Reaches',
              reach.downstreamReaches!.length.toString(),
            ),
        ],
      ),
    );
  }

  // Technical info section with coordinates and reach ID at the bottom
  Widget _buildTechnicalInfoSection(ReachData reach) {
    return Container(
      margin: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _buildInfoChip(
              icon: CupertinoIcons.location,
              label: 'Coordinates',
              value:
                  '${reach.latitude.toStringAsFixed(4)}, ${reach.longitude.toStringAsFixed(4)}',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildInfoChip(
              icon: CupertinoIcons.number,
              label: 'Reach ID',
              value: reach.reachId,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  // Better initial loading state showing correct river being loaded
  Widget _buildInitialLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CupertinoActivityIndicator(radius: 20),
          const SizedBox(height: 16),
          Text(
            'Loading river overview...',
            style: TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          if (_currentLoadingReachId != null) ...[
            const SizedBox(height: 8),
            Text(
              'Reach ID: $_currentLoadingReachId',
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'This should only take a moment',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
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
              'Unable to Load River Data',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            CupertinoButton.filled(
              onPressed: _loadReachData,
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.chart_bar,
              size: 48,
              color: CupertinoColors.secondaryLabel,
            ),
            const SizedBox(height: 16),
            const Text(
              'No Forecast Data',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This reach currently has no forecast data available.',
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
