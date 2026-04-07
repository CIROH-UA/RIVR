// lib/utils/river_image_utility.dart

import 'dart:math';

/// Utility class for managing random river image assignment
/// Uses reachId as seed for consistent image selection per river
class RiverImageUtility {
  static const List<String> _allRiverImages = [
    // Mountain Rivers
    'assets/images/rivers/mountain/mountain_river_1.webp',
    'assets/images/rivers/mountain/mountain_river_2.webp',
    'assets/images/rivers/mountain/mountain_river_3.webp',
    'assets/images/rivers/mountain/mountain_river_4.webp',
    'assets/images/rivers/mountain/mountain_river_5.webp',
    'assets/images/rivers/mountain/mountain_river_6.webp',

    // Urban Rivers
    'assets/images/rivers/urban/urban_river_1.webp',
    'assets/images/rivers/urban/urban_river_2.webp',
    'assets/images/rivers/urban/urban_river_3.webp',
    'assets/images/rivers/urban/urban_river_4.webp',
    'assets/images/rivers/urban/urban_river_5.webp',
    'assets/images/rivers/urban/urban_river_6.webp',

    // Desert Rivers
    'assets/images/rivers/desert/desert_river_1.webp',
    'assets/images/rivers/desert/desert_river_2.webp',
    'assets/images/rivers/desert/desert_river_3.webp',
    'assets/images/rivers/desert/desert_river_4.webp',
    'assets/images/rivers/desert/desert_river_5.webp',
    'assets/images/rivers/desert/desert_river_6.webp',

    // Big Water
    'assets/images/rivers/big_water/big_water_1.webp',
    'assets/images/rivers/big_water/big_water_2.webp',
    'assets/images/rivers/big_water/big_water_3.webp',
    'assets/images/rivers/big_water/big_water_4.webp',
    'assets/images/rivers/big_water/big_water_5.webp',
    'assets/images/rivers/big_water/big_water_6.webp',
  ];

  /// Get a consistent random image for a river based on its reachId
  /// Same reachId will always return the same image for consistency
  static String getDefaultImageForRiver(String reachId) {
    if (_allRiverImages.isEmpty) {
      // Fallback in case no images are available
      return 'assets/images/rivers/mountain/mountain_river_1.webp';
    }

    // Use reachId as seed for consistent selection
    final seed = _generateSeedFromReachId(reachId);
    final random = Random(seed);
    final index = random.nextInt(_allRiverImages.length);

    return _allRiverImages[index];
  }

  /// Get a completely random image (different each time)
  /// Useful for testing or when true randomness is needed
  static String getRandomImage() {
    if (_allRiverImages.isEmpty) {
      return 'assets/images/rivers/mountain/mountain_river_1.webp';
    }

    final random = Random();
    final index = random.nextInt(_allRiverImages.length);
    return _allRiverImages[index];
  }

  /// Get all available images
  static List<String> getAllImages() {
    return List.unmodifiable(_allRiverImages);
  }

  /// Get images from a specific category
  static List<String> getImagesFromCategory(String category) {
    return _allRiverImages
        .where((image) => image.contains('/$category/'))
        .toList();
  }

  /// Get the category name from an image path
  static String? getCategoryFromImage(String imagePath) {
    if (imagePath.contains('/mountain/')) return 'mountain';
    if (imagePath.contains('/urban/')) return 'urban';
    if (imagePath.contains('/desert/')) return 'desert';
    if (imagePath.contains('/big_water/')) return 'big_water';
    return null;
  }

  /// Check if an image path is valid
  static bool isValidImage(String imagePath) {
    return _allRiverImages.contains(imagePath);
  }

  /// Generate a consistent seed from reachId for deterministic randomness
  static int _generateSeedFromReachId(String reachId) {
    // Convert reachId to a consistent integer seed
    int seed = 0;
    for (int i = 0; i < reachId.length; i++) {
      seed = seed * 31 + reachId.codeUnitAt(i);
    }
    return seed.abs(); // Ensure positive seed
  }

  /// Get image statistics for debugging
  static Map<String, dynamic> getImageStats() {
    final categories = {
      'mountain': getImagesFromCategory('mountain'),
      'urban': getImagesFromCategory('urban'),
      'desert': getImagesFromCategory('desert'),
      'big_water': getImagesFromCategory('big_water'),
    };

    return {
      'totalImages': _allRiverImages.length,
      'categories': categories.map((key, value) => MapEntry(key, value.length)),
      'categoriesDetail': categories,
    };
  }

  /// Preview what image a reachId would get (for testing)
  static Map<String, String> previewImageForReaches(List<String> reachIds) {
    final results = <String, String>{};
    for (final reachId in reachIds) {
      results[reachId] = getDefaultImageForRiver(reachId);
    }
    return results;
  }
}
