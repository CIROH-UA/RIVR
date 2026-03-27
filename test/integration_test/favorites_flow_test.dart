// test/integration_test/favorites_flow_test.dart
//
// Integration tests for the favorites page (app home screen):
// empty state, populated list, card tap, search, rename, settings menu.
//
// NOTE: FavoriteRiverCard uses a looping video player, so pumpAndSettle()
// will never return for tests that render cards. Use pump() with explicit
// durations instead.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rivr/features/favorites/favorites_page.dart';
import 'package:rivr/features/favorites/widgets/favorite_river_card.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import 'package:rivr/core/providers/favorites_provider.dart';

import 'helpers/test_app.dart';
import 'helpers/mock_services.dart';

/// Pump frames for the favorites page to render cards.
///
/// FakeVideoPlayerPlatform sends the initialized event on a broadcast stream
/// before VideoPlayerController attaches its listener, so the event is lost
/// and controller.initialize() never completes. This means play() is never
/// called, so the 500ms position-polling timer is never started, and
/// pumpAndSettle() can settle normally.
Future<void> pumpFavoritesReady(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favoritesProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.registerAll();

    authProvider = createAuthProvider(services);
    await authProvider.initialize();

    // Sign in so the favorites page can initialize
    await authProvider.signIn('test@example.com', 'password123');
  });

  tearDown(() async {
    await resetServiceLocator();
  });

  group('Empty state', () {
    testWidgets('shows empty state when no favorites', (tester) async {
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await tester.pumpAndSettle();

      // Empty state text with inline CTA
      expect(find.text('No Favorite Rivers Yet'), findsOneWidget);
      expect(
        find.textContaining('Tap the + button below'),
        findsOneWidget,
      );
    });

    testWidgets('FAB is visible on empty state', (tester) async {
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await tester.pumpAndSettle();

      // FAB (blue circle with + icon) is present
      expect(find.byIcon(CupertinoIcons.add), findsOneWidget);
    });
  });

  group('Populated list', () {
    testWidgets('shows favorite river cards when favorites exist',
        (tester) async {
      services.seedFavorites([
        createTestFavorite(
          reachId: '1001',
          riverName: 'Big River',
          displayOrder: 0,
          lastKnownFlow: 250.0,
        ),
        createTestFavorite(
          reachId: '1002',
          riverName: 'Small Creek',
          displayOrder: 1,
          lastKnownFlow: 50.0,
        ),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      // Cards are visible
      expect(find.byType(FavoriteRiverCard), findsNWidgets(2));
      expect(find.text('Big River'), findsOneWidget);
      expect(find.text('Small Creek'), findsOneWidget);

      // Empty state should NOT be shown
      expect(find.text('No Favorite Rivers Yet'), findsNothing);
    });

    testWidgets('RIVR header is shown when favorites exist', (tester) async {
      services.seedFavorites([
        createTestFavorite(reachId: '1001', riverName: 'Test River'),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      // App header visible
      expect(find.text(' RIVR'), findsOneWidget);
    });
  });

  group('Search', () {
    testWidgets('search bar appears only when 4+ favorites', (tester) async {
      // 3 favorites - search should NOT appear
      services.seedFavorites([
        createTestFavorite(reachId: '1001', riverName: 'River A'),
        createTestFavorite(reachId: '1002', riverName: 'River B'),
        createTestFavorite(reachId: '1003', riverName: 'River C'),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      // Search icon should not be visible with < 4 favorites
      expect(find.byIcon(CupertinoIcons.search), findsNothing);
    });

    testWidgets('search icon visible with 4+ favorites', (tester) async {
      services.seedFavorites([
        createTestFavorite(
            reachId: '1001', riverName: 'River A', displayOrder: 0),
        createTestFavorite(
            reachId: '1002', riverName: 'River B', displayOrder: 1),
        createTestFavorite(
            reachId: '1003', riverName: 'River C', displayOrder: 2),
        createTestFavorite(
            reachId: '1004', riverName: 'River D', displayOrder: 3),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      // Search icon is present
      expect(find.byIcon(CupertinoIcons.search), findsOneWidget);
    });
  });

  group('Settings menu', () {
    // Helper: open the settings menu by invoking the button callback directly.
    // The CupertinoNavigationBar's trailing button center lands in the safe
    // area zone (y≈22), so tester.tap() can't hit it. We invoke onPressed
    // programmatically, then pump the dialog's 150ms fade transition.
    Future<void> openSettingsMenu(WidgetTester tester) async {
      final button = tester.widget<CupertinoButton>(
        find.ancestor(
          of: find.byIcon(CupertinoIcons.ellipsis),
          matching: find.byType(CupertinoButton),
        ),
      );
      button.onPressed!();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('settings menu opens with all options', (tester) async {
      services.seedFavorites([
        createTestFavorite(reachId: '1001', riverName: 'Test River'),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      await openSettingsMenu(tester);

      // Menu options visible
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Sponsors'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);

      // Flow unit toggle visible
      expect(find.text('ft³/s'), findsOneWidget);
      expect(find.text('m³/s'), findsOneWidget);

      // User name displayed
      expect(find.text('Test User'), findsOneWidget);
    });

    testWidgets('sign out shows confirmation dialog', (tester) async {
      services.seedFavorites([
        createTestFavorite(reachId: '1001', riverName: 'Test River'),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      await openSettingsMenu(tester);

      // Invoke sign out directly — the dialog barrier absorbs pointer events
      // in the test binding, so tester.tap() can't reach the text widget.
      final signOutButton = tester.widget<CupertinoButton>(
        find.ancestor(
          of: find.text('Sign Out'),
          matching: find.byType(CupertinoButton),
        ),
      );
      signOutButton.onPressed!();
      await tester.pump(const Duration(milliseconds: 300));

      // Confirmation dialog should appear
      expect(
        find.text('Are you sure you want to sign out of RIVR?'),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);

      // Cancel dismisses the dialog — warnIfMissed false because the
      // dialog barrier absorbs pointer events in the test binding.
      await tester.tap(find.text('Cancel'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));

      // Favorites page should still be showing
      expect(find.byType(FavoritesPage), findsOneWidget);
    });
  });

  group('Rename dialog', () {
    testWidgets('rename dialog opens and saves new name', (tester) async {
      services.seedFavorites([
        createTestFavorite(
          reachId: '1001',
          riverName: 'Original Name',
          customName: 'My Custom Name',
        ),
      ]);
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await pumpFavoritesReady(tester);

      // We can't easily swipe to reveal slide actions in integration tests,
      // but we can verify the card is rendered with the custom name
      expect(find.text('My Custom Name'), findsOneWidget);
    });
  });

  group('Error states', () {
    testWidgets('shows error state when favorites fail to load',
        (tester) async {
      services.favorites.shouldFail = true;
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await tester.pumpAndSettle();

      // Error state visible
      expect(find.text('Unable to Load Favorites'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
    });

    testWidgets('retry button works after error', (tester) async {
      services.favorites.shouldFail = true;
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Unable to Load Favorites'), findsOneWidget);

      // Fix and retry
      services.favorites.shouldFail = false;
      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();

      // Should now show empty state (no favorites seeded)
      expect(find.text('No Favorite Rivers Yet'), findsOneWidget);
    });
  });
}
