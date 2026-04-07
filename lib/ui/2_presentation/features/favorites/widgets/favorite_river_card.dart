// lib/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/services/4_infrastructure/favorites/flood_risk_video_service.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/components/slide_action_buttons.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/components/slide_action_constants.dart';

/// Individual favorite river card with Cupertino design
/// Supports slide actions, loading states, video backgrounds, custom image overlays, and tap navigation
class FavoriteRiverCard extends StatefulWidget {
  final FavoriteRiver favorite;
  final VoidCallback? onTap;
  final VoidCallback? onRename;
  final VoidCallback? onChangeImage;
  final bool isReorderable;
  final int cardIndex;

  const FavoriteRiverCard({
    super.key,
    required this.favorite,
    this.onTap,
    this.onRename,
    this.onChangeImage,
    this.isReorderable = true,
    this.cardIndex = 0,
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
  double _dragStartX = 0.0;
  bool _wasOpenBeforeDrag = false;

  // Video background state
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  String? _currentVideoPath;
  bool _isInitializingVideo = false;
  bool _needsVideoReinitialize = false;
  DateTime? _lastPlayRetryTime;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _initializeVideoBackground();
  }

  @override
  void didUpdateWidget(FavoriteRiverCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Reinitialize video when switching from custom image to null
    if (oldWidget.favorite.customImageAsset != null &&
        widget.favorite.customImageAsset == null) {
      AppLogger.debug(
        'FavoriteRiverCard',
        'Switching from custom image to video for ${widget.favorite.reachId}',
      );

      // Properly dispose existing controller first
      _removePlaybackListener();
      _videoController?.dispose();
      _videoController = null;
      _currentVideoPath = null;
      setState(() {
        _isVideoInitialized = false;
      });

      // Then reinitialize
      _initializeVideoBackground();
    }
    // Dispose video when switching from null to custom image
    else if (oldWidget.favorite.customImageAsset == null &&
        widget.favorite.customImageAsset != null) {
      AppLogger.debug(
        'FavoriteRiverCard',
        'Switching from video to custom image for ${widget.favorite.reachId}',
      );
      _removePlaybackListener();
      _videoController?.dispose();
      _videoController = null;
      setState(() {
        _isVideoInitialized = false;
      });
    }
  }

  @override
  void dispose() {
    _slideController.dispose();
    _removePlaybackListener();
    _videoController?.dispose();
    super.dispose();
  }

  void _addPlaybackListener() {
    _videoController?.addListener(_onVideoPlaybackChanged);
  }

  void _removePlaybackListener() {
    _videoController?.removeListener(_onVideoPlaybackChanged);
  }

  void _onVideoPlaybackChanged() {
    if (_videoController == null || !mounted || _isInitializingVideo) return;
    final value = _videoController!.value;

    // Detect silent stop: initialized, not playing, not buffering, no error
    if (value.isInitialized &&
        !value.isPlaying &&
        !value.isBuffering &&
        !value.hasError) {
      // 1-second cooldown prevents tight retry loops
      final now = DateTime.now();
      if (_lastPlayRetryTime != null &&
          now.difference(_lastPlayRetryTime!) < const Duration(seconds: 1)) {
        return;
      }
      _lastPlayRetryTime = now;
      _videoController!.play();
    }
  }

  Future<void> _initializeVideoBackground() async {
    if (_isInitializingVideo) {
      _needsVideoReinitialize = true;
      return;
    }

    final category = _getFloodRiskCategory();
    final videoPath = FloodRiskVideoService.getVideoForCategory(category);

    // Skip if correct video is already playing
    if (_currentVideoPath == videoPath && _isVideoInitialized) return;

    _isInitializingVideo = true;
    _needsVideoReinitialize = false;

    try {
      // Clean up old controller
      final oldController = _videoController;
      if (oldController != null) {
        _removePlaybackListener();
        _videoController = null;
        await oldController.dispose();
      }

      _currentVideoPath = videoPath;

      // Stagger initialization across cards to avoid exhausting
      // hardware decoder slots on Android (typically 3-6 slots).
      if (widget.cardIndex > 0) {
        await Future.delayed(Duration(milliseconds: 100 * widget.cardIndex));
        if (!mounted) return;
      }

      // Use local variable during async gap
      final controller = VideoPlayerController.asset(
        videoPath,
        // Allow background audio (e.g. music) to continue playing
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0.0);
      await controller.play();

      if (mounted) {
        _videoController = controller;
        _addPlaybackListener();
        setState(() {
          _isVideoInitialized = true;
        });
      } else {
        // Widget was disposed during init — clean up the local controller
        await controller.dispose();
      }
    } catch (e) {
      AppLogger.error('FavoriteRiverCard', 'Failed to initialize video', e);
      if (mounted) {
        setState(() {
          _isVideoInitialized = false;
        });
      }
    } finally {
      _isInitializingVideo = false;
      if (_needsVideoReinitialize && mounted) {
        _needsVideoReinitialize = false;
        _initializeVideoBackground();
      }
    }
  }

  String _getFloodRiskCategory() {
    final rawFlow = widget.favorite.lastKnownFlow;
    if (rawFlow == null) {
      AppLogger.debug(
        'FavoriteRiverCard',
        '${widget.favorite.displayName} (${widget.favorite.reachId}) - Flood Risk: NoData (no flow)',
      );
      return 'NoData';
    }

    // Get return periods from FavoritesProvider for this specific favorite
    final favoritesProvider = context.read<FavoritesProvider>();
    final returnPeriods = favoritesProvider.getReturnPeriods(
      widget.favorite.reachId,
    );

    if (returnPeriods == null || returnPeriods.isEmpty) {
      AppLogger.debug(
        'FavoriteRiverCard',
        '${widget.favorite.displayName} (${widget.favorite.reachId}) - Flood Risk: NoData (no return periods)',
      );
      return 'NoData';
    }

    // Get user's preferred flow unit
    final flowUnitService = GetIt.I<IFlowUnitPreferenceService>();
    final currentUnit = flowUnitService.currentFlowUnit;

    // Convert the flow value to current unit before comparison
    final currentFlow = flowUnitService.convertFlow(
      rawFlow,
      'CFS', // lastKnownFlow is stored in CFS
      currentUnit, // Convert to current unit
    );

    // Convert return periods to current unit (they're stored in CMS)
    final convertedReturnPeriods = <int, double>{};
    for (final entry in returnPeriods.entries) {
      convertedReturnPeriods[entry.key] = flowUnitService.convertFlow(
        entry.value,
        'CMS',
        currentUnit,
      );
    }

    // Use same logic as ReachData.getFlowCategory()
    final threshold2yr = convertedReturnPeriods[2];
    final threshold5yr = convertedReturnPeriods[5];
    final threshold10yr = convertedReturnPeriods[10];
    final threshold25yr = convertedReturnPeriods[25];

    String category;
    if (threshold2yr != null && currentFlow < threshold2yr) {
      category = 'Normal';
    } else if (threshold5yr != null && currentFlow < threshold5yr) {
      category = 'Action';
    } else if (threshold10yr != null && currentFlow < threshold10yr) {
      category = 'Moderate';
    } else if (threshold25yr != null && currentFlow < threshold25yr) {
      category = 'Major';
    } else {
      category = 'Extreme';
    }

    AppLogger.debug(
      'FavoriteRiverCard',
      '${widget.favorite.displayName} (${widget.favorite.reachId}) - Current: ${currentFlow.toStringAsFixed(1)} $currentUnit, Flood Risk: $category',
    );
    return category;
  }

  @override
  Widget build(BuildContext context) {
    // Calculate slide offset based on screen width
    final screenWidth = MediaQuery.of(context).size.width;
    final slideOffset = SlideActionConstants.getSlideOffset(screenWidth);

    // Set up slide animation with calculated offset
    _slideAnimation =
        Tween<Offset>(begin: Offset.zero, end: Offset(slideOffset, 0)).animate(
          _slideController,
        );

    return Consumer<FavoritesProvider>(
      builder: (context, favoritesProvider, child) {
        final isRefreshing = favoritesProvider.isRefreshing(
          widget.favorite.reachId,
        );

        // Check if flood risk category changed and reinitialize video
        final newCategory = _getFloodRiskCategory();
        final expectedVideoPath = FloodRiskVideoService.getVideoForCategory(
          newCategory,
        );

        if (widget.favorite.customImageAsset == null &&
            (_currentVideoPath != expectedVideoPath || !_isVideoInitialized)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initializeVideoBackground();
          });
        }

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
              transform: Matrix4.identity()..scaleByDouble(_isPressed ? 0.98 : 1.0, _isPressed ? 0.98 : 1.0, 1.0, 1.0),
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
      height: 120,
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Background: either custom image OR video (not both)
            if (widget.favorite.customImageAsset != null)
              _buildCustomImageBackground()
            else
              _buildVideoBackground(),

            // Content overlay
            _buildContentOverlay(isRefreshing),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoBackground() {
    // Check if video is initialized, controller exists, AND hasn't been disposed
    if (_isVideoInitialized &&
        _videoController != null &&
        _videoController!.value.isInitialized) {
      try {
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
      } catch (e) {
        // If accessing controller throws error (disposed), fall back to gradient
        AppLogger.error('FavoriteRiverCard', 'Video controller error', e);
        return _buildDefaultGradient();
      }
    } else {
      // Fallback to gradient while video loads or if video fails
      return _buildDefaultGradient();
    }
  }

  Widget _buildCustomImageBackground() {
    return Positioned.fill(
      child: Image.asset(
        widget.favorite.customImageAsset!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          // If custom image fails, fall back to video
          AppLogger.error(
            'FavoriteRiverCard',
            'Failed to load custom image: ${widget.favorite.customImageAsset}',
          );
          return _buildVideoBackground();
        },
      ),
    );
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
          CupertinoColors.systemBlue.withValues(alpha: 0.8),
          CupertinoColors.systemTeal.withValues(alpha: 0.8),
        ];
      case 'action':
        return [
          CupertinoColors.systemYellow.withValues(alpha: 0.8),
          CupertinoColors.systemOrange.withValues(alpha: 0.8),
        ];
      case 'moderate':
        return [
          CupertinoColors.systemOrange.withValues(alpha: 0.8),
          CupertinoColors.systemRed.withValues(alpha: 0.8),
        ];
      case 'major':
        return [
          CupertinoColors.systemRed.withValues(alpha: 0.8),
          CupertinoColors.systemPink.withValues(alpha: 0.8),
        ];
      case 'extreme':
        return [
          CupertinoColors.systemPurple.withValues(alpha: 0.8),
          CupertinoColors.systemIndigo.withValues(alpha: 0.8),
        ];
      case 'nodata':
      case 'unknown':
        return [
          CupertinoColors.systemGrey.withValues(alpha: 0.8),
          CupertinoColors.systemGrey2.withValues(alpha: 0.8),
        ];
      default:
        return [
          CupertinoColors.systemGrey.withValues(alpha: 0.8),
          CupertinoColors.systemGrey2.withValues(alpha: 0.8),
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
              CupertinoColors.black.withValues(alpha: 0.0),
              CupertinoColors.black.withValues(alpha: 0.7),
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
              color: CupertinoColors.white.withValues(alpha: 0.8),
              size: 14,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                widget.favorite.formattedFlow(
                  convertFlow: GetIt.I<IFlowUnitPreferenceService>().convertFlow,
                  currentUnit: GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit,
                ),
                style: TextStyle(
                  color: CupertinoColors.white.withValues(alpha: 0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
                    : CupertinoColors.systemGreen.withValues(alpha: 0.8),
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
              color: CupertinoColors.white.withValues(alpha: 0.7),
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
    _dragStartX = details.globalPosition.dx;
    _wasOpenBeforeDrag = _isSliding;
    setState(() {
      _isPressed = true;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    final horizontalDelta = details.delta.dx.abs();
    final verticalDelta = details.delta.dy.abs();

    if (horizontalDelta > verticalDelta) {
      final dragDistance = _dragStartX - details.globalPosition.dx;

      double newValue;
      if (_wasOpenBeforeDrag) {
        // Dragging right from open state closes proportionally
        newValue = 1.0 - (-dragDistance / SlideActionConstants.totalActionWidth);
      } else {
        newValue = dragDistance / SlideActionConstants.totalActionWidth;
      }
      newValue = newValue.clamp(0.0, 1.0);

      if (!_isSliding && newValue > 0.0) {
        setState(() {
          _isSliding = true;
        });
      }

      _slideController.value = newValue;
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    setState(() {
      _isPressed = false;
    });

    if (!_isSliding) return;

    final velocity = details.velocity.pixelsPerSecond.dx;

    if (velocity.abs() > 300) {
      // Fast swipe: animate in the direction of velocity
      if (velocity < 0) {
        // Swiping left — open
        _slideController.animateTo(1.0, curve: Curves.easeOut);
      } else {
        // Swiping right — close
        _slideController.animateTo(0.0, curve: Curves.easeOut).then((_) {
          if (mounted) setState(() => _isSliding = false);
        });
      }
    } else {
      // Slow drag: settle based on position
      if (_slideController.value > 0.3) {
        _slideController.animateTo(1.0, curve: Curves.easeOut);
      } else {
        _slideController.animateTo(0.0, curve: Curves.easeOut).then((_) {
          if (mounted) setState(() => _isSliding = false);
        });
      }
    }
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
