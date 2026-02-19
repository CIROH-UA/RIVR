// lib/features/map/widgets/reach_details_bottom_sheet.dart

import 'package:flutter/cupertino.dart';
import '../../../core/services/error_service.dart';
import '../../../core/services/app_logger.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/core/services/i_forecast_service.dart';
import '../../../core/services/i_flow_unit_preference_service.dart';
import '../../../core/constants.dart';
import '../models/selected_reach.dart';
import 'components/reach_action_buttons.dart';

/// OPTIMIZED Bottom sheet with efficient return periods loading
/// Strategy: Progressive loading with immediate flow data enhancement
/// 1. Load overview data (current flow) immediately
/// 2. Load return periods in parallel (small, fast request)
/// 3. Update flow classification as soon as return periods arrive
/// 4. Cache return periods separately for future use
class ReachDetailsBottomSheet extends StatefulWidget {
  final SelectedReach selectedReach;
  final VoidCallback? onViewForecast;

  const ReachDetailsBottomSheet({
    super.key,
    required this.selectedReach,
    this.onViewForecast,
  });

  @override
  State<ReachDetailsBottomSheet> createState() =>
      _ReachDetailsBottomSheetState();
}

class _ReachDetailsBottomSheetState extends State<ReachDetailsBottomSheet> {
  final IForecastService _forecastService = GetIt.I<IForecastService>();

  // Progressive loading states
  bool _isLoadingFlow = false;
  bool _isLoadingClassification = false;
  bool _isCancelled = false;
  String? _errorMessage;

  // Essential data
  String? _riverName;
  String? _formattedLocation;
  double? _currentFlow;
  String? _flowCategory;
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _loadDataProgressively();
  }

  @override
  void dispose() {
    _isCancelled = true;
    super.dispose();
  }

  String _formatFlow(double flow) {
    final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;

    // Format the value (no conversion needed)
    String formattedValue;
    if (flow >= 1000000) {
      formattedValue = '${(flow / 1000000).toStringAsFixed(1)}M';
    } else if (flow >= 1000) {
      formattedValue = '${(flow / 1000).toStringAsFixed(1)}K';
    } else if (flow >= 100) {
      formattedValue = flow.toStringAsFixed(0);
    } else {
      formattedValue = flow.toStringAsFixed(1);
    }

    return '$formattedValue $currentUnit';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [_buildHeader(), _buildContent(), _buildActions()],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.systemGrey5.resolveFrom(context),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Stream order icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppConstants.getStreamOrderColor(
                widget.selectedReach.streamOrder,
              ).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              AppConstants.getStreamOrderIcon(widget.selectedReach.streamOrder),
              color: AppConstants.getStreamOrderColor(
                widget.selectedReach.streamOrder,
              ),
              size: 24,
            ),
          ),
          const SizedBox(width: 12),

          // Title and subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Show loading state until we have the real river name
                if (_riverName != null)
                  Text(
                    _riverName!,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  )
                else if (_isLoadingFlow)
                  Row(
                    children: [
                      Container(
                        width: 120,
                        height: 18,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey4.resolveFrom(
                            context,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CupertinoActivityIndicator(radius: 6),
                      ),
                    ],
                  )
                else
                  Text(
                    widget
                        .selectedReach
                        .displayName, // Fallback if loading failed
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  widget.selectedReach.streamOrderDescription,
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),

          // Loading indicator or close button
          if (_isLoadingFlow)
            const CupertinoActivityIndicator(radius: 8)
          else
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(context),
              child: Icon(
                CupertinoIcons.xmark_circle_fill,
                color: CupertinoColors.systemGrey2.resolveFrom(context),
                size: 24,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          _buildBasicInfo(),
          if (_errorMessage != null) _buildErrorCard(),
          if (_currentFlow != null) _buildCurrentFlowCard(),
          if (_currentFlow == null && !_isLoadingFlow && _errorMessage == null)
            _buildNoFlowDataCard(),
        ],
      ),
    );
  }

  Widget _buildBasicInfo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.separator.resolveFrom(context),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('Reach ID', widget.selectedReach.reachId),
          const SizedBox(height: 8),
          _buildInfoRow('Stream Order', '${widget.selectedReach.streamOrder}'),
          const SizedBox(height: 8),
          _buildInfoRow('Coordinates', widget.selectedReach.coordinatesString),
          if (_formattedLocation?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            _buildInfoRow('Location', _formattedLocation!),
          ] else if (widget.selectedReach.hasLocation) ...[
            const SizedBox(height: 8),
            _buildInfoRow('Location', widget.selectedReach.formattedLocation),
          ],
        ],
      ),
    );
  }

  Widget _buildCurrentFlowCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _getFlowCategoryColor().withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _getFlowCategoryColor().withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.drop_fill,
                color: _getFlowCategoryColor(),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Current Flow',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const Spacer(),
              // Show classification loading state
              if (_isLoadingClassification)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CupertinoActivityIndicator(radius: 6),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _formatFlow(_currentFlow!),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          _buildFlowClassification(),
        ],
      ),
    );
  }

  Widget _buildFlowClassification() {
    if (_flowCategory != null) {
      // Show classification with confidence
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _getFlowCategoryColor(),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          _flowCategory!,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.white,
          ),
        ),
      );
    } else if (_isLoadingClassification) {
      // Show loading state for classification
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey3.resolveFrom(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          'Classifying flow level...',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      );
    } else {
      // Show unavailable state
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey4.resolveFrom(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          'Classification unavailable',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      );
    }
  }

  Widget _buildErrorCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemRed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemRed.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                CupertinoIcons.exclamationmark_triangle,
                color: CupertinoColors.systemRed,
                size: 16,
              ),
              SizedBox(width: 8),
              Text(
                'Loading Error',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.systemRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoFlowDataCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemOrange.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                CupertinoIcons.info_circle,
                color: CupertinoColors.systemOrange,
                size: 16,
              ),
              SizedBox(width: 8),
              Text(
                'Flow Data',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.systemOrange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Current flow data is not available for this reach.',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return ReachActionButtons(
      selectedReach: widget.selectedReach,
      riverName: _riverName,
      formattedLocation: _formattedLocation,
      formattedFlow: _currentFlow != null ? _formatFlow(_currentFlow!) : null,
      flowCategory: _flowCategory,
      latitude: _latitude,
      longitude: _longitude,
    );
  }

  /// Load all reach details via the consolidated service method
  Future<void> _loadDataProgressively() async {
    setState(() {
      _isLoadingFlow = true;
      _isLoadingClassification = true;
      _errorMessage = null;
    });

    try {
      AppLogger.debug(
        'ReachDetailsSheet',
        'Loading details for: ${widget.selectedReach.reachId}',
      );

      final details = await _forecastService.loadReachDetailsData(
        widget.selectedReach.reachId,
      );

      if (_isCancelled || !mounted) return;

      setState(() {
        _riverName = details.riverName;
        _formattedLocation = details.formattedLocation;
        _currentFlow = details.currentFlow;
        _flowCategory = details.flowCategory;
        _latitude = details.latitude;
        _longitude = details.longitude;
        _isLoadingFlow = false;
        _isLoadingClassification = false;
      });

      AppLogger.info(
        'ReachDetailsSheet',
        'Details loaded, flow: $_currentFlow, category: $_flowCategory',
      );
    } catch (error) {
      if (_isCancelled) return;
      AppLogger.error('ReachDetailsSheet', 'Error loading details', error);

      final userMessage = ErrorService.handleError(
        error,
        context: 'loadReachDetails',
      );

      if (!mounted) return;
      setState(() {
        _errorMessage = userMessage;
        _isLoadingFlow = false;
        _isLoadingClassification = false;
      });
    }
  }

  Color _getFlowCategoryColor() {
    // Use the existing AppConstants method for consistent colors
    return AppConstants.getFlowCategoryColor(_flowCategory);
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ),
      ],
    );
  }

}
