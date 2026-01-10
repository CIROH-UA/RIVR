// lib/core/config.dart
//
// config.dart should be for:
// * Critical infrastructure that could break the app
// * Environment-specific values (API keys, URLs)
// * Performance settings that affect functionality
// * Constants used across multiple features
//
class AppConfig {
  // NOAA National Water Model APIs
  static const String noaaReachesBaseUrl = 'https://api.water.noaa.gov/nwps/v1';
  static const String noaaReachesEndpoint = '/reaches/'; // + reachId

  // NWM Return Periods API
  static const String nwmReturnPeriodUrl =
      'https://nwm-api.ciroh.org//return-period';
  static const String nwmApiKey = 'INSERT-THE-KEY';

  // Mapbox Configuration
  static const String mapboxPublicToken = 'INSERT-THE-KEY';
  static const String mapboxSearchApiUrl =
      'https://api.mapbox.com/geocoding/v5/mapbox.places/';
  static const String mapboxStyleUrl = 'mapbox://styles/mapbox/standard';

  // Vector Tiles Infrastructure
  static const String vectorTilesetId = 'byu-hydroinformatics.nwm-channels';
  static const String vectorSourceId = 'streams2-source';
  static const String vectorSourceLayer = 'channels';
  static const String vectorLayerId = 'streams2-layer';

  // Helper methods for Vector Tiles Infrastructure
  static String getVectorTileSourceUrl() => 'mapbox://$vectorTilesetId';

  // Default Settings
  static const String defaultDisplayUnit = 'cfs';
  static const String defaultReturnPeriodUnit = 'cms';

  // Performance Settings (affect functionality across features)
  static const Duration httpTimeout = Duration(seconds: 30);
  static const int defaultRefreshInterval = 300; // 5 minutes in seconds

  // Map Performance Settings
  static const double defaultZoom = 9.0;
  static const double minZoomForMarkers = 8.0;
  static const double minZoomForVectorTiles = 7.0;
  static const double maxZoomForVectorTiles = 13.0;
  static const double tapAreaRadius = 12.0; // Pixels around tap for selection
  static const int searchResultLimit = 5;

  // Stream Order Performance Thresholds (used across map features)
  static const Map<String, double> streamOrderZoomThresholds = {
    'major_rivers': 7.0, // Show stream order 8+ at zoom 7+
    'tributaries': 9.0, // Show stream order 5-7 at zoom 9+
    'small_streams': 11.0, // Show stream order 1-4 at zoom 11+
  };

  // Utah center coordinates (fallback location)
  static const double defaultLatitude = 40.233845;
  static const double defaultLongitude = -111.658531;

  // Helper methods for API URLs
  static String getForecastUrl(String reachId, String series) =>
      '$noaaReachesBaseUrl/reaches/$reachId/streamflow?series=$series';

  static String getReachUrl(String reachId) =>
      '$noaaReachesBaseUrl/reaches/$reachId';

  static String getReturnPeriodUrl(String reachId) =>
      '$nwmReturnPeriodUrl?comids=$reachId&key=$nwmApiKey';

  /// Check if stream order should be visible at zoom level (performance optimization)
  static bool shouldShowStreamOrder(int streamOrder, double zoom) {
    if (streamOrder >= 8) {
      return zoom >= streamOrderZoomThresholds['major_rivers']!;
    }
    if (streamOrder >= 5) {
      return zoom >= streamOrderZoomThresholds['tributaries']!;
    }
    return zoom >= streamOrderZoomThresholds['small_streams']!;
  }
}
