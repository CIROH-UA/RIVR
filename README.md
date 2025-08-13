# RivrFlow

A comprehensive river flow monitoring and flood risk assessment mobile application built with Flutter. RivrFlow democratizes access to the National Water Model developed by NOAA, providing real-time river flow data, flood risk analysis, and interactive forecasting to help all civilians make informed decisions about water safety and recreational activities.

## About the National Water Model

RivrFlow is powered by the **National Water Model (NWM)**, developed by the National Oceanic and Atmospheric Administration (NOAA). The NWM is a cutting-edge hydrologic modeling framework that simulates water flow across the entire continental United States. By leveraging this authoritative government data source, RivrFlow provides civilian users with the same high-quality forecasting information used by emergency managers and water resource professionals.

## Core Features

### Flood Risk Assessment
- **Real-time Risk Categories**: Intelligent classification of river conditions into Normal, Elevated, High, and Flood Risk levels
- **Return Period Analysis**: Advanced statistical analysis using 2-year, 5-year, and 25-year flood thresholds
- **Visual Risk Indicators**: Color-coded warnings and intuitive icons for quick risk assessment
- **Safety-First Design**: Clear warnings and educational content to promote water safety

### Advanced Forecasting
- **Multi-Range Forecasts**: Short-range (hourly), medium-range (daily), and long-range (extended) predictions
- **Interactive Hydrographs**: Detailed flow charts with zoom, pan, and tooltip functionality
- **Ensemble Data**: Comprehensive forecast models with uncertainty visualization
- **Export Capabilities**: Save and share forecast charts as images

### Interactive Mapping
- **Mapbox Integration**: High-quality, responsive maps with multiple base layer options
- **River Reach Selection**: Tap any river segment to view detailed flow information
- **Location Services**: GPS-based navigation to nearby streams and monitoring points
- **Map Customization**: Light/dark themes and auto-switching based on system preferences

### Personal Management
- **Favorites System**: Save and organize frequently monitored river reaches
- **Custom Names & Images**: Personalize favorite locations with custom titles and photos
- **Reorderable Lists**: Drag-and-drop organization of saved locations
- **Quick Access**: One-tap navigation to detailed forecasts for favorite reaches

### User Experience
- **Cupertino Design**: Native iOS-style interface with smooth animations
- **Dark Mode Support**: Automatic theme switching based on system preferences
- **Accessibility**: VoiceOver support and proper contrast ratios
- **Offline Capabilities**: Cached data for improved performance

### Customization
- **Flow Units**: Choose between CFS (Cubic Feet per Second) and CMS (Cubic Meters per Second)
- **Notification Settings**: Customizable alerts for flood conditions (planned feature)
- **Theme Options**: Light, dark, or automatic theme switching
- **Map Preferences**: Auto or manual map style selection

## Who Benefits from RivrFlow?

### Civilian Users
RivrFlow is specifically designed to make professional-grade water forecasting accessible to all civilians, regardless of technical background:

- **Outdoor Enthusiasts**: Rafters, kayakers, anglers, hikers, and campers can assess flow conditions for optimal and safe recreation
- **Families**: Parents can check flood risks before camping or picnicking near waterways
- **Property Owners**: Riverside residents and landowners can stay informed about potential flooding
- **Community Members**: Local residents can monitor conditions affecting neighborhood safety
- **Farmers & Ranchers**: Agricultural users can track water availability and flood risks for their operations
- **Business Owners**: Tourism operators and outdoor businesses can make informed operational decisions

### Professional Applications
While designed for civilian use, RivrFlow also serves professional needs:
- **Emergency Managers**: Monitor flood risks across multiple watersheds
- **Water Resource Managers**: Track flow conditions for operational decisions
- **Researchers**: Access comprehensive flow data and forecasts
- **Infrastructure Managers**: Assess impacts on bridges, roads, and facilities

## Getting Started

### Prerequisites
- Flutter SDK ^3.8.0
- Dart SDK
- iOS 16.6+ or Android API level 21+
- Xcode 14+ (for iOS development)
- Android Studio (for Android development)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/your-username/rivrflow.git
   cd rivrflow
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Configure API Keys and Services**
   
   Create a `lib/core/config.dart` file using the template below and replace placeholder values with your actual API keys:

   ```dart
   // lib/core/config.dart
   class AppConfig {
     // NOAA National Water Model APIs (Public APIs)
     static const String noaaReachesBaseUrl = 'https://api.water.noaa.gov/nwps/v1';
     static const String noaaReachesEndpoint = '/reaches/';

     // NWM Return Periods API (Requires API Key)
     static const String nwmReturnPeriodUrl = 'YOUR_NWM_RETURN_PERIOD_URL';
     static const String nwmApiKey = 'YOUR_NWM_API_KEY';

     // Mapbox Configuration (Requires Mapbox Account)
     static const String mapboxPublicToken = 'YOUR_MAPBOX_PUBLIC_TOKEN';
     static const String mapboxSecretToken = 'YOUR_MAPBOX_SECRET_TOKEN';
     static const String mapboxSearchApiUrl = 'https://api.mapbox.com/geocoding/v5/mapbox.places/';
     static const String mapboxStyleUrl = 'mapbox://styles/mapbox/standard';

     // Vector Tiles Infrastructure (Your Mapbox Tileset)
     static const String vectorTilesetId = 'YOUR_TILESET_ID';
     static const String vectorSourceId = 'streams2-source';
     static const String vectorSourceLayer = 'YOUR_SOURCE_LAYER';
     static const String vectorLayerId = 'streams2-layer';

     // Firebase Configuration (Replace with your Firebase project values)
     static const String firebaseAndroidApiKey = 'YOUR_ANDROID_API_KEY';
     static const String firebaseAndroidAppId = 'YOUR_ANDROID_APP_ID';
     static const String firebaseiOSApiKey = 'YOUR_IOS_API_KEY';
     static const String firebaseiOSAppId = 'YOUR_IOS_APP_ID';
     static const String firebaseProjectId = 'YOUR_PROJECT_ID';
     static const String firebaseMessagingSenderId = 'YOUR_SENDER_ID';
     static const String firebaseStorageBucket = 'YOUR_STORAGE_BUCKET';
     static const String firebaseAuthDomain = 'YOUR_AUTH_DOMAIN';
     static const String iosBundleId = 'YOUR_IOS_BUNDLE_ID';
     static const String androidPackageName = 'YOUR_ANDROID_PACKAGE_NAME';

     // App Constants
     static const String appName = 'RivrFlow';
     static const String supportEmail = 'support@rivrflow.app';

     // Default Settings
     static const String defaultDisplayUnit = 'cfs';
     static const String defaultReturnPeriodUnit = 'cms';

     // Performance Settings
     static const Duration httpTimeout = Duration(seconds: 30);
     static const int defaultRefreshInterval = 300;

     // Map Performance Settings
     static const double defaultZoom = 9.0;
     static const double minZoomForMarkers = 8.0;
     static const double minZoomForVectorTiles = 7.0;
     static const double maxZoomForVectorTiles = 13.0;
     static const double tapAreaRadius = 12.0;
     static const int searchResultLimit = 5;

     // Stream Order Performance Thresholds
     static const Map<String, double> streamOrderZoomThresholds = {
       'major_rivers': 7.0,
       'tributaries': 9.0,
       'small_streams': 11.0,
     };

     // Default location (Utah coordinates)
     static const double defaultLatitude = 40.233845;
     static const double defaultLongitude = -111.658531;

     // Helper methods for API URLs
     static String getForecastUrl(String reachId, String series) =>
         '$noaaReachesBaseUrl/reaches/$reachId/streamflow?series=$series';

     static String getReachUrl(String reachId) =>
         '$noaaReachesBaseUrl/reaches/$reachId';

     static String getReturnPeriodUrl(String reachId) =>
         '$nwmReturnPeriodUrl?comids=$reachId&key=$nwmApiKey';

     static String getVectorTileSourceUrl() => 'mapbox://$vectorTilesetId';

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
   ```

4. **Set up required services:**

   **Firebase Setup:**
   - Create a new Firebase project at https://console.firebase.google.com
   - Add your Android app with package name from config.dart
   - Add your iOS app with bundle ID from config.dart
   - Download and add `google-services.json` to `android/app/`
   - Download and add `GoogleService-Info.plist` to `ios/Runner/`
   
   **Mapbox Setup:**
   - Create account at https://account.mapbox.com/
   - Get your public and secret access tokens
   - Add public token to `ios/Runner/Info.plist`:
     ```xml
     <key>MBXAccessToken</key>
     <string>YOUR_MAPBOX_PUBLIC_TOKEN</string>
     ```

   **NOAA API Setup:**
   - NOAA's base APIs are public and require no authentication
   - For enhanced features, you may need to set up additional API access

5. **Run the app**
   ```bash
   flutter run
   ```

### Environment Setup

#### iOS Setup
- Minimum deployment target: iOS 16.6
- Required permissions in `Info.plist`:
  - Location access (`NSLocationWhenInUseUsageDescription`)
  - Photo library access (`NSPhotoLibraryUsageDescription`)
  - URL schemes for external navigation

#### Android Setup
- Minimum SDK version: 21
- Target SDK version: 34
- Required permissions in `AndroidManifest.xml`:
  - Location access
  - Internet access
  - Photo storage access

## Architecture

### Design Patterns
- **Provider Pattern**: State management using Flutter Provider
- **Repository Pattern**: Data access abstraction
- **Service Layer**: Business logic separation
- **Clean Architecture**: Domain-driven design principles

### Project Structure
```
lib/
├── core/                 # Shared utilities and services
│   ├── models/          # Data models
│   ├── providers/       # State management
│   ├── services/        # Business logic services
│   └── widgets/         # Reusable UI components
├── features/            # Feature-based modules
│   ├── auth/           # Authentication
│   ├── favorites/      # Favorites management
│   ├── forecast/       # Flow forecasting
│   ├── map/           # Interactive mapping
│   └── settings/      # User preferences
└── main.dart          # App entry point
```

### Key Dependencies
- **`firebase_core`**: Firebase integration
- **`mapbox_maps_flutter`**: Interactive mapping
- **`provider`**: State management
- **`syncfusion_flutter_charts`**: Advanced charting
- **`shared_preferences`**: Local storage
- **`geolocator`**: Location services
- **`screenshot`**: Chart export functionality

## Security & Privacy

### Data Protection
- **Secure Storage**: Sensitive data encrypted using Flutter Secure Storage
- **Firebase Security**: Authentication and Firestore security rules
- **Location Privacy**: Location data used only for map positioning
- **No Tracking**: User activities are not tracked or monetized

### Authentication
- **Firebase Auth**: Secure user authentication system
- **Biometric Support**: Optional fingerprint/Face ID authentication
- **Guest Mode**: Limited functionality without account creation

## Data Sources

RivrFlow integrates with reliable, authoritative data sources:
- **NOAA National Water Model**: Official river flow forecasts developed by the National Weather Service
- **Return Period Statistics**: Historical flood frequency analysis based on government datasets
- **Mapbox**: High-quality mapping and geocoding services

The National Water Model represents a significant advancement in hydrologic prediction, providing high-resolution forecasts across all river reaches in the continental United States. RivrFlow makes this sophisticated forecasting technology accessible to everyday users in an intuitive mobile interface.

## Contributing

We welcome contributions to RivrFlow! Please read our [Contributing Guidelines](CONTRIBUTING.md) before submitting pull requests.

### Development Guidelines
- Follow Flutter best practices and conventions
- Maintain Cupertino design system consistency
- Write comprehensive tests for new features
- Update documentation for API changes
- Ensure accessibility compliance

### Bug Reports
Please use the GitHub issue tracker to report bugs or suggest enhancements. Include:
- Device and OS version
- Steps to reproduce the issue
- Expected vs. actual behavior
- Screenshots if applicable

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- **Documentation**: [Wiki](https://github.com/your-username/rivrflow/wiki)
- **Issues**: [GitHub Issues](https://github.com/your-username/rivrflow/issues)
- **Email**: support@rivrflow.app

## Acknowledgments

- **NOAA**: For developing and maintaining the National Water Model and providing comprehensive river flow forecast data
- **Mapbox**: For exceptional mapping services
- **Flutter Community**: For outstanding open-source packages
- **BYU Hydroinformatics Lab**: For project support and expertise

---

**Safety Disclaimer**: RivrFlow is designed to provide informational data to support decision-making. Always exercise caution around water bodies and consult local authorities for official flood warnings and emergency information. Never enter flood waters or ignore evacuation orders.

**Stay Safe, Stay Informed with RivrFlow**