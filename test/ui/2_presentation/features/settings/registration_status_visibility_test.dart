// test/ui/2_presentation/features/settings/registration_status_visibility_test.dart
//
// The push-registration diagnostics must not ship to users.
//
// Jerson's call after seeing "6 devices registered" on a built app: useful to
// developers, not something any shipped app shows. The numbers are push
// registrations, not devices — a phone reinstalled five times contributes
// five — and a healthy app announcing them tells a user nothing they can act
// on.
//
// Tested through a pure function because **widget tests always run with
// `kDebugMode` true**, so the release branch — the one that decides what users
// actually see — cannot be reached by pumping the widget. A test that pumped
// the page would pass while the release build showed the diagnostics anyway.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/ui/2_presentation/features/settings/pages/notifications_settings_page.dart';

void main() {
  group('release builds hide the healthy diagnostics', () {
    test('a registered device shows nothing', () {
      expect(
        shouldShowRegistrationStatus(
          hasToken: true,
          isPending: false,
          isDebug: false,
        ),
        isFalse,
        reason: 'a working app must not announce its push registrations',
      );
    });

    test('a pending registration shows nothing', () {
      // "Will activate on a real device" is a simulator message. It has no
      // meaning to someone holding a phone.
      expect(
        shouldShowRegistrationStatus(
          hasToken: true,
          isPending: true,
          isDebug: false,
        ),
        isFalse,
      );
    });

    test('NOT registered is still shown — it is the one actionable state', () {
      // This is the state ADR 0008 existed for: push was silently dead for
      // roughly six months because no token was ever issued. A user seeing
      // this knows alerts will not arrive and the footer says what to try.
      expect(
        shouldShowRegistrationStatus(
          hasToken: false,
          isPending: false,
          isDebug: false,
        ),
        isTrue,
      );
    });
  });

  group('debug builds keep every state', () {
    test('all three states are visible to a developer', () {
      for (final (hasToken, isPending) in [
        (true, false),
        (true, true),
        (false, false),
      ]) {
        expect(
          shouldShowRegistrationStatus(
            hasToken: hasToken,
            isPending: isPending,
            isDebug: true,
          ),
          isTrue,
          reason: 'debug must keep the diagnostics ADR 0008 exists because of',
        );
      }
    });
  });
}
