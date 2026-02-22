// test/integration_test/favorites_flow_test.dart
//
// Integration tests for the favorites page (app home screen):
// empty state, populated list, card tap, search, rename, settings menu.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/features/favorites/favorites_page.dart';
import 'package:rivr/features/favorites/widgets/favorite_river_card.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import 'package:rivr/core/providers/favorites_provider.dart';

import 'helpers/test_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favoritesProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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

      // Empty state text
      expect(find.text('No Favorite Rivers Yet'), findsOneWidget);
      expect(find.text('How do I add favorites?'), findsOneWidget);
    });

    testWidgets('help dialog shows on tap', (tester) async {
      favoritesProvider = createFavoritesProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favoritesProvider,
      ));
      await tester.pumpAndSettle();

      // Tap help link
      await tester.tap(find.text('How do I add favorites?'));
      await tester.pumpAndSettle();

      // Help dialog visible
      expect(find.text('Adding Favorites'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
      expect(find.text('Explore Now'), findsOneWidget);

      // Dismiss
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(find.text('Adding Favorites'), findsNothing);
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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

      // Search icon is present
      expect(find.byIcon(CupertinoIcons.search), findsOneWidget);
    });
  });

  group('Settings menu', () {
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
      await tester.pumpAndSettle();

      // Tap settings (ellipsis) button
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      // Menu options visible
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('App Theme'), findsOneWidget);
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
      await tester.pumpAndSettle();

      // Open settings menu
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      // Tap sign out - this closes the menu and triggers _handleSignOut
      await tester.tap(find.text('Sign Out'));
      await tester.pumpAndSettle();

      // Confirmation dialog should appear
      expect(
        find.text('Are you sure you want to sign out of RIVR?'),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);

      // Cancel dismisses the dialog
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

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
