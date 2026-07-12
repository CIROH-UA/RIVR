// lib/ui/2_presentation/routing/app_router.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/ui/2_presentation/shared/pages/navigation_error_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/hydrograph_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/image_selection_page.dart';
import 'package:rivr/ui/2_presentation/features/settings/pages/notifications_settings_page.dart';
import 'package:rivr/ui/2_presentation/features/settings/pages/sponsors_page.dart';
import 'package:rivr/ui/2_presentation/features/profile/pages/account_page.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/map_with_favorites.dart';
import 'package:rivr/ui/2_presentation/routing/app_routes.dart';
import 'package:rivr/ui/2_presentation/routing/route_args.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';

/// Centralized router — owns all route→page mapping and typed navigation.
class AppRouter {
  AppRouter._();

  // ---------------------------------------------------------------------------
  // Named routes (simple, used by CupertinoApp.routes)
  // ---------------------------------------------------------------------------
  static Map<String, WidgetBuilder> get namedRoutes => {
    AppRoutes.favorites: (context) => const FavoritesPage(),
    AppRoutes.map: (context) => const MapWithFavorites(),
    AppRoutes.forecast: (context) {
      final args = ModalRoute.of(context)?.settings.arguments;
      final reachId = args is ReachArgs
          ? args.reachId
          : args as String?;
      final source = args is ReachArgs ? args.source : ForecastSource.nwm;
      final lat = args is ReachArgs ? args.lat : null;
      final lon = args is ReachArgs ? args.lon : null;
      if (reachId == null) {
        return const NavigationErrorPage.missingArguments(
          routeName: 'forecast',
        );
      }
      // Consolidated forecast page (NWM + GEOGLOWS) — the redesign target
      // that replaces the separate overview + detail pages.
      return ReachForecastPage(
        reachId: reachId,
        source: source,
        lat: lat,
        lon: lon,
      );
    },
    AppRoutes.notificationsSettings: (context) =>
        const NotificationsSettingsPage(),
    AppRoutes.sponsors: (context) => const SponsorsPage(),
    AppRoutes.account: (context) => const AccountPage(),
  };

  // ---------------------------------------------------------------------------
  // onGenerateRoute (parameterised routes)
  // ---------------------------------------------------------------------------
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.hydrograph:
        return _buildHydrographRoute(settings);

      case AppRoutes.imageSelection:
        return _buildImageSelectionRoute(settings);

      default:
        return CupertinoPageRoute(
          builder: (context) => NavigationErrorPage.pageNotFound(
            routeName: settings.name ?? 'unknown',
          ),
          settings: settings,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // onUnknownRoute
  // ---------------------------------------------------------------------------
  static Route<dynamic> onUnknownRoute(RouteSettings settings) {
    return CupertinoPageRoute(
      builder: (context) => NavigationErrorPage.pageNotFound(
        routeName: settings.name ?? 'unknown',
      ),
      settings: settings,
    );
  }

  // ---------------------------------------------------------------------------
  // Type-safe navigation helpers
  // ---------------------------------------------------------------------------

  static Future<T?> pushForecast<T>(
    BuildContext context, {
    required String reachId,
    ForecastSource source = ForecastSource.nwm,
    double? lat,
    double? lon,
  }) {
    return Navigator.pushNamed<T>(
      context,
      AppRoutes.forecast,
      arguments: ReachArgs(reachId: reachId, source: source, lat: lat, lon: lon),
    );
  }

  static Future<T?> pushHydrograph<T>(
    BuildContext context, {
    required String reachId,
    required String forecastType,
    String? title,
  }) {
    return Navigator.pushNamed<T>(
      context,
      AppRoutes.hydrograph,
      arguments: HydrographArgs(
        reachId: reachId,
        forecastType: forecastType,
        title: title,
      ),
    );
  }

  static Future<T?> pushImageSelection<T>(
    BuildContext context, {
    required String reachId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      AppRoutes.imageSelection,
      arguments: reachId,
    );
  }

  static Future<T?> pushMap<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, AppRoutes.map);
  }

  static Future<T?> pushNotificationsSettings<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, AppRoutes.notificationsSettings);
  }

  static Future<T?> pushSponsors<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, AppRoutes.sponsors);
  }

  static Future<T?> pushAccount<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, AppRoutes.account);
  }

  static void pushFavoritesAndClear(BuildContext context) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.favorites,
      (route) => false,
    );
  }

  // ---------------------------------------------------------------------------
  // Private route builders
  // ---------------------------------------------------------------------------

  /// Build a CupertinoPageRoute for the hydrograph route.
  /// Accepts either [HydrographArgs] or [Map<String, dynamic>].
  static CupertinoPageRoute _buildHydrographRoute(RouteSettings settings) {
    final args = settings.arguments;
    String? reachId;
    String? forecastType;
    String? title;

    if (args is HydrographArgs) {
      reachId = args.reachId;
      forecastType = args.forecastType;
      title = args.title;
    } else if (args is Map<String, dynamic>) {
      reachId = args['reachId'] as String?;
      forecastType = args['forecastType'] as String?;
      title = args['title'] as String?;
    }

    if (reachId == null || forecastType == null) {
      return CupertinoPageRoute(
        builder: (context) => const NavigationErrorPage.invalidArguments(
          expected: 'reachId (String) and forecastType (String)',
          routeName: 'hydrograph',
        ),
        settings: settings,
      );
    }

    return CupertinoPageRoute(
      builder: (context) => HydrographPage(
        reachId: reachId!,
        forecastType: forecastType!,
        title: title,
      ),
      settings: settings,
    );
  }

  /// Build a CupertinoPageRoute for the image selection route.
  static CupertinoPageRoute _buildImageSelectionRoute(RouteSettings settings) {
    final reachId = settings.arguments as String?;

    if (reachId == null) {
      return CupertinoPageRoute(
        builder: (context) => const NavigationErrorPage(
          message: 'No river selected for image customization.',
          title: 'Selection Required',
          icon: CupertinoIcons.photo,
        ),
        settings: settings,
      );
    }

    return CupertinoPageRoute(
      builder: (context) => ImageSelectionPage(reachId: reachId),
      settings: settings,
    );
  }
}
