// lib/features/map/widgets/reach_details_bottom_sheet.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/services/forecast_service.dart';
import '../../../core/services/error_service.dart';
import '../../../core/services/flow_unit_preference_service.dart';
import '../../../core/providers/favorites_provider.dart';
import '../../../core/constants.dart';
import '../models/selected_reach.dart';

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
  final ForecastService _forecastService = ForecastService();

  // Progressive loading states
  bool _isLoadingFlow = false;
  bool _isLoadingClassification = false;
  String? _errorMessage;

  // Essential data
  String? _riverName;
  String? _formattedLocation;
  double? _currentFlow;
  String? _flowCategory;
  double? _latitude;
  double? _longitude;

  // Favorites toggle state
  bool _isTogglingFavorite = false;

  @override
  void initState() {
    super.initState();
    _loadDataProgressively();
  }

  // Get current flow units from preference service
  String _getCurrentFlowUnit() {
    final currentUnit = FlowUnitPreferenceService().currentFlowUnit;
    return currentUnit; // Returns 'CFS' or 'CMS' directly
  }

  // Calculate flow category using already-converted values
  String _calculateFlowCategory(double? currentFlow, dynamic reach) {
    if (currentFlow == null || reach?.returnPeriods == null) {
      return 'Unknown';
    }

    final currentUnit = _getCurrentFlowUnit();

    // No conversion needed - flow is already in user's preferred unit from API service
    return reach.getFlowCategory(currentFlow, currentUnit);
  }

  String _formatFlow(double flow) {
    // FIXED: Use flow directly (already in user's preferred unit from API service)
    final currentUnit = _getCurrentFlowUnit();

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
              ).withOpacity(0.15),
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
        color: _getFlowCategoryColor().withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _getFlowCategoryColor().withOpacity(0.3),
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
        color: CupertinoColors.systemRed.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemRed.withOpacity(0.3),
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
        color: CupertinoColors.systemOrange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemOrange.withOpacity(0.3),
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // View Forecast button (primary action)
          Expanded(
            flex: 2,
            child: CupertinoButton.filled(
              onPressed: () {
                Navigator.pushNamed(
                  context,
                  '/forecast',
                  arguments: widget.selectedReach.reachId,
                );
              },
              child: const Text('View Forecast'),
            ),
          ),

          const SizedBox(width: 12),

          // Heart button with cached data optimization
          Expanded(
            child: Consumer<FavoritesProvider>(
              builder: (context, favoritesProvider, child) {
                final isFavorited = favoritesProvider.isFavorite(
                  widget.selectedReach.reachId,
                );

                return CupertinoButton(
                  color: isFavorited
                      ? CupertinoColors.systemRed.withOpacity(0.1)
                      : CupertinoColors.tertiarySystemGroupedBackground
                            .resolveFrom(context),
                  onPressed: _isTogglingFavorite
                      ? null
                      : () => _toggleFavoriteOptimized(favoritesProvider),
                  child: _isTogglingFavorite
                      ? const CupertinoActivityIndicator(radius: 8)
                      : Icon(
                          isFavorited
                              ? CupertinoIcons.heart_fill
                              : CupertinoIcons.heart,
                          color: isFavorited
                              ? CupertinoColors.systemRed
                              : CupertinoColors.systemGrey.resolveFrom(context),
                        ),
                );
              },
            ),
          ),

          const SizedBox(width: 12),

          // More options
          CupertinoButton(
            color: CupertinoColors.tertiarySystemGroupedBackground.resolveFrom(
              context,
            ),
            onPressed: _showMoreOptions,
            child: Icon(
              CupertinoIcons.ellipsis,
              color: CupertinoColors.systemGrey.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  // FIXED: Progressive loading with corrected flow classification
  Future<void> _loadDataProgressively() async {
    setState(() {
      _isLoadingFlow = true;
      _errorMessage = null;
    });

    try {
      print(
        'BOTTOM_SHEET: Starting progressive loading for: ${widget.selectedReach.reachId}',
      );

      // STEP 1: Load overview data (current flow) - FAST
      final overviewFuture = _forecastService.loadOverviewData(
        widget.selectedReach.reachId,
      );

      // STEP 2: Load return periods separately (if not cached) - PARALLEL
      final returnPeriodsFuture = _loadReturnPeriodsIfNeeded(
        widget.selectedReach.reachId,
      );

      // Wait for overview data first (shows flow immediately)
      final forecast = await overviewFuture;

      if (!mounted) return;
      setState(() {
        _riverName = forecast.reach.riverName;
        _formattedLocation = forecast.reach.formattedLocation;
        _currentFlow = _forecastService.getCurrentFlow(
          forecast,
        ); // Already converted!
        _latitude = forecast.reach.latitude;
        _longitude = forecast.reach.longitude;
        _isLoadingFlow = false;

        // Check if we already have return periods (cached)
        if (forecast.reach.hasReturnPeriods && _currentFlow != null) {
          // FIXED: Use flow directly (already converted by API service)
          _flowCategory = _calculateFlowCategory(_currentFlow!, forecast.reach);
        } else if (_currentFlow != null) {
          // We have flow but not return periods yet
          _isLoadingClassification = true;
        }
      });

      print(
        'BOTTOM_SHEET: ✅ Overview data loaded, current flow: $_currentFlow',
      );

      // STEP 3: Wait for return periods and update classification
      await returnPeriodsFuture;
    } catch (error) {
      print('BOTTOM_SHEET: ❌ Error in progressive loading: $error');

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

  // FIXED: Load return periods with corrected flow classification
  Future<void> _loadReturnPeriodsIfNeeded(String reachId) async {
    try {
      // Check if we already have cached return periods
      final isReturnPeriodsCached = await _forecastService.isReachCached(
        reachId,
      );

      if (isReturnPeriodsCached) {
        print('BOTTOM_SHEET: Return periods already cached');
        return; // Already have them from overview loading
      }

      print('BOTTOM_SHEET: Loading return periods for classification...');

      // Load supplementary data (return periods) - this is lightweight
      final currentForecast = await _forecastService.loadOverviewData(reachId);
      final enhancedForecast = await _forecastService.loadSupplementaryData(
        reachId,
        currentForecast,
      );

      // Update flow classification if we now have return periods
      if (enhancedForecast.reach.hasReturnPeriods && _currentFlow != null) {
        // FIXED: Use flow directly (already converted by API service)
        final flowCategory = _calculateFlowCategory(
          _currentFlow!,
          enhancedForecast.reach,
        );

        if (!mounted) return;
        setState(() {
          _flowCategory = flowCategory;
          _isLoadingClassification = false;
        });

        print('BOTTOM_SHEET: ✅ Flow classification updated: $flowCategory');
      } else {
        if (!mounted) return;
        setState(() {
          _isLoadingClassification = false;
        });
        print(
          'BOTTOM_SHEET: ⚠️ Return periods not available for classification',
        );
      }
    } catch (e) {
      print('BOTTOM_SHEET: ⚠️ Failed to load return periods: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingClassification = false;
      });
      // Don't throw - classification is nice-to-have
    }
  }

  // Fast favorite toggle using cached coordinates
  Future<void> _toggleFavoriteOptimized(
    FavoritesProvider favoritesProvider,
  ) async {
    final reachId = widget.selectedReach.reachId;
    final isFavorited = favoritesProvider.isFavorite(reachId);

    if (!mounted) return;
    setState(() {
      _isTogglingFavorite = true;
    });

    try {
      bool success;
      if (isFavorited) {
        success = await favoritesProvider.removeFavorite(reachId);
        if (success) {
          _showFeedback('Removed from favorites');
        }
      } else {
        // Use coordinates we already loaded
        if (_latitude != null && _longitude != null) {
          success = await favoritesProvider.addFavoriteWithKnownCoordinates(
            reachId,
            latitude: _latitude!,
            longitude: _longitude!,
            riverName: _riverName,
          );
        } else {
          success = await favoritesProvider.addFavorite(reachId);
        }

        if (success) {
          _showFeedback('Added to favorites');
        }
      }

      if (!success) {
        _showFeedback('Failed to update favorites', isError: true);
      }
    } catch (e) {
      print('BOTTOM_SHEET: Error toggling favorite: $e');
      _showFeedback('Failed to update favorites', isError: true);
    }

    if (!mounted) return;
    setState(() {
      _isTogglingFavorite = false;
    });
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

  void _showFeedback(String message, {bool isError = false}) {
    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showMoreOptions() {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text('${widget.selectedReach.displayName} Options'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _copyReachInfo();
            },
            child: const Text('Copy Reach Info'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _shareLocation();
            },
            child: const Text('Share Location'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _openInMaps();
            },
            child: const Text('Open in Maps'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  Future<void> _copyReachInfo() async {
    try {
      final text = _buildReachInfoText();
      await Clipboard.setData(ClipboardData(text: text));
      _showFeedback('Reach information copied to clipboard');
    } catch (e) {
      print('BOTTOM_SHEET: Error copying reach info: $e');
    }
  }

  Future<void> _shareLocation() async {
    try {
      final text = _buildLocationShareText();
      await Share.share(text, subject: widget.selectedReach.displayName);
    } catch (e) {
      print('BOTTOM_SHEET: Error sharing location: $e');
    }
  }

  Future<void> _openInMaps() async {
    try {
      final coords = widget.selectedReach.coordinatesString.split(', ');
      if (coords.length == 2) {
        final lat = coords[0];
        final lng = coords[1];
        final url = 'https://maps.google.com/?q=$lat,$lng';
        if (await canLaunchUrl(Uri.parse(url))) {
          await launchUrl(Uri.parse(url));
        }
      }
    } catch (e) {
      print('BOTTOM_SHEET: Error opening maps: $e');
    }
  }

  String _buildReachInfoText() {
    final buffer = StringBuffer();

    buffer.writeln(_riverName ?? widget.selectedReach.displayName);
    buffer.writeln('Reach ID: ${widget.selectedReach.reachId}');
    buffer.writeln('🌊 Stream Order: ${widget.selectedReach.streamOrder}');
    buffer.writeln('📍 Coordinates: ${widget.selectedReach.coordinatesString}');

    if (_formattedLocation?.isNotEmpty == true) {
      buffer.writeln('📍 Location: $_formattedLocation');
    } else if (widget.selectedReach.hasLocation) {
      buffer.writeln('📍 Location: ${widget.selectedReach.formattedLocation}');
    }

    if (_currentFlow != null) {
      buffer.writeln('\n💧 Current Flow: ${_formatFlow(_currentFlow!)}');
      if (_flowCategory != null) {
        buffer.writeln('Risk Level: $_flowCategory');
      }
    }

    buffer.writeln('\n📱 Shared from RivrFlow');
    return buffer.toString();
  }

  String _buildLocationShareText() {
    final buffer = StringBuffer();

    buffer.writeln('📍 ${_riverName ?? widget.selectedReach.displayName}');
    buffer.writeln(
      '\n📍 Coordinates: ${widget.selectedReach.coordinatesString}',
    );

    if (_formattedLocation?.isNotEmpty == true) {
      buffer.writeln('📍 $_formattedLocation');
    } else if (widget.selectedReach.hasLocation) {
      buffer.writeln('📍 ${widget.selectedReach.formattedLocation}');
    }

    if (_currentFlow != null && _flowCategory != null) {
      buffer.writeln(
        '\n💧 Current Flow: ${_formatFlow(_currentFlow!)} ($_flowCategory)',
      );
    }

    final coords = widget.selectedReach.coordinatesString.split(', ');
    if (coords.length == 2) {
      final lat = coords[0];
      final lng = coords[1];
      buffer.writeln('\n🗺️ View on Google Maps:');
      buffer.writeln('https://maps.google.com/?q=$lat,$lng');
    }

    buffer.writeln('\n📱 Shared from RivrFlow');
    return buffer.toString();
  }
}
