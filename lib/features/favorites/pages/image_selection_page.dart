// lib/features/favorites/pages/image_selection_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/favorites_provider.dart';

/// Image selection page for choosing custom favorite river images
/// Features categorized browsing with grid layout
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

  // Image categories with their respective image assets
  final List<ImageCategory> _categories = [
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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Choose Image'),
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
        child: Column(
          children: [
            _buildCategorySelector(),
            Expanded(child: _buildImageGrid()),
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
          // ✅ THEME-AWARE STYLING - Let Cupertino handle theme adaptation automatically
          backgroundColor: CupertinoColors.systemGrey6.resolveFrom(context),
          thumbColor: CupertinoColors.systemBackground.resolveFrom(context),
          children: {
            for (int i = 0; i < _categories.length; i++)
              i: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _categories[i].icon,
                      size: 16,
                      // ✅ FIXED: Now properly shows selected vs unselected states with theme awareness
                      color: _selectedCategoryIndex == i
                          ? CupertinoColors.activeBlue.resolveFrom(context)
                          : CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _categories[i].shortName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _selectedCategoryIndex == i
                            ? FontWeight
                                  .w600 // Bold for selected
                            : FontWeight.w500, // Medium for unselected
                        // ✅ FIXED: Now properly shows selected vs unselected states with theme awareness
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
                childAspectRatio: 1.3, // Slightly wider than square
              ),
              itemCount: category.images.length,
              itemBuilder: (context, index) {
                final imagePath = category.images[index];
                final isSelected = _selectedImagePath == imagePath;

                return _buildImageTile(imagePath, isSelected);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageTile(String imagePath, bool isSelected) {
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
              Image.asset(
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
        // Just navigate back immediately - the updated image will be visible in favorites
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
