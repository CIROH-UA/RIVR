// lib/features/favorites/widgets/image_category_grid.dart

import 'package:flutter/cupertino.dart';

/// Reusable grid component for displaying and selecting images within a category
/// Handles image preview, selection state, and asset path management
class ImageCategoryGrid extends StatefulWidget {
  final List<String> imagePaths;
  final String? selectedImagePath;
  final Function(String?) onSelectionChanged;
  final int crossAxisCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double childAspectRatio;
  final bool enabled;
  final String? categoryName;

  const ImageCategoryGrid({
    super.key,
    required this.imagePaths,
    required this.onSelectionChanged,
    this.selectedImagePath,
    this.crossAxisCount = 2,
    this.crossAxisSpacing = 12.0,
    this.mainAxisSpacing = 12.0,
    this.childAspectRatio = 1.3,
    this.enabled = true,
    this.categoryName,
  });

  @override
  State<ImageCategoryGrid> createState() => _ImageCategoryGridState();
}

class _ImageCategoryGridState extends State<ImageCategoryGrid> {
  String? _localSelectedPath;

  @override
  void initState() {
    super.initState();
    _localSelectedPath = widget.selectedImagePath;
  }

  @override
  void didUpdateWidget(ImageCategoryGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedImagePath != oldWidget.selectedImagePath) {
      _localSelectedPath = widget.selectedImagePath;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imagePaths.isEmpty) {
      return _buildEmptyState();
    }

    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.crossAxisCount,
        crossAxisSpacing: widget.crossAxisSpacing,
        mainAxisSpacing: widget.mainAxisSpacing,
        childAspectRatio: widget.childAspectRatio,
      ),
      itemCount: widget.imagePaths.length,
      itemBuilder: (context, index) {
        final imagePath = widget.imagePaths[index];
        final isSelected = _localSelectedPath == imagePath;

        return ImageTile(
          imagePath: imagePath,
          isSelected: isSelected,
          enabled: widget.enabled,
          onTap: () => _handleImageSelection(imagePath),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.photo_on_rectangle,
            size: 48,
            color: CupertinoColors.systemGrey.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            widget.categoryName != null
                ? 'No images available for ${widget.categoryName}'
                : 'No images available',
            style: const TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _handleImageSelection(String imagePath) {
    if (!widget.enabled) return;

    setState(() {
      // Toggle selection: if already selected, deselect; otherwise select
      _localSelectedPath = _localSelectedPath == imagePath ? null : imagePath;
    });

    // Notify parent of selection change
    widget.onSelectionChanged(_localSelectedPath);
  }
}

/// Individual image tile component
/// Handles image display, selection state, and user interaction
class ImageTile extends StatefulWidget {
  final String imagePath;
  final bool isSelected;
  final bool enabled;
  final VoidCallback? onTap;

  const ImageTile({
    super.key,
    required this.imagePath,
    required this.isSelected,
    required this.enabled,
    this.onTap,
  });

  @override
  State<ImageTile> createState() => _ImageTileState();
}

class _ImageTileState extends State<ImageTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.enabled ? _handleTapDown : null,
      onTapUp: widget.enabled ? _handleTapUp : null,
      onTapCancel: widget.enabled ? _handleTapCancel : null,
      onTap: widget.enabled ? widget.onTap : null,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: _buildTileContent(),
          );
        },
      ),
    );
  }

  Widget _buildTileContent() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: widget.isSelected
            ? Border.all(color: CupertinoColors.activeBlue, width: 3)
            : Border.all(
                color: CupertinoColors.separator.withValues(alpha: 0.3),
                width: 1,
              ),
        boxShadow: [
          BoxShadow(
            color: widget.isSelected
                ? CupertinoColors.activeBlue.withValues(alpha: 0.2)
                : CupertinoColors.systemGrey.withValues(alpha: 0.15),
            blurRadius: widget.isSelected ? 12 : 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Main image
            _buildImage(),

            // Selection overlay
            if (widget.isSelected) _buildSelectionOverlay(),

            // Subtle gradient for depth (when not selected)
            if (!widget.isSelected) _buildGradientOverlay(),

            // Disabled overlay
            if (!widget.enabled) _buildDisabledOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildImage() {
    return Image.asset(
      widget.imagePath,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return _buildImageError();
      },
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;

        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          child: child,
        );
      },
    );
  }

  Widget _buildImageError() {
    return Container(
      color: CupertinoColors.systemGrey6,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.photo,
            color: CupertinoColors.systemGrey,
            size: MediaQuery.of(context).size.width > 400 ? 32 : 24,
          ),
          const SizedBox(height: 8),
          Text(
            'Image\nUnavailable',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: CupertinoColors.systemGrey,
              fontSize: MediaQuery.of(context).size.width > 400 ? 12 : 10,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionOverlay() {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.activeBlue.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Icon(
          CupertinoIcons.checkmark_circle_fill,
          color: CupertinoColors.white,
          size: 40,
        ),
      ),
    );
  }

  Widget _buildGradientOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 30,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              CupertinoColors.black.withValues(alpha: 0.0),
              CupertinoColors.black.withValues(alpha: 0.2),
            ],
          ),
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildDisabledOverlay() {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  void _handleTapDown(TapDownDetails details) {
    _animationController.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    _animationController.reverse();
  }

  void _handleTapCancel() {
    _animationController.reverse();
  }
}

/// Utility class for managing image asset paths
class ImageAssetManager {
  static const String _baseImagePath = 'assets/images/rivers';

  /// Generate asset paths for a specific category
  static List<String> getImagePaths(String category, int count) {
    return List.generate(
      count,
      (index) =>
          '$_baseImagePath/$category/${category}_river_${index + 1}.webp',
    );
  }

  /// Get all available categories with their image counts
  static Map<String, List<String>> getAllCategories() {
    return {
      'mountain': getImagePaths('mountain', 6),
      'urban': getImagePaths('urban', 6),
      'desert': getImagePaths('desert', 6),
      'big_water': getImagePaths('big_water', 6),
    };
  }

  /// Validate if an asset path exists (basic path format check)
  static bool isValidAssetPath(String path) {
    return path.startsWith(_baseImagePath) &&
        path.endsWith('.webp') &&
        path.contains('rivers/');
  }

  /// Extract category name from asset path
  static String? getCategoryFromPath(String path) {
    if (!isValidAssetPath(path)) return null;

    final parts = path.split('/');
    if (parts.length >= 4) {
      return parts[3]; // assets/images/rivers/[category]/...
    }
    return null;
  }

  /// Extract image filename from asset path
  static String? getFilenameFromPath(String path) {
    if (!isValidAssetPath(path)) return null;

    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : null;
  }
}
