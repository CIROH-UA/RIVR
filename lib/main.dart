// lib/main.dart
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // ADD: FCM import
import 'package:rivr/core/services/app_logger.dart';
import 'package:rivr/core/services/error_service.dart';
import 'package:rivr/core/di/service_locator.dart';
import 'package:provider/provider.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import 'package:rivr/core/providers/reach_data_provider.dart';
import 'package:rivr/core/providers/favorites_provider.dart';
import 'package:rivr/core/services/map_preference_service.dart';
import 'package:rivr/core/routing/app_router.dart';
import 'package:rivr/core/services/i_fcm_service.dart';
import 'package:rivr/features/favorites/favorites_page.dart';
import 'package:get_it/get_it.dart';
import 'firebase_options.dart';
import 'features/auth/presentation/pages/auth_coordinator.dart';
import 'features/onboarding/pages/onboarding_page.dart';
import 'features/onboarding/services/onboarding_service.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// ADD: Background message handler (must be top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Initialize Firebase if needed
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  AppLogger.debug(
    'Main',
    'FCM background received message: ${message.messageId}',
  );
  AppLogger.debug(
    'Main',
    'FCM background title: ${message.notification?.title}',
  );
  AppLogger.debug('Main', 'FCM background body: ${message.notification?.body}');

  // Handle the background message (for now, just log it)
  // In the future, you could update local database or trigger other actions
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase with proper configuration
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Register all services with dependency injection
  setupServiceLocator();

  // Catch Flutter framework errors (widget build failures, layout errors, etc.)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    ErrorService.logError(
      'FlutterError',
      details.exception,
      stackTrace: details.stack,
    );
  };

  // Catch platform/async errors not caught by Flutter framework
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorService.logError('PlatformError', error, stackTrace: stack);
    return true;
  };

  // ADD: Register background message handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const RivrApp());
}

class RivrApp extends StatefulWidget {
  const RivrApp({super.key});

  @override
  State<RivrApp> createState() => _RivrAppState();
}

class _RivrAppState extends State<RivrApp> {
  bool _hasSeenOnboarding = true; // Default true so failure skips onboarding
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _initializeServices();

    // Provide the navigator key to the FCM service so notification taps
    // can route to the relevant forecast page.
    GetIt.I<IFCMService>().navigatorKey = _navigatorKey;
  }

  Future<void> _initializeServices() async {
    // Initialize map preference service (loads saved preferences)
    await MapPreferenceService.loadMapPreference();

    // Check if user has completed onboarding
    final seen = await OnboardingService.hasSeenOnboarding();
    if (mounted) {
      setState(() => _hasSeenOnboarding = seen);
    }

    AppLogger.info('Main', 'App services initialized');
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AuthProvider()),
        ChangeNotifierProvider(create: (context) => ReachDataProvider()),
        ChangeNotifierProvider(create: (context) => FavoritesProvider()),
      ],
      child: CupertinoApp(
        navigatorKey: _navigatorKey,
        title: 'RIVR',
        theme: const CupertinoThemeData(brightness: Brightness.light),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en', 'US')],
        home: _hasSeenOnboarding
            ? AuthCoordinator(onAuthSuccess: (context) => const FavoritesPage())
            : const OnboardingPage(),
        routes: AppRouter.namedRoutes,
        onGenerateRoute: AppRouter.onGenerateRoute,
        onUnknownRoute: AppRouter.onUnknownRoute,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
