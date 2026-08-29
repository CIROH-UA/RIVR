// test/models/1_domain/shared/favorite_label_key_test.dart
//
// The label a Cloud Function uses to name a river.
//
// Custom names live only in device SharedPreferences, so a flood notification
// used NOAA's official name even for a river the user had renamed — and since
// the copy rewrite that name is the first thing read on a lock screen.
// `favoriteLabels` carries the user's own name to the server.
//
// **The key format is a cross-language contract.** The app writes these keys
// and two Cloud Functions read them. A mismatch does not throw: every label
// simply stops being found and every notification quietly reverts to the
// official name. `functions/src/notification-service.test.ts` pins the other
// side by reading this file's source.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/favorite_label_key.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';

void main() {
  group('the key carries the source', () {
    test('it is <source>:<reachId>, matching reachKey on the server', () {
      expect(favoriteLabelKey(ForecastSource.nwm, '18471070'),
          'nwm:18471070');
      expect(favoriteLabelKey(ForecastSource.geoglows, '620569308'),
          'geoglows:620569308');
    });

    test('two networks sharing a reach id get separate keys', () {
      // The whole reason the key changed. Keyed by reach alone, an NWM comid
      // and a GEOGLOWS linkno that are numerically equal shared one slot and
      // one river's label silently overwrote the other's. Both id spaces are
      // plain integers with no coordination, so it is a matter of time.
      expect(favoriteLabelKey(ForecastSource.nwm, '12345'),
          isNot(favoriteLabelKey(ForecastSource.geoglows, '12345')));
    });
  });

  group('what a rename writes', () {
    test('a renamed river is added under its own key', () {
      final merged = labelsAfterRename(
        existing: const {},
        source: ForecastSource.nwm,
        reachId: '18471070',
        label: 'The fishing spot',
      );
      expect(merged, {'nwm:18471070': 'The fishing spot'});
    });

    test('other rivers survive the write', () {
      // Read-modify-write, not replace. A label for a river the user is not
      // renaming must not be dropped.
      final merged = labelsAfterRename(
        existing: const {
          'nwm:999': 'Provo River',
          'geoglows:111': 'Rio Napo',
        },
        source: ForecastSource.nwm,
        reachId: '18471070',
        label: 'The fishing spot',
      );
      expect(merged, hasLength(3));
      expect(merged!['nwm:999'], 'Provo River');
      expect(merged['geoglows:111'], 'Rio Napo');
    });

    test('entries under the OLD bare-reachId key are preserved', () {
      // The server still reads those. Dropping them here would blank a user's
      // names for every river they have not renamed since the upgrade.
      final merged = labelsAfterRename(
        existing: const {'9962444': 'Provo, UT'},
        source: ForecastSource.nwm,
        reachId: '18471070',
        label: 'The fishing spot',
      );
      expect(merged!['9962444'], 'Provo, UT');
    });

    test('an unchanged label writes nothing', () {
      // Every dismissal of the rename dialog would otherwise cost a Firestore
      // round trip.
      expect(
        labelsAfterRename(
          existing: const {'nwm:18471070': 'The fishing spot'},
          source: ForecastSource.nwm,
          reachId: '18471070',
          label: 'The fishing spot',
        ),
        isNull,
      );
    });

    test('a blank or whitespace label writes nothing', () {
      for (final blank in ['', '   ', '\t']) {
        expect(
          labelsAfterRename(
            existing: const {},
            source: ForecastSource.nwm,
            reachId: '1',
            label: blank,
          ),
          isNull,
          reason: 'a blank label would put an empty title on a lock screen',
        );
      }
    });

    test('the label is trimmed before it is stored', () {
      final merged = labelsAfterRename(
        existing: const {},
        source: ForecastSource.nwm,
        reachId: '1',
        label: '  The fishing spot  ',
      );
      expect(merged!['nwm:1'], 'The fishing spot');
    });

    test('renaming the same river twice replaces, not accumulates', () {
      var merged = labelsAfterRename(
        existing: const {},
        source: ForecastSource.nwm,
        reachId: '1',
        label: 'First',
      )!;
      merged = labelsAfterRename(
        existing: merged,
        source: ForecastSource.nwm,
        reachId: '1',
        label: 'Second',
      )!;
      expect(merged, {'nwm:1': 'Second'});
    });
  });
}
