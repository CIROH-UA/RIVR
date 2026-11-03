// test/integration_test/rename_dialog_test.dart
//
// ADR 0016 finding 13. Renaming a river opened an EMPTY box titled "Rename
// River", on top of the card that was the only thing telling you which river
// you had tapped. The existing name could not be edited, only retyped from
// memory — and `customName` is null until you have already renamed once, so
// this was every first rename.
//
// Save was not the default action, the keyboard's return key did nothing,
// and an empty field accepted the tap and silently did nothing at all.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';

import 'helpers/test_app.dart';
import 'helpers/mock_services.dart';

void main() {
  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favorites;

  Future<void> settle(WidgetTester tester, [int ms = 900]) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'has_seen_swipe_hint': true});
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.seedFavorites(const [
      FavoriteRiver(
        reachId: 'reach-1',
        riverName: 'Provo River',
        displayOrder: 0,
        lastKnownFlow: 142,
        storedFlowUnit: 'CFS',
        source: ForecastSource.nwm,
      ),
    ]);
    services.registerAll();

    authProvider = createAuthProvider(services);
    await authProvider.initialize();
    await authProvider.signIn('test@example.com', 'password123');
    favorites = createFavoritesProvider(services);
  });

  tearDown(() async => resetServiceLocator());

  /// Open the row and tap Rename.
  Future<void> openRenameDialog(WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      home: const FavoritesPage(),
      services: services,
      authProvider: authProvider,
      favoritesProvider: favorites,
    ));
    await settle(tester);

    await tester.drag(find.byType(FavoriteRiverCard).first,
        const Offset(-260, 0));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
  }

  testWidgets('it names the river and prefills the current name',
      (tester) async {
    await openRenameDialog(tester);

    expect(find.text('Rename Provo River'), findsOneWidget,
        reason: 'the title was the generic "Rename River" while the dialog '
            'covered the card that would have told you which one');

    final field = tester.widget<CupertinoTextField>(
        find.byType(CupertinoTextField));
    expect(field.controller!.text, 'Provo River',
        reason: 'the box used to be empty on a first rename, so the name '
            'had to be retyped from memory');
    expect(field.controller!.selection.start, 0,
        reason: 'and selected, so typing replaces rather than appends');
    expect(field.controller!.selection.end, 'Provo River'.length);
  });

  testWidgets('Save is the default action and refuses an empty name',
      (tester) async {
    await openRenameDialog(tester);

    final save = find.widgetWithText(CupertinoDialogAction, 'Save');
    expect(tester.widget<CupertinoDialogAction>(save).isDefaultAction, isTrue,
        reason: 'the confirming action on an iOS alert is the bold one');

    // Unchanged name: nothing to save.
    expect(tester.widget<CupertinoDialogAction>(save).onPressed, isNull);

    await tester.enterText(find.byType(CupertinoTextField), '   ');
    await settle(tester, 200);
    expect(tester.widget<CupertinoDialogAction>(save).onPressed, isNull,
        reason: 'an empty name used to accept the tap and do nothing, with '
            'no error and no disabled state');

    await tester.enterText(find.byType(CupertinoTextField), 'Upper Provo');
    await settle(tester, 200);
    expect(tester.widget<CupertinoDialogAction>(save).onPressed, isNotNull);
  });

  testWidgets('the name is saved', (tester) async {
    await openRenameDialog(tester);

    await tester.enterText(find.byType(CupertinoTextField), 'Upper Provo');
    await settle(tester, 200);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Save'));
    await settle(tester);

    expect(favorites.favorites.first.customName, 'Upper Provo');
  });
}
