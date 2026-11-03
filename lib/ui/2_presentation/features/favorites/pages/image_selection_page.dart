// lib/ui/2_presentation/features/favorites/pages/image_selection_page.dart

import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/services/1_contracts/shared/i_background_image_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';

/// Image selection page for choosing custom favorite river images
/// Features categorized browsing with grid layout + custom upload support
class ImageSelectionPage extends StatefulWidget {
  final String reachId;

  const ImageSelectionPage({super.key, required this.reachId});

  @override
  State<ImageSelectionPage> createState() => _ImageSelectionPageState();
}

class _ImageSelectionPageState extends State<ImageSelectionPage> {
  /// Index 0 is "Custom Images", which is empty for everybody who has never
  /// uploaded one — so opening there showed a new user an empty screen with
  /// two dozen bundled backgrounds hidden one tap away. Open on the first
  /// category that actually has pictures in it.
  int _selectedCategoryIndex = _firstStockCategory;
  static const int _customCategory = 0;
  static const int _firstStockCategory = 1;
  String? _selectedImagePath;
  bool _isUpdating = false;
  bool _isUploading = false;
  List<String> _customImages = [];

  final IBackgroundImageService _backgroundService = GetIt.I<IBackgroundImageService>();
  final IUserSettingsService _settingsService = GetIt.I<IUserSettingsService>();

  // Image categories with custom images as first category
  late final List<ImageCategory> _categories;

  /// The background this river is using right now, if any. Shown as a badge
  /// and preselected, because the picker used to give no clue which of the
  /// two dozen images you already had.
  String? _appliedImagePath;

  @override
  void initState() {
    super.initState();
    _initializeCategories();
    _loadCustomImages();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readAppliedImage());
  }

  void _readAppliedImage() {
    if (!mounted) return;
    final applied = context
        .read<FavoritesProvider>()
        .favorites
        .where((f) => f.reachId == widget.reachId)
        .firstOrNull
        ?.customImageAsset;
    if (applied == null) return;

    setState(() {
      _appliedImagePath = applied;
      _selectedImagePath = applied;
      for (var i = 0; i < _categories.length; i++) {
        if (_categories[i].images.contains(applied)) {
          _selectedCategoryIndex = i;
          return;
        }
      }
      if (_customImages.contains(applied)) {
        _selectedCategoryIndex = _customCategory;
      }
    });
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
      AppLogger.error('ImageSelectionPage', 'Error loading custom images', e);
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
        // Always present, disabled when there is nothing new to save. It
        // used to be built only when a selection existed, so it appeared and
        // disappeared from the navigation bar as you tapped around.
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: (_isUpdating ||
                  _selectedImagePath == null ||
                  _selectedImagePath == _appliedImagePath)
              ? null
              : _saveSelection,
          child: _isUpdating
              ? const CupertinoActivityIndicator(radius: 8)
              : const Text('Save'),
        ),
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

  /// One primary, one secondary.
  ///
  /// These used to be two filled pills side by side — blue "Flow animation"
  /// next to green "Upload image" — reading as two equally important
  /// actions, in a colour iOS does not use for a primary. And "Flow
  /// animation" never said what it actually does, which is take the photo
  /// off and put the animated water back.
  Widget _buildButtonRow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _uploadButton(),
        const SizedBox(height: 4),
        CupertinoButton(
          onPressed: _isUpdating ? null : _resetToDefault,
          child: Text(
            'Remove photo, use flow animation',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.systemBlue.resolveFrom(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUploadButton() => Center(child: _uploadButton());

  Widget _uploadButton() {
    return CupertinoButton(
      onPressed: _isUploading ? null : _uploadCustomImage,
      borderRadius: BorderRadius.circular(25),
      color: CupertinoColors.systemBlue,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
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
              // The selection SURVIVES a category change. Clearing it meant
              // glancing at another category threw away the image you had
              // picked, and took the Save button with it.
              setState(() => _selectedCategoryIndex = value);
            }
          },
          backgroundColor: CupertinoColors.systemGrey6.resolveFrom(context),
          thumbColor: CupertinoColors.systemBackground.resolveFrom(context),
          children: {
            // No icons. Five segments with an icon each forced the label to
            // 10 pt, below the size iOS treats as legible and fixed against
            // Dynamic Type. The label alone says it.
            for (int i = 0; i < _categories.length; i++)
              i: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(
                  _categories[i].shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: _selectedCategoryIndex == i
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: _selectedCategoryIndex == i
                        ? CupertinoColors.label.resolveFrom(context)
                        : CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
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
          // The segmented control above already names the category; a header
          // repeating it with the same icon two rows down cost ~44 pt of
          // grid and said nothing new.
          if (isCustomCategory && _customImages.isNotEmpty) ...[
            Text(
              '${_customImages.length} of your own image${_customImages.length == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Image grid
          Expanded(
            child: GridView.builder(
              // Room for the floating buttons, which otherwise sit on top of
              // the last row of images permanently.
              padding: const EdgeInsets.only(bottom: 96),
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
    final isApplied = imagePath == _appliedImagePath;

    return GestureDetector(
      onTap: _isUpdating ? null : () => _selectImage(imagePath),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // The border is always 3 pt wide, transparent when unselected.
          // Adding it only on selection changed the box and shifted the
          // picture by 3 pt as you tapped.
          border: Border.all(
            color: isSelected
                ? CupertinoColors.activeBlue
                : const Color(0x00000000),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.systemGrey.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            fit: StackFit.expand,
            children: [
              isCustomImage
                  ? Image.file(
                      File(imagePath),
                      fit: BoxFit.cover,
                      semanticLabel: 'Custom river background image',
                      errorBuilder: (context, error, stackTrace) =>
                          _buildImageError(),
                    )
                  : Image.asset(
                      imagePath,
                      fit: BoxFit.cover,
                      semanticLabel: 'River background image',
                      errorBuilder: (context, error, stackTrace) =>
                          _buildImageError(),
                    ),

              // Selection overlay
              if (isSelected)
                Container(
                  color: CupertinoColors.activeBlue.withValues(alpha: 0.3),
                  child: const Center(
                    child: Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: CupertinoColors.white,
                      size: 40,
                    ),
                  ),
                ),

              // Which one you are already using. Without it the picker gave
              // no way to tell your current background from the other 23.
              if (isApplied)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: CupertinoColors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'In use',
                      style: TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),

              // Delete, on your own images only.
              //
              // It is shown whether or not the tile is selected — it used to
              // vanish the moment you tapped the picture, so the one you had
              // just looked at was the one you could not remove. The icon is
              // 16 pt inside a 44 pt target, which is Apple's minimum; it
              // used to be a 28 pt target.
              if (isCustomImage)
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showDeleteConfirmation(imagePath),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemBackground
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    CupertinoColors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(
                            CupertinoIcons.trash_fill,
                            size: 16,
                            color: CupertinoColors.systemRed,
                            semanticLabel: 'Delete this image',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // The 40 pt black gradient that used to sit along the bottom of
              // every unselected tile is gone. It was there "for better
              // contrast", but nothing is written on a tile — so it only
              // darkened the picture the user is trying to judge.
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteConfirmation(String imagePath) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete Image'),
        content: const Text(
          'Are you sure you want to delete your image? This action cannot be undone.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(context);
              _deleteCustomImage(imagePath);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteCustomImage(String imagePath) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    if (authProvider.currentUser == null) return;

    try {
      // Delete from file system
      final success = await _backgroundService.deleteCustomBackground(
        imagePath,
      );

      if (success) {
        // Remove from user settings
        await _settingsService.removeCustomBackgroundImage(
          authProvider.currentUser!.uid,
          imagePath,
        );

        // Refresh the custom images list
        await _loadCustomImages();

        // If the deleted image was selected, clear selection
        if (_selectedImagePath == imagePath) {
          setState(() {
            _selectedImagePath = null;
          });
        }

        HapticFeedback.lightImpact();
      } else {
        _showErrorMessage('Failed to delete image. Please try again.');
      }
    } catch (e) {
      _showErrorMessage('Error deleting image: ${e.toString()}');
    }
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
          _selectedCategoryIndex = _customCategory;
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
        return 'Big Water';
      default:
        return name;
    }
  }
}
