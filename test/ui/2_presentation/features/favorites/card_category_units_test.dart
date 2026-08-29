// test/ui/2_presentation/features/favorites/card_category_units_test.dart
//
// The favourites card under-reported EVERY flood category, and it was a unit
// bug rather than a classifier bug.
//
// `FavoriteRiverCard._getFloodRiskCategory` converted return periods from
// `'CMS'`, on the belief they were stored natively in CMS. They are not: both
// `ReturnPeriodPayload.decode` (NWM) and `GeoglowsForecastPayload.decode`
// (GEOGLOWS) already convert to the unit current at decode time. So for a CFS
// user every threshold was multiplied by ~35.3 and almost every river read
// NORMAL however high it was.
//
// Found on a device 2026-08-30: GEOGLOWS reach 620569308 at 834 CFS against a
// 684 CFS two-year threshold showed NORMAL on the card, while the server —
// which converts once — alerted it as Action. The badge colour and the card's
// animation both follow that category, so all three were wrong together.
//
// The classifier itself was never wrong. These tests pin the CONVERSION COUNT,
// which is the thing that broke.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';

/// The conversion the app uses, matching FlowUnitPreferenceService.
const double _cmsToCfs = 35.3147;

/// Thresholds as the payload decoders hand them over: already in the user's
/// unit. Reach 620569308's real GEOGLOWS values, converted once.
Map<int, double> _thresholdsInCfs() => {
      2: 19.4 * _cmsToCfs, // ~685
      5: 31.3 * _cmsToCfs,
      10: 39.2 * _cmsToCfs,
      25: 49.1 * _cmsToCfs,
    };

void main() {
  conversionSourceGuard();
  group('the device case that exposed it', () {
    test('834 CFS against a ~685 CFS two-year threshold is Action', () {
      // What the card should have said, and what the server did say.
      expect(FlowClassification.category(834, _thresholdsInCfs()), 'Action');
    });

    test('converting a SECOND time is what produced NORMAL', () {
      // Reproduces the bug exactly: thresholds already in CFS, converted from
      // "CMS" again.
      final doubleConverted = {
        for (final e in _thresholdsInCfs().entries)
          e.key: e.value * _cmsToCfs,
      };
      expect(FlowClassification.category(834, doubleConverted), 'Normal',
          reason: 'this is the wrong answer the card was giving — the test '
              'exists to show the mechanism, not to bless it');
      expect(doubleConverted[2]! > 24000, isTrue,
          reason: 'a ~685 CFS threshold became ~24,000 CFS');
    });
  });

  group('a single conversion classifies every band correctly', () {
    test('below the two-year level is Normal', () {
      expect(FlowClassification.category(600, _thresholdsInCfs()), 'Normal');
    });

    test('each band is reachable — nothing is stuck on Normal', () {
      // The symptom was "everything reads Normal". A single conversion must
      // still be able to produce every category above it.
      final t = _thresholdsInCfs();
      expect(FlowClassification.category(t[2]! + 1, t), 'Action');
      expect(FlowClassification.category(t[5]! + 1, t), 'Moderate');
      expect(FlowClassification.category(t[10]! + 1, t), 'Major');
      expect(FlowClassification.category(t[25]! + 1, t), 'Extreme');
    });
  });

  group('a CMS user was never affected, which is why it hid', () {
    test('converting CMS to CMS is a no-op, so the bug was invisible', () {
      // convertFlow('CMS','CMS') returns the value unchanged, so a CMS user saw
      // correct categories throughout. Only CFS users — the default — were
      // wrong, which is the kind of asymmetry that survives a code review.
      final cms = {2: 19.4, 5: 31.3, 10: 39.2, 25: 49.1};
      expect(FlowClassification.category(23.6, cms), 'Action');
    });
  });
}

/// A SOURCE-LEVEL guard, and weaker than a behavioural one — stated plainly.
///
/// The tests above pin the classifier and the arithmetic, and they do NOT
/// catch the regression: restoring the literal `'CMS'` in the card leaves them
/// all green, because they never run the card's own conversion. Verified by
/// mutation, not assumed.
///
/// Catching it properly needs a `FavoriteRiverCard` widget test with a real
/// `FavoritesProvider` and a registered flow-unit service, and no such harness
/// exists yet. Until it does, this asserts the one line that broke. It will not
/// catch a different way of getting the units wrong.
void conversionSourceGuard() {
  group('the card converts from the stored unit, not a literal CMS', () {
    late String src;

    setUpAll(() {
      src = File('lib/ui/2_presentation/features/favorites/widgets/'
              'favorite_river_card.dart')
          .readAsStringSync();
    });

    test('it reads the unit the provider recorded', () {
      expect(src, contains('getReturnPeriodUnit'),
          reason: 'the card stopped asking which unit the thresholds are in, '
              'so it is guessing again');
    });

    test("it does not convert return periods from a literal 'CMS'", () {
      // The exact regression: thresholds arrive already converted, so a second
      // conversion multiplies every one by ~35 and every river reads Normal.
      final rpConversion = RegExp(
          r"convertFlow\(\s*entry\.value,\s*'CMS'", multiLine: true);
      expect(rpConversion.hasMatch(src), isFalse,
          reason: 'return periods are converted from CMS again — they are '
              'already in the user unit when they reach the card');
    });
  });
}
