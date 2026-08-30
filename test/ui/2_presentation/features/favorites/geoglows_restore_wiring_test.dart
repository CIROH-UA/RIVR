// test/ui/2_presentation/features/favorites/geoglows_restore_wiring_test.dart
//
// Renaming a GEOGLOWS favourite was a one-way door, reported on a device
// 2026-08-29. The fix is a chain of three links, and the provider's link is
// the only one with real behavioural tests
// (`favorites_provider_place_label_test.dart`):
//
//   1. FavoriteRiverCard geocodes the reach          → publishes to provider
//   2. FavoritesProvider caches it                   → TESTED behaviourally
//   3. favorites_page's rename dialog reads it       → decides the button
//
// **These are SOURCE-LEVEL guards on links 1 and 3, and they say so.**
// Exercising them properly needs a widget harness for a card that plays
// video, loads images and reads several providers, and no such harness
// exists. What these pin is the CALL — which is exactly what would be lost if
// someone "tidied" the publish away, and which no amount of provider testing
// would notice.
//
// Comments are stripped before matching. A guard a comment can satisfy is not
// a guard, and this repository learned that twice in one day on 2026-08-30 —
// once on `loadCompleteReachData` and once on `upcomingFrom`. Both files below
// discuss the fix in prose containing the very names being matched.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source with `//` line comments and `///` doc comments removed.
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  const card =
      'lib/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';
  const page =
      'lib/ui/2_presentation/features/favorites/pages/favorites_page.dart';

  test('the card PUBLISHES the geocoded label, not just its own state', () {
    final src = _code(card);

    expect(src.contains('cachePlaceLabel('), isTrue,
        reason: 'the resolved place label lives only in this widget unless it '
            'is published. That is precisely why the GEOGLOWS rename had no '
            'way back: the dialog is built by the page, which cannot see it.');
  });

  test('the card geocodes through the INTERFACE, so it can be faked', () {
    // ADR 0011 recorded this file as one of two still calling
    // GeocodingService's statics. A static cannot be faked, so the publish
    // above could never be tested at the point it happens.
    final src = _code(card);

    expect(src.contains('IGeocodingService'), isTrue);
    expect(src.contains('GeocodingService.placeLabel('), isFalse,
        reason: 'the static is back; nothing can fake it');
  });

  test('the rename dialog READS the label to decide the restore button', () {
    final src = _code(page);

    expect(src.contains('getPlaceLabel('), isTrue,
        reason: 'without this the button is gated on riverName alone, which '
            'GEOGLOWS reaches never have — the original defect');
  });

  test('the restore button is not gated on riverName ALONE', () {
    // The precise shape of the bug: `favorite.riverName != null &&
    // favorite.riverName!.isNotEmpty` as the whole condition. Pinned as a
    // string because it is the exact expression that shipped.
    final src = _code(page);

    expect(
      src.contains("favorite.riverName != null &&\n"
          "        favorite.riverName!.isNotEmpty"),
      isFalse,
      reason: 'this is the original gate; GEOGLOWS reaches publish no river '
          'name, so it is false for every one of them',
    );
  });
}
