// lib/features/favorites/widgets/favorite_river_card.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:rivrflow/core/providers/reach_data_provider.dart';
import 'package:rivrflow/core/services/flow_unit_preference_service.dart';
import '../../../core/models/favorite_river.dart';
import '../../../core/providers/favorites_provider.dart';
import '../services/flood_risk_video_service.dart';
import 'components/slide_action_buttons.dart';
import 'components/slide_action_constants.dart';

/// Individual favorite river card with Cupertino design
/// Supports slide actions, loading states, video backgrounds, and tap navigation
class FavoriteRiverCard extends StatefulWidget {
  final FavoriteRiver favorite;
  final VoidCallback? onTap;
  final VoidCallback? onRename;
  final VoidCallback? onChangeImage;
  final bool isReorderable;

  const FavoriteRiverCard({
    super.key,
    required this.favorite,
    this.onTap,
    this.onRename,
    this.onChangeImage,
    this.isReorderable = true,
  });

  @override
  State<FavoriteRiverCard> createState() => _FavoriteRiverCardState();
}

class _FavoriteRiverCardState extends State<FavoriteRiverCard>
    with TickerProviderStateMixin {
  bool _isPressed = false;
  bool _isSliding = false;
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;

  // Video background state
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  String? _currentVideoPath;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _initializeVideoBackground();
  }

  @override
  void dispose() {
    _slideController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _initializeVideoBackground() async {
    // For now, skip video initialization and use gradients
    // This prevents the PlatformException while video assets are being set up
    if (mounted) {
      setState(() {
        _isVideoInitialized = false;
      });
    }

    final category = _getFloodRiskCategory();
    final videoPath = FloodRiskVideoService.getVideoForCategory(category);

    if (_currentVideoPath != videoPath) {
      await _videoController?.dispose();

      _currentVideoPath = videoPath;
      _videoController = VideoPlayerController.asset(videoPath);

      try {
        await _videoController!.initialize();
        await _videoController!.setLooping(true);
        await _videoController!.setVolume(0.0); // Mute the video
        await _videoController!.play();

        if (mounted) {
          setState(() {
            _isVideoInitialized = true;
          });
        }
      } catch (e) {
        print('Failed to initialize video: $e');
        if (mounted) {
          setState(() {
            _isVideoInitialized = false;
          });
        }
      }
    }
  }

  String _getFloodRiskCategory() {
    // Get current flow and reach data from provider
    final reachDataProvider = context.read<ReachDataProvider>();
    final reachData = reachDataProvider.currentReach;
    final currentFlow = reachDataProvider.getCurrentFlow();

    if (reachData == null ||
        currentFlow == null ||
        !reachData.hasReturnPeriods) {
      return 'Normal'; // Default when no classification data available
    }

    // Get user's preferred flow unit
    final flowUnitService = FlowUnitPreferenceService();
    final currentUnit = flowUnitService.currentFlowUnit;

    // Get flood category using ReachData classification
    return reachData.getFlowCategory(currentFlow, currentUnit);
  }

  @override
  Widget build(BuildContext context) {
    // Calculate slide offset based on screen width
    final screenWidth = MediaQuery.of(context).size.width;
    final slideOffset = SlideActionConstants.getSlideOffset(screenWidth);

    // Set up slide animation with calculated offset
    _slideAnimation =
        Tween<Offset>(begin: Offset.zero, end: Offset(slideOffset, 0)).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeInOut),
        );

    return Consumer<FavoritesProvider>(
      builder: (context, favoritesProvider, child) {
        final isRefreshing = favoritesProvider.isRefreshing(
          widget.favorite.reachId,
        );

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 19, vertical: 6),
          child: GestureDetector(
            onTap: _isSliding ? null : widget.onTap,
            onLongPress: widget.isReorderable ? null : _handleLongPress,
            onPanStart: _handlePanStart,
            onPanUpdate: _handlePanUpdate,
            onPanEnd: _handlePanEnd,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              transform: Matrix4.identity()..scale(_isPressed ? 0.98 : 1.0),
              child: Stack(
                children: [
                  // Action buttons (show when sliding)
                  if (_isSliding) _buildActionButtons(favoritesProvider),

                  // Main card content
                  SlideTransition(
                    position: _slideAnimation,
                    child: _buildCardContent(isRefreshing),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCardContent(bool isRefreshing) {
    return Container(
      width: double.infinity,
      height: 210,
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Video background (or fallback)
            _buildVideoBackground(),

            // Content overlay
            _buildContentOverlay(isRefreshing),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoBackground() {
    if (_isVideoInitialized && _videoController != null) {
      return Positioned.fill(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _videoController!.value.size.width,
            height: _videoController!.value.size.height,
            child: VideoPlayer(_videoController!),
          ),
        ),
      );
    } else {
      // Fallback to gradient while video loads or if video fails
      return _buildDefaultGradient();
    }
  }

  Widget _buildDefaultGradient() {
    // Generate gradient based on flood risk category
    final category = _getFloodRiskCategory();
    final colors = _getGradientColorsForCategory(category);

    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
        ),
      ),
    );
  }

  List<Color> _getGradientColorsForCategory(String category) {
    switch (category.toLowerCase()) {
      case 'normal':
        return [
          CupertinoColors.systemBlue.withOpacity(0.8),
          CupertinoColors.systemTeal.withOpacity(0.8),
        ];
      case 'action':
        return [
          CupertinoColors.systemYellow.withOpacity(0.8),
          CupertinoColors.systemOrange.withOpacity(0.8),
        ];
      case 'moderate':
        return [
          CupertinoColors.systemOrange.withOpacity(0.8),
          CupertinoColors.systemRed.withOpacity(0.8),
        ];
      case 'major':
        return [
          CupertinoColors.systemRed.withOpacity(0.8),
          CupertinoColors.systemPink.withOpacity(0.8),
        ];
      case 'extreme':
        return [
          CupertinoColors.systemPurple.withOpacity(0.8),
          CupertinoColors.systemIndigo.withOpacity(0.8),
        ];
      default:
        return [
          CupertinoColors.systemGrey.withOpacity(0.8),
          CupertinoColors.systemGrey2.withOpacity(0.8),
        ];
    }
  }

  Widget _buildContentOverlay(bool isRefreshing) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              CupertinoColors.black.withOpacity(0.0),
              CupertinoColors.black.withOpacity(0.7),
            ],
            stops: const [0.0, 1.0],
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row with flood risk badge and loading indicator
            Row(
              children: [
                // Flood risk badge
                _buildFloodRiskBadge(),
                const Spacer(),
                if (isRefreshing)
                  const CupertinoActivityIndicator(
                    color: CupertinoColors.white,
                    radius: 8,
                  ),
              ],
            ),

            const Spacer(),

            // Bottom content
            _buildBottomContent(),
          ],
        ),
      ),
    );
  }

  Widget _buildFloodRiskBadge() {
    final category = _getFloodRiskCategory();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getBadgeColor(category),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        category.toUpperCase(),
        style: const TextStyle(
          color: CupertinoColors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _getBadgeColor(String category) {
    switch (category.toLowerCase()) {
      case 'normal':
        return CupertinoColors.systemBlue;
      case 'action':
        return CupertinoColors.systemYellow;
      case 'moderate':
        return CupertinoColors.systemOrange;
      case 'major':
        return CupertinoColors.systemRed;
      case 'extreme':
        return CupertinoColors.systemPurple;
      case 'nodata':
      case 'unknown':
        return CupertinoColors.systemGrey;
      default:
        return CupertinoColors.systemGrey;
    }
  }

  Widget _buildBottomContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // River name
        Text(
          widget.favorite.displayName,
          style: const TextStyle(
            color: CupertinoColors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),

        const SizedBox(height: 4),

        // Flow information
        Row(
          children: [
            Icon(
              CupertinoIcons.drop,
              color: CupertinoColors.white.withOpacity(0.8),
              size: 14,
            ),
            const SizedBox(width: 4),
            Text(
              widget.favorite.formattedFlow,
              style: TextStyle(
                color: CupertinoColors.white.withOpacity(0.9),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),

            // Data freshness indicator
            if (widget.favorite.lastUpdated != null) ...[
              const SizedBox(width: 8),
              Icon(
                widget.favorite.isFlowDataStale
                    ? CupertinoIcons.exclamationmark_circle
                    : CupertinoIcons.checkmark_circle,
                color: widget.favorite.isFlowDataStale
                    ? CupertinoColors.systemYellow
                    : CupertinoColors.systemGreen.withOpacity(0.8),
                size: 12,
              ),
            ],
          ],
        ),

        // Last updated info (if stale)
        if (widget.favorite.isFlowDataStale &&
            widget.favorite.lastUpdated != null) ...[
          const SizedBox(height: 2),
          Text(
            _getLastUpdatedText(),
            style: TextStyle(
              color: CupertinoColors.white.withOpacity(0.7),
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  // Simplified action buttons using the new component
  Widget _buildActionButtons(FavoritesProvider favoritesProvider) {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: SlideActionButtons(
        favorite: widget.favorite,
        favoritesProvider: favoritesProvider,
        onCloseSlide: _closeSlide,
        onChangeImage: widget.onChangeImage,
        onRename: widget.onRename,
      ),
    );
  }

  String _getLastUpdatedText() {
    if (widget.favorite.lastUpdated == null) return '';

    final now = DateTime.now();
    final difference = now.difference(widget.favorite.lastUpdated!);

    if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  // Gesture handling for slide actions
  void _handlePanStart(DragStartDetails details) {
    setState(() {
      _isPressed = true;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    // Only respond to horizontal gestures to avoid interfering with vertical reorder drags
    final horizontalDelta = details.delta.dx.abs();
    final verticalDelta = details.delta.dy.abs();

    // Only trigger slide actions if the gesture is primarily horizontal
    if (horizontalDelta > verticalDelta) {
      if (details.delta.dx < -5 && !_isSliding) {
        // More sensitive swipe detection - swiping left shows actions
        setState(() {
          _isSliding = true;
        });
        _slideController.forward();
      } else if (details.delta.dx > 5 && _isSliding) {
        // Swiping right hides actions
        _closeSlide();
      }
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    setState(() {
      _isPressed = false;
    });
  }

  void _handleLongPress() {
    // Provide haptic feedback when starting to reorder
    HapticFeedback.mediumImpact();

    // Optional: Add a subtle visual indicator that reorder mode is active
    setState(() {
      _isPressed = true;
    });

    // Reset after a short delay
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _isPressed = false;
        });
      }
    });
  }

  void _closeSlide() {
    if (_isSliding) {
      setState(() {
        _isSliding = false;
      });
      _slideController.reverse();
    }
  }
}
