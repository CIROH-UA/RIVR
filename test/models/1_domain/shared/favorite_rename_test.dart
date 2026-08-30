// test/models/1_domain/shared/favorite_rename_test.dart
//
// The "Restore to ..." button's whole decision, tested as a pure function
// instead of guessed at through source greps.
//
// **Two defects came through this code in two days, and the second one is why
// this file exists.**
//
// 1. 2026-08-29: the button never appeared for a GEOGLOWS favourite, because
//    it was gated on a river name GEOGLOWS reaches never publish. A rename
//    was a one-way door.
// 2. 2026-08-30, found on a device within an hour of fixing the first: the
//    button appeared even when the custom name was ALREADY the default —
//    "Restore to Pitumarca, Peru" on a river called Pitumarca, Peru. A
//    control that does nothing, presented as though it did.
//
// The second slipped past source-level guards that only checked the page
// *called* the right things. It never compared the two names, and no grep
// would notice. The decision is now a pure function and these are real tests.
//
// The second defect was never GEOGLOWS-specific either: an NWM reach renamed
// to its own river name showed the same dead button, from the same
// expression, long before any of this work.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/favorite_rename.dart';

void main() {
  group('nothing to undo', () {
    test('a river that was never renamed has no restore', () {
      expect(
        restoreTargetFor(
          customName: null,
          riverName: 'Provo River',
          placeLabel: null,
        ),
        isNull,
      );
    });

    test('an empty or blank custom name counts as never renamed', () {
      for (final name in ['', '   ']) {
        expect(
          restoreTargetFor(
            customName: name,
            riverName: 'Provo River',
            placeLabel: null,
          ),
          isNull,
          reason: 'custom name "$name"',
        );
      }
    });
  });

  group('nothing to restore TO', () {
    test('a GEOGLOWS reach whose place has not resolved yet has no restore',
        () {
      // Geocoding is asynchronous and may never succeed — offline, no
      // coordinates, a reach in the ocean. No button is correct; a button
      // restoring to nothing would look like a control that wipes the name.
      expect(
        restoreTargetFor(
          customName: 'My fishing spot',
          riverName: null,
          placeLabel: null,
        ),
        isNull,
      );
    });

    test('a blank place label is not a restore target', () {
      expect(
        restoreTargetFor(
          customName: 'My fishing spot',
          riverName: '',
          placeLabel: '   ',
        ),
        isNull,
      );
    });
  });

  group('the defect found on a device 2026-08-30', () {
    test('a custom name that IS the default offers no restore — GEOGLOWS', () {
      // The exact case: renamed, then restored, and the button stayed,
      // offering to restore "Pitumarca, Peru" to "Pitumarca, Peru".
      expect(
        restoreTargetFor(
          customName: 'Pitumarca, Peru',
          riverName: null,
          placeLabel: 'Pitumarca, Peru',
        ),
        isNull,
        reason: 'a control that changes nothing must not be offered',
      );
    });

    test('a custom name that IS the default offers no restore — NWM', () {
      // Never GEOGLOWS-specific. This shipped long before that work.
      expect(
        restoreTargetFor(
          customName: 'Provo River',
          riverName: 'Provo River',
          placeLabel: null,
        ),
        isNull,
      );
    });

    test('whitespace does not make a name different', () {
      // The save path trims, so these are the same name in practice and the
      // button would still be dead.
      expect(
        restoreTargetFor(
          customName: '  Provo River  ',
          riverName: 'Provo River',
          placeLabel: null,
        ),
        isNull,
      );
    });

    test('but DIFFERENT CASE is a real difference', () {
      // Restoring "provo river" to "Provo River" genuinely changes what the
      // user sees, so the button belongs there.
      expect(
        restoreTargetFor(
          customName: 'provo river',
          riverName: 'Provo River',
          placeLabel: null,
        ),
        'Provo River',
      );
    });
  });

  group('the button appears when it should', () {
    test('NWM: renamed away from the official name', () {
      expect(
        restoreTargetFor(
          customName: 'The fishing spot',
          riverName: 'White River',
          placeLabel: null,
        ),
        'White River',
      );
    });

    test('GEOGLOWS: renamed away from the geocoded place', () {
      // The 2026-08-29 defect. Before the fix this was null for every
      // GEOGLOWS reach, because there is no riverName to gate on.
      expect(
        restoreTargetFor(
          customName: 'My fishing spot',
          riverName: null,
          placeLabel: 'Pitumarca, Peru',
        ),
        'Pitumarca, Peru',
      );
    });

    test('the network name WINS over the geocoded place', () {
      // An NWM reach can have both. Its published name is the truer default,
      // and the place label is only a stand-in for reaches that have none.
      expect(
        restoreTargetFor(
          customName: 'Renamed',
          riverName: 'White River',
          placeLabel: 'Somewhere, USA',
        ),
        'White River',
      );
    });

    test('an empty network name falls through to the place', () {
      // NWM occasionally returns "" for a real reach — recorded in
      // notifications_history for storeStaticDaily. Empty must not win.
      expect(
        restoreTargetFor(
          customName: 'Renamed',
          riverName: '',
          placeLabel: 'Pitumarca, Peru',
        ),
        'Pitumarca, Peru',
      );
    });

    test('the returned target is trimmed, since it goes into the field', () {
      expect(
        restoreTargetFor(
          customName: 'Renamed',
          riverName: '  White River  ',
          placeLabel: null,
        ),
        'White River',
      );
    });
  });
}
