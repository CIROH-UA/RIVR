// lib/core/routing/app_router.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/core/pages/navigation_error_page.dart';
import 'package:rivr/features/favorites/favorites_page.dart';
import 'package:rivr/features/forecast/pages/reach_overview_page.dart';
import 'package:rivr/features/forecast/pages/short_range_detail_page.dart';
import 'package:rivr/features/forecast/pages/medium_range_detail_page.dart';
import 'package:rivr/features/forecast/pages/long_range_detail_page.dart';
import 'package:rivr/features/forecast/pages/hydrograph_page.dart';
import 'package:rivr/features/favorites/pages/image_selection_page.dart';
import 'package:rivr/features/settings/pages/notifications_settings_page.dart';
import 'package:rivr/features/settings/pages/app_theme_settings_page.dart';
import 'package:rivr/features/settings/pages/sponsors_page.dart';
import 'package:rivr/features/map/widgets/map_with_favorites.dart';
import 'app_routes.dart';
import 'route_args.dart';

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
      if (reachId == null) {
        return const NavigationErrorPage.missingArguments(
          routeName: 'forecast',
        );
      }
      return ReachOverviewPage(reachId: reachId);
    },
    AppRoutes.notificationsSettings: (context) =>
        const NotificationsSettingsPage(),
    AppRoutes.appThemeSettings: (context) => const AppThemeSettingsPage(),
    AppRoutes.sponsors: (context) => const SponsorsPage(),
  };

  // ---------------------------------------------------------------------------
  // onGenerateRoute (parameterised routes)
  // ---------------------------------------------------------------------------
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.reachOverview:
        return _buildReachRoute(
          settings,
          routeLabel: 'reach overview',
          builder: (reachId) => ReachOverviewPage(reachId: reachId),
        );

      case AppRoutes.shortRangeDetail:
        return _buildReachRoute(
          settings,
          routeLabel: 'short range detail',
          builder: (reachId) => ShortRangeDetailPage(reachId: reachId),
        );

      case AppRoutes.mediumRangeDetail:
        return _buildReachRoute(
          settings,
          routeLabel: 'medium range detail',
          builder: (reachId) => MediumRangeDetailPage(reachId: reachId),
        );

      case AppRoutes.longRangeDetail:
        return _buildReachRoute(
          settings,
          routeLabel: 'long range detail',
          builder: (reachId) => LongRangeDetailPage(reachId: reachId),
        );

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
  }) {
    return Navigator.pushNamed<T>(
      context,
      AppRoutes.forecast,
      arguments: reachId,
    );
  }

  static Future<T?> pushForecastDetail<T>(
    BuildContext context, {
    required String reachId,
    required String forecastType,
  }) {
    final route = AppRoutes.detailRouteForForecastType(forecastType);
    return Navigator.pushNamed<T>(
      context,
      route,
      arguments: ReachArgs(reachId: reachId),
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

  static Future<T?> pushAppThemeSettings<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, AppRoutes.appThemeSettings);
  }

  static Future<T?> pushSponsors<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, AppRoutes.sponsors);
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

  /// Build a CupertinoPageRoute for routes that only need a reachId.
  /// Accepts either [ReachArgs], [Map<String, dynamic>], or plain [String].
  static CupertinoPageRoute _buildReachRoute(
    RouteSettings settings, {
    required String routeLabel,
    required Widget Function(String reachId) builder,
  }) {
    final args = settings.arguments;
    String? reachId;

    if (args is ReachArgs) {
      reachId = args.reachId;
    } else if (args is Map<String, dynamic>) {
      reachId = args['reachId'] as String?;
    } else if (args is String) {
      reachId = args;
    }

    if (reachId == null) {
      return CupertinoPageRoute(
        builder: (context) => NavigationErrorPage.missingArguments(
          routeName: routeLabel,
        ),
        settings: settings,
      );
    }

    return CupertinoPageRoute(
      builder: (context) => builder(reachId!),
      settings: settings,
    );
  }

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
