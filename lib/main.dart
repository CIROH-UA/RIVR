// lib/main.dart
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:rivr/services/4_infrastructure/shared/analytics_service.dart';
import 'package:rivr/ui/2_presentation/routing/route_observer.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // ADD: FCM import
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/map/flood_tileset_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_coordinator.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';
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
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
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
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  // Disable Crashlytics data collection in debug to avoid polluting the dashboard
  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
    !kDebugMode,
  );

  // Register all services with dependency injection
  setupDependencies();

  // Which flood tileset to draw. Deliberately not awaited: a new tileset is
  // published nightly and the user should get it immediately, but startup must
  // never wait on the network. Remote Config serves its cached value meanwhile,
  // and the service falls back to deriving the id from today's date.
  unawaited(GetIt.I<FloodTilesetService>().initialize());

  // ADR 0011 Phase 5's kill switch. Same rule: startup never waits on the
  // network. Until it resolves the switch reads its default (false), so the
  // app takes the live path — exactly today's behaviour.
  unawaited(GetIt.I<StoreReadSwitch>().initialize());

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

class _RivrAppState extends State<RivrApp> with WidgetsBindingObserver {
  bool _hasSeenOnboarding = true; // Default true so failure skips onboarding
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Owned here rather than created inside MultiProvider, because the ADR 0011
  /// store coordinator has to follow it and therefore needs a reference. Owning
  /// it also means owning its disposal — see [dispose].
  final FavoritesProvider _favorites = FavoritesProvider();

  /// ADR 0011 Phase 5. Reads the cloud store for favourited reaches when the
  /// kill switch allows it.
  ///
  /// Released on [AppLifecycleState.detached], NOT in [dispose]. This is the
  /// root widget passed to `runApp`, and Flutter never disposes it — the
  /// process is killed instead — so a `dispose` that claimed to release
  /// listeners would be describing a path that does not run. Review round 2
  /// found exactly that claim here.
  ///
  /// Within a session the releases that actually matter are elsewhere and are
  /// tested: sign-out (`AuthProvider._detachStoreListeners`), the kill switch
  /// turning off, and a changed favourite set.
  StoreReadCoordinator? _storeReads;

  @override
  void initState() {
    super.initState();
    _initializeServices();

    // Provide the navigator key to the FCM service so notification taps
    // can route to the relevant forecast page.
    GetIt.I<IFCMService>().navigatorKey = _navigatorKey;

    _storeReads = StoreReadCoordinator(
      subscriptions: GetIt.I<StoreSubscriptionService>(),
      readSwitch: GetIt.I<StoreReadSwitch>(),
      cache: GetIt.I<IRiverDataCache>(),
      favouritesListenable: _favorites,
      favourites: () => [
        for (final f in _favorites.favorites)
          (source: f.source, reachId: f.reachId),
      ],
    );

    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached) return;
    // The real end-of-life hook for the root widget. Cancelling a Firestore
    // subscription is fire-and-forget, so nothing is awaited.
    unawaited(_storeReads?.dispose());
    // NOT the StoreReadSwitch. It is a GetIt singleton, and `detached` is
    // RESUMABLE on Android — disposing it here left a permanently dead
    // singleton whose notifier throws on the next config change, for the rest
    // of the process. Round 4, non-blocking 7. Its one subscription dies with
    // the process anyway, which is the only thing this hook could have been
    // protecting.

  }

  @override
  void dispose() {
    // Flutter does not dispose the root widget, so this runs only in tests
    // that pump RivrApp directly. Kept correct rather than removed: it is the
    // honest teardown for those, and the lifecycle observer above is what
    // covers the real app.
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_storeReads?.dispose());
    _favorites.dispose();
    super.dispose();
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
        ChangeNotifierProvider<FavoritesProvider>.value(value: _favorites),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
      ],
      child: CupertinoApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [AnalyticsService.instance.observer, appRouteObserver],
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
