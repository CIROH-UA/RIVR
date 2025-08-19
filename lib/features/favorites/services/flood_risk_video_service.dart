// lib/features/favorites/services/flood_risk_video_service.dart

/// Service for mapping flood risk categories to video background assets
class FloodRiskVideoService {
  static const String _baseVideoPath = 'assets/videos';

  /// Map of flood risk categories to video file paths
  static const Map<String, String> _categoryVideoMap = {
    'Normal': '$_baseVideoPath/Normal-Risk.mp4',
    'Action': '$_baseVideoPath/Action-Risk.mp4',
    'Moderate': '$_baseVideoPath/Moderate-Risk.mp4',
    'Major': '$_baseVideoPath/Major-Risk.mp4',
    'Extreme': '$_baseVideoPath/Extreme-Risk.mp4',
  };

  /// Default fallback video for unknown categories
  static const String _defaultVideo = '$_baseVideoPath/Normal-Risk.mp4';

  /// Get video asset path for a flood risk category
  static String getVideoForCategory(String category) {
    return _categoryVideoMap[category] ?? _defaultVideo;
  }

  /// Check if a category has an associated video
  static bool hasVideoForCategory(String category) {
    return _categoryVideoMap.containsKey(category);
  }

  /// Get all available flood risk categories
  static List<String> getAllCategories() {
    return _categoryVideoMap.keys.toList();
  }

  /// Get all video asset paths
  static List<String> getAllVideoPaths() {
    return _categoryVideoMap.values.toList();
  }

  /// Validate video asset path format
  static bool isValidVideoPath(String path) {
    return path.startsWith(_baseVideoPath) &&
        path.endsWith('.mp4') &&
        _categoryVideoMap.values.contains(path);
  }
}
