// test/models/1_domain/shared/location_denial_test.dart
//
// What the map tells a user when it cannot find them.
//
// **The behaviour this covers did not exist until 2026-08-30.** Tapping the
// recentre button with location refused did nothing at all — no message, no
// prompt, no route to Settings. The service logged an error and returned,
// and the button beside it had shown a dialog for its own empty case for
// months. Found by Jerson asking "what happens if location is not granted?",
// which is also how it became clear no test covered any denied path.
//
// Pure, so the MESSAGE is testable. The permission check itself goes through
// Geolocator's statics and a live Mapbox map — no seam, no fake — and that is
// exactly the excuse that let a dead button survive unnoticed.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/location_denial.dart';

void main() {
  test('every denial has a title and a body', () {
    // A blank dialog is worse than no dialog. Derived from the enum so a new
    // value cannot be added without copy.
    for (final d in LocationDenial.values) {
      final m = locationDenialMessage(d);
      expect(m.title.trim(), isNotEmpty, reason: '$d has no title');
      expect(m.body.trim(), isNotEmpty, reason: '$d has no body');
    }
  });

  group('Settings is offered only when Settings is the fix', () {
    test('services off and permanent refusal both offer Settings', () {
      // These cannot be resolved from inside the app. iOS will not show the
      // permission prompt again after a permanent refusal, so Settings is
      // the only route.
      for (final d in [
        LocationDenial.serviceDisabled,
        LocationDenial.deniedForever,
      ]) {
        expect(locationDenialMessage(d).openSettings, isTrue, reason: '$d');
      }
    });

    test('a plain refusal does NOT offer Settings', () {
      // It can still be resolved by the system prompt, which the next tap
      // triggers. Sending the user to Settings for something the next tap
      // fixes is a longer road for no reason.
      expect(
        locationDenialMessage(LocationDenial.denied).openSettings,
        isFalse,
      );
    });

    test('no fix does NOT offer Settings — nothing there would help', () {
      // Permission is fine; the device simply has no position. Offering
      // Settings for a problem Settings cannot fix sends people on an errand
      // and teaches them the button lies.
      expect(
        locationDenialMessage(LocationDenial.noFix).openSettings,
        isFalse,
      );
    });
  });

  group('the copy says what actually happened', () {
    test('the no-fix message does not blame permissions', () {
      // The user granted access. Telling them to "allow location" when they
      // already did is the most annoying possible wrong message.
      final m = locationDenialMessage(LocationDenial.noFix);
      expect(m.body.toLowerCase().contains('settings'), isFalse);
      expect(m.body.toLowerCase().contains('permission'), isFalse);
    });

    test('the services-off message is about the DEVICE, not the app', () {
      // Location Services being off is system-wide. A message about RIVR's
      // own permission would send the user to the wrong screen.
      final m = locationDenialMessage(LocationDenial.serviceDisabled);
      expect(m.title.toLowerCase().contains('location services'), isTrue);
    });

    test('the two Settings messages are not identical', () {
      // They are different problems and lead to different screens; one
      // shared string would describe one of them wrongly.
      expect(
        locationDenialMessage(LocationDenial.serviceDisabled).body,
        isNot(locationDenialMessage(LocationDenial.deniedForever).body),
      );
    });
  });
}
