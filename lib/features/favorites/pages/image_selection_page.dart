// lib/features/favorites/pages/image_selection_page.dart

import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/favorites_provider.dart';
import '../../../core/services/background_image_service.dart';
import '../../../features/auth/services/user_settings_service.dart';
import '../../../features/auth/providers/auth_provider.dart';

/// Image selection page for choosing custom favorite river images
/// Features categorized browsing with grid layout + custom upload support
class ImageSelectionPage extends StatefulWidget {
  final String reachId;

  const ImageSelectionPage({super.key, required this.reachId});

  @override
  State<ImageSelectionPage> createState() => _ImageSelectionPageState();
}

class _ImageSelectionPageState extends State<ImageSelectionPage> {
  int _selectedCategoryIndex = 0;
  String? _selectedImagePath;
  bool _isUpdating = false;
  bool _isUploading = false;
  List<String> _customImages = [];

  final BackgroundImageService _backgroundService = BackgroundImageService();
  final UserSettingsService _settingsService = UserSettingsService();

  // Image categories with custom images as first category
  late final List<ImageCategory> _categories;

  @override
  void initState() {
    super.initState();
    _initializeCategories();
    _loadCustomImages();
  }

  void _initializeCategories() {
    _categories = [
      // Custom images category (index 0)
      ImageCategory(
        name: 'Custom Images',
        icon: CupertinoIcons.camera_fill,
        images: [], // Will be populated with _customImages
      ),
      // Existing asset categories
      ImageCategory(
        name: 'Mountain Rivers',
        icon: CupertinoIcons.snow,
        images: [
          'assets/images/rivers/mountain/mountain_river_1.webp',
          'assets/images/rivers/mountain/mountain_river_2.webp',
          'assets/images/rivers/mountain/mountain_river_3.webp',
          'assets/images/rivers/mountain/mountain_river_4.webp',
          'assets/images/rivers/mountain/mountain_river_5.webp',
          'assets/images/rivers/mountain/mountain_river_6.webp',
        ],
      ),
      ImageCategory(
        name: 'Urban Rivers',
        icon: CupertinoIcons.building_2_fill,
        images: [
          'assets/images/rivers/urban/urban_river_1.webp',
          'assets/images/rivers/urban/urban_river_2.webp',
          'assets/images/rivers/urban/urban_river_3.webp',
          'assets/images/rivers/urban/urban_river_4.webp',
          'assets/images/rivers/urban/urban_river_5.webp',
          'assets/images/rivers/urban/urban_river_6.webp',
        ],
      ),
      ImageCategory(
        name: 'Desert Rivers',
        icon: CupertinoIcons.sun_max,
        images: [
          'assets/images/rivers/desert/desert_river_1.webp',
          'assets/images/rivers/desert/desert_river_2.webp',
          'assets/images/rivers/desert/desert_river_3.webp',
          'assets/images/rivers/desert/desert_river_4.webp',
          'assets/images/rivers/desert/desert_river_5.webp',
          'assets/images/rivers/desert/desert_river_6.webp',
        ],
      ),
      ImageCategory(
        name: 'Big Water',
        icon: CupertinoIcons.drop_fill,
        images: [
          'assets/images/rivers/big_water/big_water_1.webp',
          'assets/images/rivers/big_water/big_water_2.webp',
          'assets/images/rivers/big_water/big_water_3.webp',
          'assets/images/rivers/big_water/big_water_4.webp',
          'assets/images/rivers/big_water/big_water_5.webp',
          'assets/images/rivers/big_water/big_water_6.webp',
        ],
      ),
    ];
  }

  Future<void> _loadCustomImages() async {
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (authProvider.currentUser != null) {
        final customImages = await _settingsService.getUserCustomBackgrounds(
          authProvider.currentUser!.uid,
        );

        setState(() {
          _customImages = customImages;
        });
      }
    } catch (e) {
      print('Error loading custom images: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Choose Background'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _isUpdating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        trailing: _selectedImagePath != null
            ? CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _isUpdating ? null : _saveSelection,
                child: _isUpdating
                    ? const CupertinoActivityIndicator(radius: 8)
                    : const Text('Save'),
              )
            : null,
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildCategorySelector(),
                Expanded(child: _buildImageGrid()),
              ],
            ),
            // Floating buttons (reset + upload)
            _buildFloatingButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingButtons() {
    return Consumer<FavoritesProvider>(
      builder: (context, favoritesProvider, child) {
        // Get current favorite to check if it has a custom image
        final currentFavorite = favoritesProvider.favorites
            .where((f) => f.reachId == widget.reachId)
            .firstOrNull;

        final hasCustomImage = currentFavorite?.customImageAsset != null;

        return Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: hasCustomImage
              ? _buildButtonRow() // Both buttons when custom image is set
              : _buildUploadButton(), // Only upload button when no custom image
        );
      },
    );
  }

  Widget _buildButtonRow() {
    return Row(
      children: [
        // Use flow animation button
        Expanded(
          child: CupertinoButton(
            onPressed: _isUpdating ? null : _resetToDefault,
            borderRadius: BorderRadius.circular(25),
            color: CupertinoColors.systemBlue,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.play_circle,
                  color: CupertinoColors.white,
                  size: 18,
                ),
                const SizedBox(width: 6),
                const Flexible(
                  child: Text(
                    'Flow animation',
                    style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_isUpdating) ...[
                  const SizedBox(width: 8),
                  const CupertinoActivityIndicator(
                    radius: 6,
                    color: CupertinoColors.white,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Upload button
        Expanded(
          child: CupertinoButton(
            onPressed: _isUploading ? null : _uploadCustomImage,
            borderRadius: BorderRadius.circular(25),
            color: CupertinoColors.systemGreen,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.camera,
                  color: CupertinoColors.white,
                  size: 18,
                ),
                const SizedBox(width: 6),
                const Flexible(
                  child: Text(
                    'Upload image',
                    style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_isUploading) ...[
                  const SizedBox(width: 8),
                  const CupertinoActivityIndicator(
                    radius: 6,
                    color: CupertinoColors.white,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUploadButton() {
    return Center(
      child: CupertinoButton(
        onPressed: _isUploading ? null : _uploadCustomImage,
        borderRadius: BorderRadius.circular(25),
        color: CupertinoColors.systemGreen,
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.camera,
              color: CupertinoColors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            const Text(
              'Upload your own image',
              style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_isUploading) ...[
              const SizedBox(width: 12),
              const CupertinoActivityIndicator(
                radius: 8,
                color: CupertinoColors.white,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategorySelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: _selectedCategoryIndex,
          onValueChanged: (value) {
            if (value != null && !_isUpdating) {
              setState(() {
                _selectedCategoryIndex = value;
                _selectedImagePath =
                    null; // Clear selection when switching categories
              });
            }
          },
          backgroundColor: CupertinoColors.systemGrey6.resolveFrom(context),
          thumbColor: CupertinoColors.systemBackground.resolveFrom(context),
          children: {
            for (int i = 0; i < _categories.length; i++)
              i: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _categories[i].icon,
                      size: 14,
                      color: _selectedCategoryIndex == i
                          ? CupertinoColors.activeBlue.resolveFrom(context)
                          : CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _categories[i].shortName,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: _selectedCategoryIndex == i
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: _selectedCategoryIndex == i
                            ? CupertinoColors.activeBlue.resolveFrom(context)
                            : CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
          },
        ),
      ),
    );
  }

  Widget _buildImageGrid() {
    final category = _categories[_selectedCategoryIndex];
    final isCustomCategory = _selectedCategoryIndex == 0;
    final images = isCustomCategory ? _customImages : category.images;

    if (isCustomCategory && _customImages.isEmpty) {
      return _buildEmptyCustomImages();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Category header
          Row(
            children: [
              Icon(category.icon, color: CupertinoColors.activeBlue, size: 20),
              const SizedBox(width: 8),
              Text(
                category.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isCustomCategory && _customImages.isNotEmpty) ...[
                const Spacer(),
                Text(
                  '${_customImages.length} image${_customImages.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // Image grid
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.3,
              ),
              itemCount: images.length,
              itemBuilder: (context, index) {
                final imagePath = images[index];
                final isSelected = _selectedImagePath == imagePath;
                final isCustomImage = isCustomCategory;

                return _buildImageTile(imagePath, isSelected, isCustomImage);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCustomImages() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.camera,
              size: 64,
              color: CupertinoColors.systemGrey.resolveFrom(context),
            ),
            const SizedBox(height: 16),
            const Text(
              'No custom images yet',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Upload your own images to use as backgrounds for your favorite rivers.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildImageTile(
    String imagePath,
    bool isSelected,
    bool isCustomImage,
  ) {
    return GestureDetector(
      onTap: _isUpdating ? null : () => _selectImage(imagePath),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: CupertinoColors.activeBlue, width: 3)
              : null,
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.systemGrey.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Image
              isCustomImage
                  ? Image.file(
                      File(imagePath),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return _buildImageError();
                      },
                    )
                  : Image.asset(
                      imagePath,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return _buildImageError();
                      },
                    ),

              // Selection overlay
              if (isSelected)
                Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.activeBlue.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.white,
                      size: 40,
                    ),
                  ),
                ),

              // Custom image indicator
              if (isCustomImage && !isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBackground.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      CupertinoIcons.camera_fill,
                      size: 14,
                      color: CupertinoColors.activeBlue,
                    ),
                  ),
                ),

              // Gradient overlay for better contrast
              if (!isSelected)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          CupertinoColors.black.withOpacity(0.0),
                          CupertinoColors.black.withOpacity(0.3),
                        ],
                      ),
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageError() {
    return Container(
      color: CupertinoColors.systemGrey6,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.photo,
            color: CupertinoColors.systemGrey,
            size: 32,
          ),
          SizedBox(height: 8),
          Text(
            'Image\nUnavailable',
            textAlign: TextAlign.center,
            style: TextStyle(color: CupertinoColors.systemGrey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _selectImage(String imagePath) {
    setState(() {
      _selectedImagePath = imagePath;
    });
    HapticFeedback.selectionClick();
  }

  Future<void> _uploadCustomImage() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    if (authProvider.currentUser == null) {
      _showErrorMessage('Please sign in to upload custom images');
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      final result = await _backgroundService.showImageSourceSelector(
        context: context,
        userId: authProvider.currentUser!.uid,
      );

      if (result.isSuccess && result.imagePath != null) {
        // Add to user's custom backgrounds collection
        await _settingsService.addCustomBackgroundImage(
          authProvider.currentUser!.uid,
          result.imagePath!,
        );

        // Refresh custom images list
        await _loadCustomImages();

        // Switch to custom category and select the new image
        setState(() {
          _selectedCategoryIndex = 0;
          _selectedImagePath = result.imagePath;
        });

        HapticFeedback.lightImpact();
      } else if (result.error != null && result.error != 'Cancelled') {
        _showErrorMessage(result.error!);
      }
    } catch (e) {
      _showErrorMessage('Failed to upload image: ${e.toString()}');
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  Future<void> _saveSelection() async {
    if (_selectedImagePath == null || _isUpdating) return;

    setState(() {
      _isUpdating = true;
    });

    try {
      final favoritesProvider = context.read<FavoritesProvider>();
      final success = await favoritesProvider.updateFavorite(
        widget.reachId,
        customImageAsset: _selectedImagePath,
      );

      if (success && mounted) {
        Navigator.of(context).pop();
      } else if (mounted) {
        _showErrorMessage('Failed to update image. Please try again.');
      }
    } catch (e) {
      if (mounted) {
        _showErrorMessage('An error occurred: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  Future<void> _resetToDefault() async {
    if (_isUpdating) return;

    setState(() {
      _isUpdating = true;
    });

    try {
      final favoritesProvider = context.read<FavoritesProvider>();
      final success = await favoritesProvider.updateFavorite(
        widget.reachId,
        customImageAsset: null,
      );

      if (success && mounted) {
        Navigator.of(context).pop();
      } else if (mounted) {
        _showErrorMessage('Failed to reset background. Please try again.');
      }
    } catch (e) {
      if (mounted) {
        _showErrorMessage('An error occurred: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  void _showErrorMessage(String message) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Error'),
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
}

/// Data class for image categories
class ImageCategory {
  final String name;
  final IconData icon;
  final List<String> images;

  ImageCategory({required this.name, required this.icon, required this.images});

  /// Short name for segmented control
  String get shortName {
    switch (name) {
      case 'Custom Images':
        return 'Custom';
      case 'Mountain Rivers':
        return 'Mountain';
      case 'Urban Rivers':
        return 'Urban';
      case 'Desert Rivers':
        return 'Desert';
      case 'Big Water':
        return 'Water';
      default:
        return name;
    }
  }
}
