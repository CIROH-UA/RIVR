import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';

// Phase 1 guards from ADR 0009.
//
// Preferences sync through Firestore; permissions do not. A device signing in
// to an account that already wants notifications inherits the preference with a
// blank permission — and because the app only asks when a toggle is *switched*,
// an inherited "on" was never asked about. Measured on Android: two green
// toggles, a registered FCM token, POST_NOTIFICATIONS denied, every message
// dropped.
//
// These exercise the decision table without a platform channel. The real
// FCMService needs FirebaseMessaging, so the table is modelled here exactly as
// reconcileDevice implements it; the paired test in fcm_service_test.dart holds
// the two in step.

/// Mirrors `FCMService.reconcileDevice`, minus the Firebase calls.
class ReconcileHarness {
  ReconcileHarness(this.osStatus);

  NotificationPermissionResult osStatus;

  int permissionRequests = 0;
  int tokenRefreshes = 0;
  bool reconciledThisSession = false;

  Future<NotificationPermissionResult> reconcile({required bool wantsAny}) async {
    if (!wantsAny) return NotificationPermissionResult.notDetermined;

    switch (osStatus) {
      case NotificationPermissionResult.granted:
        tokenRefreshes++;
        return NotificationPermissionResult.granted;

      case NotificationPermissionResult.notDetermined:
        if (reconciledThisSession) return osStatus;
        reconciledThisSession = true;
        permissionRequests++;
        return NotificationPermissionResult.granted; // user accepted

      case NotificationPermissionResult.permanentlyDenied:
      case NotificationPermissionResult.denied:
      case NotificationPermissionResult.error:
      case NotificationPermissionResult.tokenUnavailable:
        return osStatus;
    }
  }
}

void main() {
  group('guard 1 — asks once per session, never in a loop', () {
    test('a never-asked device with the preference on is prompted once',
        () async {
      final h = ReconcileHarness(NotificationPermissionResult.notDetermined);

      await h.reconcile(wantsAny: true);
      expect(h.permissionRequests, 1);
    });

    // The settings page calls this on every open. Without the session flag,
    // reopening would re-prompt — and on iOS the prompt is spent after the
    // first, so the app would be asking a question the OS no longer answers.
    test('opening the page repeatedly does not ask again', () async {
      final h = ReconcileHarness(NotificationPermissionResult.notDetermined);

      await h.reconcile(wantsAny: true);
      await h.reconcile(wantsAny: true);
      await h.reconcile(wantsAny: true);

      expect(h.permissionRequests, 1, reason: 'one prompt per session, ever');
    });
  });

  group('guard 2 — a denied device is never prompted', () {
    test('permanentlyDenied issues zero requests', () async {
      final h = ReconcileHarness(NotificationPermissionResult.permanentlyDenied);

      final r = await h.reconcile(wantsAny: true);

      expect(h.permissionRequests, 0);
      expect(r, NotificationPermissionResult.permanentlyDenied);
    });

    test('denied issues zero requests', () async {
      final h = ReconcileHarness(NotificationPermissionResult.denied);
      await h.reconcile(wantsAny: true);
      expect(h.permissionRequests, 0);
    });

    test('repeated opens still never prompt a denied device', () async {
      final h = ReconcileHarness(NotificationPermissionResult.permanentlyDenied);
      for (var i = 0; i < 5; i++) {
        await h.reconcile(wantsAny: true);
      }
      expect(h.permissionRequests, 0);
    });
  });

  group('guard 3 — the preference gates everything', () {
    test('preference off never prompts, whatever the OS says', () async {
      for (final os in NotificationPermissionResult.values) {
        final h = ReconcileHarness(os);
        await h.reconcile(wantsAny: false);
        expect(h.permissionRequests, 0, reason: 'os=$os');
        expect(h.tokenRefreshes, 0, reason: 'os=$os');
      }
    });
  });

  group('guard 4 — an authorised device still gets a token', () {
    // A device can be authorised and unregistered: permission granted on a
    // previous install, token never written, or dropped by a failed rotation.
    // To the user both look identical, so granted must still reconcile.
    test('granted refreshes the token rather than assuming one exists',
        () async {
      final h = ReconcileHarness(NotificationPermissionResult.granted);

      final r = await h.reconcile(wantsAny: true);

      expect(h.tokenRefreshes, 1);
      expect(h.permissionRequests, 0, reason: 'already granted — do not ask');
      expect(r, NotificationPermissionResult.granted);
    });

    test('an error state neither asks nor claims success', () async {
      final h = ReconcileHarness(NotificationPermissionResult.error);
      final r = await h.reconcile(wantsAny: true);
      expect(h.permissionRequests, 0);
      expect(h.tokenRefreshes, 0);
      expect(r, NotificationPermissionResult.error);
    });
  });

  group('the whole decision table', () {
    test('every OS state has defined behaviour', () async {
      for (final os in NotificationPermissionResult.values) {
        final h = ReconcileHarness(os);
        await expectLater(h.reconcile(wantsAny: true), completes,
            reason: 'os=$os must not throw');
      }
    });
  });
}
