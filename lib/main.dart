// lib/main.dart
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:rivr/services/4_infrastructure/shared/analytics_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // ADD: FCM import
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/shared/error_service.dart';
import 'package:rivr/services/5_injection/dependency_container.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';
import 'package:rivr/services/4_infrastructure/map/map_preference_service.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/firebase_options.dart';
import 'package:rivr/ui/2_presentation/features/auth/pages/auth_coordinator.dart';
import 'package:rivr/ui/2_presentation/features/onboarding/pages/onboarding_page.dart';
import 'package:rivr/services/4_infrastructure/onboarding/onboarding_service.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// ADD: Background message handler (must be top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Initialize Firebase if needed (guard against duplicate init)
  if (Firebase.apps.isEmpty) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await Firebase.initializeApp();
    } else {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
  }

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

  // On iOS, Firebase auto-inits natively from GoogleService-Info.plist before
  // Dart runs. Calling initializeApp(options:) with different option values
  // causes a duplicate-app crash. Use no-arg init on iOS to reuse the native app.
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await Firebase.initializeApp();
  } else {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  // Disable Crashlytics data collection in debug to avoid polluting the dashboard
  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!kDebugMode);

  // Register all services with dependency injection
  setupDependencies();

  // Catch Flutter framework errors (widget build failures, layout errors, etc.)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    ErrorService.logError(
      'FlutterError',
      details.exception,
      stackTrace: details.stack,
    );
  };

  // Catch platform/async errors not caught by Flutter framework
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
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
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
      ],
      child: CupertinoApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [AnalyticsService.instance.observer],
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
