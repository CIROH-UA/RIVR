// lib/ui/2_presentation/features/map/widgets/components/reach_action_buttons.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';

/// Extracted action buttons for the reach details bottom sheet.
/// Handles: View Forecast, favorite toggle, share, copy, open in maps.
class ReachActionButtons extends StatefulWidget {
  final SelectedReach selectedReach;
  final String? riverName;
  final String? formattedLocation;
  final String? formattedFlow;
  final String? flowCategory;
  final double? latitude;
  final double? longitude;
  final double? currentFlow;

  const ReachActionButtons({
    super.key,
    required this.selectedReach,
    this.riverName,
    this.formattedLocation,
    this.formattedFlow,
    this.flowCategory,
    this.latitude,
    this.longitude,
    this.currentFlow,
  });

  @override
  State<ReachActionButtons> createState() => _ReachActionButtonsState();
}

class _ReachActionButtonsState extends State<ReachActionButtons> {
  bool _isTogglingFavorite = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // View Forecast button (primary action)
          Expanded(
            flex: 2,
            child: CupertinoButton.filled(
              onPressed: () {
                AppRouter.pushForecast(
                  context,
                  reachId: widget.selectedReach.reachId,
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
                      ? CupertinoColors.systemRed.withValues(alpha: 0.1)
                      : CupertinoColors
                            .tertiarySystemGroupedBackground
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
                              : CupertinoColors.systemGrey.resolveFrom(
                                  context,
                                ),
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
        if (widget.latitude != null && widget.longitude != null) {
          success = await favoritesProvider.addFavoriteWithKnownCoordinates(
            reachId,
            latitude: widget.latitude!,
            longitude: widget.longitude!,
            riverName: widget.riverName,
            currentFlow: widget.currentFlow,
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
      AppLogger.error('ReachActionButtons', 'Error toggling favorite', e);
      _showFeedback('Failed to update favorites', isError: true);
    }

    if (!mounted) return;
    setState(() {
      _isTogglingFavorite = false;
    });
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
              Future.delayed(const Duration(milliseconds: 350), _copyReachInfo);
            },
            child: const Text('Copy Info'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              Future.delayed(
                  const Duration(milliseconds: 350), _shareLocation);
            },
            child: const Text('Share Location'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              Future.delayed(const Duration(milliseconds: 350), _openInMaps);
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
      AppLogger.error('ReachActionButtons', 'Error copying reach info', e);
    }
  }

  Future<void> _shareLocation() async {
    try {
      final text = _buildLocationShareText();
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: widget.selectedReach.displayName,
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (e) {
      AppLogger.error('ReachActionButtons', 'Error sharing location', e);
      _showFeedback('Unable to share. Please try again.', isError: true);
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
      AppLogger.error('ReachActionButtons', 'Error opening maps', e);
    }
  }

  String _buildReachInfoText() {
    final buffer = StringBuffer();

    buffer.writeln(widget.riverName ?? widget.selectedReach.displayName);
    buffer.writeln('Reach ID: ${widget.selectedReach.reachId}');
    buffer.writeln(
      '\u{1F30A} Stream Order: ${widget.selectedReach.streamOrder}',
    );
    buffer.writeln(
      '\u{1F4CD} Coordinates: ${widget.selectedReach.coordinatesString}',
    );

    if (widget.formattedLocation?.isNotEmpty == true) {
      buffer.writeln('\u{1F4CD} Location: ${widget.formattedLocation}');
    } else if (widget.selectedReach.hasLocation) {
      buffer.writeln(
        '\u{1F4CD} Location: ${widget.selectedReach.formattedLocation}',
      );
    }

    if (widget.formattedFlow != null) {
      buffer.writeln('\n\u{1F4A7} Current Flow: ${widget.formattedFlow}');
      if (widget.flowCategory != null) {
        buffer.writeln('Risk Level: ${widget.flowCategory}');
      }
    }

    buffer.writeln('\n\u{1F4F1} Shared from RIVR');
    return buffer.toString();
  }

  String _buildLocationShareText() {
    final buffer = StringBuffer();

    buffer.writeln(
      '\u{1F4CD} ${widget.riverName ?? widget.selectedReach.displayName}',
    );
    buffer.writeln(
      '\n\u{1F4CD} Coordinates: ${widget.selectedReach.coordinatesString}',
    );

    if (widget.formattedLocation?.isNotEmpty == true) {
      buffer.writeln('\u{1F4CD} ${widget.formattedLocation}');
    } else if (widget.selectedReach.hasLocation) {
      buffer.writeln(
        '\u{1F4CD} ${widget.selectedReach.formattedLocation}',
      );
    }

    if (widget.formattedFlow != null && widget.flowCategory != null) {
      buffer.writeln(
        '\n\u{1F4A7} Current Flow: ${widget.formattedFlow} (${widget.flowCategory})',
      );
    }

    final coords = widget.selectedReach.coordinatesString.split(', ');
    if (coords.length == 2) {
      final lat = coords[0];
      final lng = coords[1];
      buffer.writeln('\n\u{1F5FA}\u{FE0F} View on Google Maps:');
      buffer.writeln('https://maps.google.com/?q=$lat,$lng');
    }

    buffer.writeln('\n\u{1F4F1} Shared from RIVR');
    return buffer.toString();
  }
}
