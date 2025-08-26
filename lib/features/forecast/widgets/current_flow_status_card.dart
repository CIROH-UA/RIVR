// lib/features/forecast/widgets/current_flow_status_card.dart

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:rivrflow/features/forecast/utils/flow_category_pulse_animator.dart';
import '../../../core/providers/reach_data_provider.dart';
import '../../../core/services/flow_unit_preference_service.dart';
import '../../../core/constants.dart'; // Import for centralized styling

class CurrentFlowStatusCard extends StatefulWidget {
  final VoidCallback? onTap;
  final bool expanded;

  const CurrentFlowStatusCard({super.key, this.onTap, this.expanded = false});

  @override
  State<CurrentFlowStatusCard> createState() => _CurrentFlowStatusCardState();
}

class _CurrentFlowStatusCardState extends State<CurrentFlowStatusCard>
    with TickerProviderStateMixin {
  bool _returnPeriodExpanded = false;
  late FlowCategoryPulseAnimator _pulseAnimator;

  @override
  void initState() {
    super.initState();

    // Initialize pulse animator utility
    _pulseAnimator = FlowCategoryPulseAnimator(vsync: this);

    // Start animation only if card is tappable
    if (widget.onTap != null) {
      _pulseAnimator.start();
    }
  }

  @override
  void dispose() {
    // Clean disposal of pulse animator
    _pulseAnimator.dispose();
    super.dispose();
  }

  // Get current flow units from preference service
  String _getCurrentFlowUnit() {
    final unitService = FlowUnitPreferenceService();
    return unitService.currentFlowUnit; // Returns 'CFS' or 'CMS' directly
  }

  // Calculate flow category using already-converted values
  String _calculateFlowCategory(double? currentFlow, dynamic reach) {
    if (currentFlow == null || reach?.returnPeriods == null) {
      return 'Unknown';
    }

    final currentUnit = _getCurrentFlowUnit();

    // FIXED: No double conversion - flow is already in preferred unit from API service
    return reach.getFlowCategory(currentFlow, currentUnit);
  }

  // REMOVED: _convertFlowToCurrentUnit method - no longer needed!
  // The NoaaApiService already converts all forecast data to preferred units

  @override
  Widget build(BuildContext context) {
    return Consumer<ReachDataProvider>(
      builder: (context, reachProvider, child) {
        // Handle initial loading (no overview data yet)
        if (reachProvider.isLoadingOverview ||
            (!reachProvider.hasOverviewData && reachProvider.isLoading)) {
          return _buildLoadingCard();
        }

        // Handle no data state
        if (!reachProvider.hasOverviewData) {
          return _buildEmptyCard();
        }

        // FIXED: Get flow data that's already converted by NoaaApiService
        final currentFlow = reachProvider
            .getCurrentFlow(); // Already in preferred unit!
        final reach = reachProvider.currentReach;

        // FIXED: No double conversion - use flow data directly
        final category = _calculateFlowCategory(currentFlow, reach);

        // Update pulse animation based on flow category
        _pulseAnimator.updateCategory(category);

        return GestureDetector(
          onTap: widget.onTap,
          child: AnimatedBuilder(
            animation: _pulseAnimator.animation!,
            builder: (context, child) {
              return Transform.scale(
                scale: widget.onTap != null ? _pulseAnimator.value : 1.0,
                child: Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _getGradientColors(category),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: CupertinoColors.systemGrey.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(category),
                        const SizedBox(height: 16),
                        // FIXED: Use flow value directly (already converted)
                        _buildFlowValue(currentFlow),
                        const SizedBox(height: 16),

                        // Progressive flow indicator based on loading state
                        _buildProgressiveFlowIndicator(
                          currentFlow,
                          reach,
                          reachProvider,
                        ),

                        const SizedBox(height: 12),
                        _buildMetadata(reach, reachProvider),
                        if (widget.expanded) ...[
                          const SizedBox(height: 16),
                          _buildExpandedContent(reach, reachProvider),
                        ] else
                          _buildExpandHint(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHeader(String category) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Current Flow',
          style: TextStyle(
            color: CupertinoColors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _getBadgeBackgroundColor(category),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            category,
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  // FIXED: Format flow value that's already converted
  Widget _buildFlowValue(double? flow) {
    if (flow == null) {
      return const Text(
        'No data',
        style: TextStyle(
          color: CupertinoColors.white,
          fontSize: 32,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    // Get current flow unit dynamically
    final currentUnit = _getCurrentFlowUnit();

    // Format flow as integer with comma separators
    final formattedFlow = NumberFormat('#,###').format(flow.round());

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          formattedFlow, // Shows "43,210" instead of "43210.0078125"
          style: const TextStyle(
            color: CupertinoColors.white,
            fontSize: 32,
            fontWeight: FontWeight.bold,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Text(
            currentUnit,
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  // Progressive flow indicator that handles loading states
  Widget _buildProgressiveFlowIndicator(
    double? currentFlow,
    dynamic reach,
    ReachDataProvider reachProvider,
  ) {
    // Show return period flow indicator if we have the data
    if (reach?.returnPeriods != null &&
        reach!.returnPeriods!.isNotEmpty &&
        currentFlow != null) {
      // FIXED: Use flow data directly (no conversion needed)
      return _buildFlowIndicator(currentFlow, reach);
    }

    // Show loading state if we're loading supplementary data (return periods)
    if (reachProvider.isLoadingSupplementary && currentFlow != null) {
      return _buildFlowIndicatorLoading();
    }

    // No indicator if no flow data
    return const SizedBox.shrink();
  }

  // Loading state for flow indicator
  Widget _buildFlowIndicatorLoading() {
    return Column(
      children: [
        Container(
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: CupertinoColors.white.withValues(alpha: 0.3),
          ),
          child: const Center(
            child: SizedBox(
              height: 4,
              width: 40,
              child: CupertinoActivityIndicator(
                color: CupertinoColors.white,
                radius: 6,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Loading flow categories...',
          style: TextStyle(
            color: CupertinoColors.white.withValues(alpha: 0.7),
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  // FIXED: Flow indicator with flow data already in correct unit
  Widget _buildFlowIndicator(
    double currentFlow, // Already in user's preferred unit from API service
    dynamic reach,
  ) {
    final currentUnit = _getCurrentFlowUnit();

    // Get return periods in the same unit as current flow
    final convertedReturnPeriods = reach.getReturnPeriodsInUnit(currentUnit);
    if (convertedReturnPeriods == null || convertedReturnPeriods.isEmpty) {
      return const SizedBox.shrink();
    }

    // Get specific return period values for accurate positioning
    final twoYear = convertedReturnPeriods[2];
    final fiveYear = convertedReturnPeriods[5];
    final tenYear = convertedReturnPeriods[10];
    final twentyFiveYear = convertedReturnPeriods[25];

    // Calculate where the current flow sits relative to return periods
    double flowPosition = 0.0; // Position as percentage (0.0 to 1.0)

    if (twoYear != null) {
      if (currentFlow <= twoYear) {
        // In Normal zone (0-20%)
        flowPosition = (currentFlow / twoYear) * 0.20;
      } else if (fiveYear != null && currentFlow <= fiveYear) {
        // In Action zone (20-40%)
        flowPosition =
            0.20 + ((currentFlow - twoYear) / (fiveYear - twoYear)) * 0.20;
      } else if (tenYear != null && currentFlow <= tenYear) {
        // In Moderate zone (40-60%)
        flowPosition =
            0.40 + ((currentFlow - fiveYear!) / (tenYear - fiveYear)) * 0.20;
      } else if (twentyFiveYear != null && currentFlow <= twentyFiveYear) {
        // In Major zone (60-80%)
        flowPosition =
            0.60 +
            ((currentFlow - tenYear!) / (twentyFiveYear - tenYear)) * 0.20;
      } else {
        // In Extreme zone (80-100%)
        if (twentyFiveYear != null) {
          // Calculate position beyond 25-year, capped at 100%
          final extraFlow = currentFlow - twentyFiveYear;
          final extraRange =
              twentyFiveYear *
              0.5; // Assume extreme zone is 50% of 25-year value
          flowPosition =
              0.80 + (extraFlow / extraRange * 0.20).clamp(0.0, 0.20);
        } else {
          flowPosition = 0.90; // Default to near end if no 25-year data
        }
      }
    }

    // Use centralized colors for flow categories
    List<double> stops = [
      0.0, // Start
      0.17, 0.24, // Normal to Action transition
      0.37, 0.44, // Action to Moderate transition
      0.57, 0.64, // Moderate to Major transition
      0.77, 0.84, // Major to Extreme transition
      1.0, // End
    ];

    List<Color> colors = [
      const Color(0xFF4A90E2), // Normal blue start
      const Color(0xFF4A90E2), // Normal blue end
      const Color(0xFFFFC107), // Action yellow start
      const Color(0xFFFFC107), // Action yellow end
      const Color(0xFFFF9800), // Moderate orange start
      const Color(0xFFFF9800), // Moderate orange end
      const Color(0xFFF44336), // Major red start
      const Color(0xFFF44336), // Major red end
      const Color(0xFF9C27B0), // Extreme purple start
      const Color(0xFF9C27B0), // Extreme purple end
    ];

    return Column(
      children: [
        Container(
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(stops: stops, colors: colors),
          ),
          child: Stack(
            children: [
              // Flow marker positioned based on actual return period values
              Positioned(
                left: (flowPosition * MediaQuery.of(context).size.width * 0.8)
                    .clamp(0, MediaQuery.of(context).size.width * 0.8 - 4),
                top: -2,
                child: Container(
                  width: 4,
                  height: 12,
                  decoration: BoxDecoration(
                    color: CupertinoColors.white,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: CupertinoColors.black.withValues(alpha: 0.3),
                        blurRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _buildEqualWidthZoneLabels(),
      ],
    );
  }

  // Build equal-width zone labels with Extreme included
  Widget _buildEqualWidthZoneLabels() {
    final screenWidth = MediaQuery.of(context).size.width * 0.8;

    return SizedBox(
      height: 20,
      child: Stack(
        children: [
          // Normal - centered in 0-20% zone
          Positioned(
            left:
                (0.10 * screenWidth -
                15), // 10% position minus half label width
            child: const Text(
              'Normal',
              style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 8,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // Action - centered in 20-40% zone
          Positioned(
            left:
                (0.30 * screenWidth -
                12), // 30% position minus half label width
            child: const Text(
              'Action',
              style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 8,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // Moderate - centered in 40-60% zone
          Positioned(
            left:
                (0.50 * screenWidth -
                18), // 50% position minus half label width
            child: const Text(
              'Moderate',
              style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 8,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // Major - centered in 60-80% zone
          Positioned(
            left:
                (0.70 * screenWidth -
                12), // 70% position minus half label width
            child: const Text(
              'Major',
              style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 8,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // Extreme - centered in 80-100% zone
          Positioned(
            left:
                (0.90 * screenWidth -
                15), // 90% position minus half label width
            child: const Text(
              'Extreme',
              style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 8,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Use cached formatted location
  Widget _buildMetadata(dynamic reach, ReachDataProvider reachProvider) {
    if (reach == null) return const SizedBox.shrink();

    return Row(
      children: [
        Icon(
          CupertinoIcons.location,
          color: CupertinoColors.white.withValues(alpha: 0.8),
          size: 16,
        ),
        const SizedBox(width: 6),
        Text(
          reach.displayName ?? reach.riverName,
          style: TextStyle(
            color: CupertinoColors.white.withValues(alpha: 0.9),
            fontSize: 14,
          ),
        ),

        //  Use cached formatted location (fixes subtitle issues)
        Builder(
          builder: (context) {
            final formattedLocation = reachProvider.getFormattedLocation();
            if (formattedLocation.isNotEmpty) {
              return Row(
                children: [
                  const SizedBox(width: 8),
                  Text(
                    '• $formattedLocation',
                    style: TextStyle(
                      color: CupertinoColors.white.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                ],
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  // IMPROVED: Handle loading states for return periods
  Widget _buildExpandedContent(dynamic reach, ReachDataProvider reachProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          height: 1,
          color: CupertinoColors.white.withValues(alpha: 0.3),
        ),
        const SizedBox(height: 16),
        CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            setState(() {
              _returnPeriodExpanded = !_returnPeriodExpanded;
            });
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CupertinoColors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Return Period Information',
                  style: TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(
                  _returnPeriodExpanded
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  color: CupertinoColors.white,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 300),
          crossFadeState: _returnPeriodExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _buildReturnPeriodContent(reach, reachProvider),
          ),
        ),
      ],
    );
  }

  // Progressive return period content
  Widget _buildReturnPeriodContent(
    dynamic reach,
    ReachDataProvider reachProvider,
  ) {
    // Show return period table if we have the data
    if (reach?.returnPeriods != null && reach!.returnPeriods!.isNotEmpty) {
      return _buildReturnPeriodTable(reach);
    }

    // Show loading state if we're loading supplementary data
    if (reachProvider.isLoadingSupplementary) {
      return _buildReturnPeriodLoading();
    }

    // Show not available message
    return _buildReturnPeriodNotAvailable();
  }

  // Loading state for return period table
  Widget _buildReturnPeriodLoading() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: CupertinoColors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Column(
          children: [
            CupertinoActivityIndicator(
              color: CupertinoColors.white,
              radius: 12,
            ),
            SizedBox(height: 8),
            Text(
              'Loading return period data...',
              style: TextStyle(color: CupertinoColors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  // Not available state for return periods
  Widget _buildReturnPeriodNotAvailable() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Return period data is not available for this reach.',
        style: TextStyle(
          color: CupertinoColors.white.withValues(alpha: 0.8),
          fontSize: 14,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  // Use converted return periods and dynamic header
  Widget _buildReturnPeriodTable(dynamic reach) {
    final periods = [
      2,
      5,
      10,
      25,
      50,
      100,
    ].where((year) => reach.returnPeriods.containsKey(year)).toList();

    // Get current flow unit for table header
    final currentUnit = _getCurrentFlowUnit();

    // Get return periods converted to current unit
    final convertedReturnPeriods = reach.getReturnPeriodsInUnit(currentUnit);
    if (convertedReturnPeriods == null) {
      return _buildReturnPeriodNotAvailable();
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                flex: 2,
                child: Text(
                  'Return Period',
                  style: TextStyle(
                    color: CupertinoColors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  'Flow ($currentUnit)',
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...periods.map((year) {
            final flow = convertedReturnPeriods[year]!;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      '$year-year',
                      style: TextStyle(
                        color: CupertinoColors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _formatFlow(flow),
                      style: TextStyle(
                        color: CupertinoColors.white.withValues(alpha: 0.9),
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildExpandHint() {
    if (widget.onTap == null) return const SizedBox.shrink();

    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Icon(
          CupertinoIcons.chevron_down,
          color: CupertinoColors.white.withValues(alpha: 00.6),
          size: 20,
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [CupertinoColors.systemGrey, CupertinoColors.systemGrey2],
        ),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CupertinoActivityIndicator(
              color: CupertinoColors.white,
              radius: 12,
            ),
            SizedBox(height: 12),
            Text(
              'Loading flow data...',
              style: TextStyle(color: CupertinoColors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      height: 120,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [CupertinoColors.systemGrey3, CupertinoColors.systemGrey4],
        ),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_circle,
              color: CupertinoColors.white,
              size: 24,
            ),
            SizedBox(height: 8),
            Text(
              'No flow data available',
              style: TextStyle(color: CupertinoColors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  // Use centralized styling and support new categories
  List<Color> _getGradientColors(String category) {
    final baseColor = AppConstants.getFlowCategoryColor(category);

    switch (category.toLowerCase()) {
      case 'normal':
        return [baseColor, baseColor.withValues(alpha: 0.7)];
      case 'action':
        return [baseColor, baseColor.withValues(alpha: 0.8)];
      case 'moderate':
        return [baseColor, baseColor.withValues(alpha: 0.8)];
      case 'major':
        return [baseColor, baseColor.withValues(alpha: 0.7)];
      case 'extreme':
        return [baseColor, baseColor.withValues(alpha: 0.7)];
      default:
        // Use a neutral gray for unknown categories
        return [CupertinoColors.systemGrey, CupertinoColors.systemGrey2];
    }
  }

  // Support new categories with better contrast
  Color _getBadgeBackgroundColor(String category) {
    switch (category.toLowerCase()) {
      case 'normal':
        return CupertinoColors.white.withValues(alpha: 0.25);
      case 'action':
        return CupertinoColors.black.withValues(alpha: 0.25);
      case 'moderate':
        return CupertinoColors.black.withValues(alpha: 0.25);
      case 'major':
        return CupertinoColors.white.withValues(alpha: 0.25);
      case 'extreme':
        return CupertinoColors.white.withValues(alpha: 0.25);
      default:
        return CupertinoColors.white.withValues(alpha: 0.25);
    }
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
}
