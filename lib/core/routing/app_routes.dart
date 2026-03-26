// lib/core/routing/app_routes.dart

/// Centralized route name constants.
/// All route strings live here — no string literals elsewhere.
class AppRoutes {
  AppRoutes._();

  static const onboarding = '/onboarding';
  static const favorites = '/favorites';
  static const map = '/map';
  static const forecast = '/forecast';
  static const reachOverview = '/reach-overview';
  static const shortRangeDetail = '/short-range-detail';
  static const mediumRangeDetail = '/medium-range-detail';
  static const longRangeDetail = '/long-range-detail';
  static const hydrograph = '/hydrograph';
  static const imageSelection = '/image-selection';
  static const notificationsSettings = '/notifications-settings';
  static const sponsors = '/sponsors';

  /// Map forecast type string to the corresponding detail route.
  static String detailRouteForForecastType(String forecastType) {
    switch (forecastType) {
      case 'short_range':
        return shortRangeDetail;
      case 'medium_range':
        return mediumRangeDetail;
      case 'long_range':
        return longRangeDetail;
      default:
        return shortRangeDetail;
    }
  }
}
