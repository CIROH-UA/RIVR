// lib/main.dart
import 'package:flutter/cupertino.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // ADD: FCM import
import 'package:provider/provider.dart';
import 'package:rivrflow/core/pages/navigation_error_page.dart';
import 'package:rivrflow/features/auth/providers/auth_provider.dart';
import 'package:rivrflow/core/providers/reach_data_provider.dart';
import 'package:rivrflow/core/providers/favorites_provider.dart';
import 'package:rivrflow/core/providers/theme_provider.dart';
import 'package:rivrflow/core/services/theme_service.dart';
import 'package:rivrflow/core/services/map_preference_service.dart';
import 'package:rivrflow/features/favorites/favorites_page.dart';
import 'package:rivrflow/features/forecast/pages/reach_overview_page.dart';
import 'package:rivrflow/features/forecast/pages/short_range_detail_page.dart';
import 'package:rivrflow/features/forecast/pages/medium_range_detail_page.dart';
import 'package:rivrflow/features/forecast/pages/long_range_detail_page.dart';
import 'package:rivrflow/features/forecast/pages/hydrograph_page.dart';
import 'package:rivrflow/features/favorites/pages/image_selection_page.dart';
import 'package:rivrflow/features/settings/pages/notifications_settings_page.dart';
import 'package:rivrflow/features/settings/pages/app_theme_settings_page.dart';
import 'package:rivrflow/features/settings/pages/sponsors_page.dart';
import 'package:rivrflow/features/map/widgets/map_with_favorites.dart';
import 'package:rivrflow/test/home_page.dart';
import 'firebase_options.dart';
import 'features/auth/presentation/pages/auth_coordinator.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// ADD: Background message handler (must be top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Initialize Firebase if needed
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  print('FCM_BACKGROUND: Received message: ${message.messageId}');
  print('FCM_BACKGROUND: Title: ${message.notification?.title}');
  print('FCM_BACKGROUND: Body: ${message.notification?.body}');

  // Handle the background message (for now, just log it)
  // In the future, you could update local database or trigger other actions
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase with proper configuration
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ADD: Register background message handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const RivrFlowApp());
}

class RivrFlowApp extends StatefulWidget {
  const RivrFlowApp({super.key});

  @override
  State<RivrFlowApp> createState() => _RivrFlowAppState();
}

class _RivrFlowAppState extends State<RivrFlowApp> with WidgetsBindingObserver {
  late ThemeProvider _themeProvider;

  @override
  void initState() {
    super.initState();
    _themeProvider = ThemeProvider();
    WidgetsBinding.instance.addObserver(this);
    _initializeServices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    _themeProvider.updateSystemBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

  Future<void> _initializeServices() async {
    // Initialize theme service
    final savedTheme = await ThemeService.loadTheme();
    _themeProvider.setTheme(savedTheme);
    _themeProvider.updateSystemBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );

    // Initialize map preference service (loads saved preferences)
    await MapPreferenceService.loadMapPreference();

    print('🚀 App services initialized');
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _themeProvider),
        ChangeNotifierProvider(create: (context) => AuthProvider()),
        ChangeNotifierProvider(create: (context) => ReachDataProvider()),
        ChangeNotifierProvider(create: (context) => FavoritesProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return CupertinoApp(
            title: 'RivrFlow',
            theme: themeProvider.themeData,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en', 'US')],
            // Set FavoritesPage as home page (after authentication)
            home: AuthCoordinator(
              onAuthSuccess: (context) => const FavoritesPage(),
            ),
            routes: {
              '/favorites': (context) => const FavoritesPage(),
              '/map': (context) => const MapWithFavorites(),
              '/forecast': (context) {
                final reachId =
                    ModalRoute.of(context)?.settings.arguments as String?;
                if (reachId == null) {
                  return const NavigationErrorPage.missingArguments(
                    routeName: 'forecast',
                  );
                }
                return ReachOverviewPage(reachId: reachId);
              },
              // Settings pages
              '/notifications-settings': (context) =>
                  const NotificationsSettingsPage(),
              '/app-theme-settings': (context) => const AppThemeSettingsPage(),
              '/sponsors': (context) => const SponsorsPage(),
              '/test-home': (context) =>
                  const HomePage(), // Keep test home for development
            },
            onGenerateRoute: (settings) {
              // Handle routes with arguments
              switch (settings.name) {
                case '/reach-overview':
                  final args = settings.arguments as Map<String, dynamic>?;
                  final reachId = args?['reachId'] as String?;
                  if (reachId == null) {
                    return CupertinoPageRoute(
                      builder: (context) =>
                          const NavigationErrorPage.missingArguments(
                            routeName: 'reach overview',
                          ),
                      settings: settings,
                    );
                  }
                  return CupertinoPageRoute(
                    builder: (context) => ReachOverviewPage(reachId: reachId),
                    settings: settings,
                  );

                case '/short-range-detail':
                  final args = settings.arguments as Map<String, dynamic>?;
                  final reachId = args?['reachId'] as String?;
                  if (reachId == null) {
                    return CupertinoPageRoute(
                      builder: (context) =>
                          const NavigationErrorPage.missingArguments(
                            routeName: 'short range detail',
                          ),
                      settings: settings,
                    );
                  }
                  return CupertinoPageRoute(
                    builder: (context) =>
                        ShortRangeDetailPage(reachId: reachId),
                    settings: settings,
                  );

                case '/medium-range-detail':
                  final args = settings.arguments as Map<String, dynamic>?;
                  final reachId = args?['reachId'] as String?;
                  if (reachId == null) {
                    return CupertinoPageRoute(
                      builder: (context) =>
                          const NavigationErrorPage.missingArguments(
                            routeName: 'medium range detail',
                          ),
                      settings: settings,
                    );
                  }
                  return CupertinoPageRoute(
                    builder: (context) =>
                        MediumRangeDetailPage(reachId: reachId),
                    settings: settings,
                  );

                case '/long-range-detail':
                  final args = settings.arguments as Map<String, dynamic>?;
                  final reachId = args?['reachId'] as String?;
                  if (reachId == null) {
                    return CupertinoPageRoute(
                      builder: (context) =>
                          const NavigationErrorPage.missingArguments(
                            routeName: 'long range detail',
                          ),
                      settings: settings,
                    );
                  }
                  return CupertinoPageRoute(
                    builder: (context) => LongRangeDetailPage(reachId: reachId),
                    settings: settings,
                  );

                case '/hydrograph':
                  final args = settings.arguments as Map<String, dynamic>?;
                  final reachId = args?['reachId'] as String?;
                  final forecastType = args?['forecastType'] as String?;

                  if (reachId == null || forecastType == null) {
                    return CupertinoPageRoute(
                      builder: (context) =>
                          const NavigationErrorPage.invalidArguments(
                            expected:
                                'reachId (String) and forecastType (String)',
                            routeName: 'hydrograph',
                          ),
                      settings: settings,
                    );
                  }

                  return CupertinoPageRoute(
                    builder: (context) => HydrographPage(
                      reachId: reachId,
                      forecastType: forecastType,
                      title: args?['title'] as String?,
                    ),
                    settings: settings,
                  );

                case '/image-selection':
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

                default:
                  return CupertinoPageRoute(
                    builder: (context) => NavigationErrorPage.pageNotFound(
                      routeName: settings.name ?? 'unknown',
                    ),
                    settings: settings,
                  );
              }
            },
            // Handle completely unknown routes
            onUnknownRoute: (settings) {
              return CupertinoPageRoute(
                builder: (context) => NavigationErrorPage.pageNotFound(
                  routeName: settings.name ?? 'unknown',
                ),
                settings: settings,
              );
            },
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}
