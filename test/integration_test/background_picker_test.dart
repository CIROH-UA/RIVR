// test/integration_test/background_picker_test.dart
//
// ADR 0016 findings 14 and 15. The picker had one defect every new user met
// before anything else: it opened on "Custom Images", which is empty until
// you have uploaded one, so the two dozen bundled backgrounds were invisible
// behind a tap nobody had a reason to make.
//
// The rest are the ones that cost you work: a selection thrown away for
// glancing at another category, a Save button that came and went from the
// navigation bar, and no indication at all of which background the river was
// already using.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/image_selection_page.dart';

import 'helpers/test_app.dart';

const _reach = 'reach-1';

void main() {
  /// `pumpAndSettle` does not return here — the grid's asset images keep a
  /// frame scheduled. Pump a bounded stretch instead, as the other
  /// favourites tests do.
  Future<void> settle(WidgetTester tester, [int ms = 900]) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favorites;

  /// All of the async wiring lives in setUp on purpose. Inside a
  /// `testWidgets` body the clock is fake, so `await authProvider.initialize()`
  /// or a provider load never returns — it waits on timers nothing is
  /// pumping. setUp runs outside that zone.
  Future<void> prepare({String? applied}) async {
    SharedPreferences.setMockInitialValues({});
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.seedFavorites([
      FavoriteRiver(
        reachId: _reach,
        riverName: 'Provo River',
        displayOrder: 0,
        lastKnownFlow: 142,
        storedFlowUnit: 'CFS',
        source: ForecastSource.nwm,
        customImageAsset: applied,
      ),
    ]);
    services.registerAll();

    authProvider = createAuthProvider(services);
    await authProvider.initialize();
    await authProvider.signIn('test@example.com', 'password123');

    favorites = createFavoritesProvider(services);
    // Any identity will do — the mock repository returns the seeded list
    // regardless, and `AuthProvider.currentUser` is only populated once the
    // auth stream has been pumped, which has not happened yet here.
    await favorites.ensureLoadedFor('test-user');
  }

  Future<void> pumpPicker(WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      home: const ImageSelectionPage(reachId: _reach),
      services: services,
      authProvider: authProvider,
      favoritesProvider: favorites,
    ));
    await settle(tester);
  }

  tearDown(() async => resetServiceLocator());

  group('no background applied yet', () {
    setUp(() => prepare());

    testWidgets('opens on a category that has pictures in it', (tester) async {
      await pumpPicker(tester);

      expect(find.text('No custom images yet'), findsNothing,
          reason: 'the first thing a new user sees must not be an empty '
              'screen with the real choices hidden one tap away');
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('a selection survives looking at another category',
        (tester) async {
      await pumpPicker(tester);

      await tester.tap(find.byType(Image).first);
      await settle(tester);
      expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget);

      await tester.tap(find.text('Urban'));
      await settle(tester);
      await tester.tap(find.text('Mountain'));
      await settle(tester);

      expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget,
          reason: 'glancing at another category used to throw the choice '
              'away and take the Save button with it');
    });

    testWidgets('Save is always present, and disabled until there is a change',
        (tester) async {
      await pumpPicker(tester);

      final save = find.widgetWithText(CupertinoButton, 'Save');
      expect(save, findsOneWidget,
          reason: 'it used to be built only when something was selected, so '
              'it appeared and disappeared from the navigation bar');
      expect(tester.widget<CupertinoButton>(save).onPressed, isNull);

      await tester.tap(find.byType(Image).first);
      await settle(tester);

      expect(tester.widget<CupertinoButton>(save).onPressed, isNotNull);
    });
  });

  group('a background is already applied', () {
    const inUse = 'assets/images/rivers/urban/urban_river_2.webp';
    setUp(() => prepare(applied: inUse));

    testWidgets('it is marked, and the picker opens on it', (tester) async {
      await pumpPicker(tester);

      expect(find.text('In use'), findsOneWidget,
          reason: 'nothing used to distinguish your current background from '
              'the other twenty-three');
      expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget,
          reason: 'and it opens on it, rather than making you hunt');

      expect(
          tester
              .widget<CupertinoButton>(
                  find.widgetWithText(CupertinoButton, 'Save'))
              .onPressed,
          isNull,
          reason: 'nothing has changed yet, so there is nothing to save');
    });
  });
}
