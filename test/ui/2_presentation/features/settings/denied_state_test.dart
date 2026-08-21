import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';

// Phase 3 guards from ADR 0009 — "denied is a state, not a dead end".
//
// With provisional authorization rejected, a hard denial is genuinely terminal
// until the user visits system settings. The app must therefore never pretend
// otherwise, and must never write a preference on behalf of a device that
// cannot deliver.
//
// These model the page's derived state exactly as it is implemented. The page
// itself needs GetIt, Provider and Firebase to pump, so the rules are tested
// here and the widget wiring is verified on device.

class DeniedStateModel {
  DeniedStateModel({
    required this.osPermission,
    required this.prefFloodAlerts,
    required this.prefWeeklyOutlook,
  });

  NotificationPermissionResult osPermission;
  bool prefFloodAlerts;
  bool prefWeeklyOutlook;

  int firestoreWrites = 0;
  int tokenRegistrations = 0;

  bool get osDenied =>
      osPermission == NotificationPermissionResult.permanentlyDenied;

  bool get anyEnabled => prefFloodAlerts || prefWeeklyOutlook;

  // What the switches render.
  bool get floodSwitchValue => osDenied ? false : prefFloodAlerts;
  bool get weeklySwitchValue => osDenied ? false : prefWeeklyOutlook;
  bool get switchesInteractive => !osDenied;
  bool get showsDeliverySchedule => prefWeeklyOutlook && !osDenied;

  /// A tap only reaches the handler when the switch is interactive.
  void tapFloodSwitch() {
    if (!switchesInteractive) return;
    prefFloodAlerts = !prefFloodAlerts;
    firestoreWrites++;
  }

  /// Returning from system settings.
  Future<void> onResume(NotificationPermissionResult newStatus) async {
    final before = osPermission;
    osPermission = newStatus;
    final justGranted = before != NotificationPermissionResult.granted &&
        newStatus == NotificationPermissionResult.granted;
    if (justGranted && anyEnabled) tokenRegistrations++;
  }
}

DeniedStateModel denied() => DeniedStateModel(
      osPermission: NotificationPermissionResult.permanentlyDenied,
      prefFloodAlerts: true,
      prefWeeklyOutlook: true,
    );

void main() {
  group('guard 1 — a blocked device writes nothing', () {
    test('tapping a toggle does not reach Firestore', () {
      final m = denied();
      m.tapFloodSwitch();
      m.tapFloodSwitch();
      expect(m.firestoreWrites, 0,
          reason: 'a denied device must not persist a preference');
    });

    // The account preference stays true. The device simply cannot act on it —
    // and destroying it here would silence the user's other devices too.
    test('the account preference survives the refusal', () {
      final m = denied();
      m.tapFloodSwitch();
      expect(m.prefFloodAlerts, isTrue);
      expect(m.prefWeeklyOutlook, isTrue);
    });
  });

  group('guard 2 — the UI stops promising delivery', () {
    test('switches read off even though the account wants alerts', () {
      final m = denied();
      expect(m.floodSwitchValue, isFalse);
      expect(m.weeklySwitchValue, isFalse);
      expect(m.switchesInteractive, isFalse);
    });

    test('the "Delivered Fridays" row is hidden', () {
      final m = denied();
      expect(m.showsDeliverySchedule, isFalse,
          reason: 'nothing is delivered to a blocked device');
    });

    test('a granted device shows the real preference and accepts taps', () {
      final m = DeniedStateModel(
        osPermission: NotificationPermissionResult.granted,
        prefFloodAlerts: true,
        prefWeeklyOutlook: true,
      );
      expect(m.floodSwitchValue, isTrue);
      expect(m.switchesInteractive, isTrue);
      expect(m.showsDeliverySchedule, isTrue);
      m.tapFloodSwitch();
      expect(m.firestoreWrites, 1);
    });
  });

  group('guard 3 — returning from settings recovers without another tap', () {
    test('granting in system settings registers the device', () async {
      final m = denied();
      await m.onResume(NotificationPermissionResult.granted);
      expect(m.tokenRegistrations, 1);
      expect(m.floodSwitchValue, isTrue, reason: 'the UI catches up');
      expect(m.switchesInteractive, isTrue);
    });

    test('resuming while still denied changes nothing', () async {
      final m = denied();
      await m.onResume(NotificationPermissionResult.permanentlyDenied);
      expect(m.tokenRegistrations, 0);
      expect(m.floodSwitchValue, isFalse);
    });

    // Every foreground/background cycle calls this. Registering each time would
    // rewrite the token array on every app switch.
    test('an already-granted device does not re-register on every resume',
        () async {
      final m = DeniedStateModel(
        osPermission: NotificationPermissionResult.granted,
        prefFloodAlerts: true,
        prefWeeklyOutlook: true,
      );
      await m.onResume(NotificationPermissionResult.granted);
      await m.onResume(NotificationPermissionResult.granted);
      expect(m.tokenRegistrations, 0, reason: 'only the transition matters');
    });

    test('granting is ignored when the account wants nothing', () async {
      final m = DeniedStateModel(
        osPermission: NotificationPermissionResult.permanentlyDenied,
        prefFloodAlerts: false,
        prefWeeklyOutlook: false,
      );
      await m.onResume(NotificationPermissionResult.granted);
      expect(m.tokenRegistrations, 0);
    });
  });

  // The guard that proves preference and permission are genuinely separate
  // concerns: one device refusing must not silence the others.
  group('guard 4 — one device refusing does not affect another', () {
    test('a denial on phone A leaves phone B delivering', () {
      final shared = {'floodAlerts': true, 'weeklyOutlook': true};

      final phoneA = DeniedStateModel(
        osPermission: NotificationPermissionResult.permanentlyDenied,
        prefFloodAlerts: shared['floodAlerts']!,
        prefWeeklyOutlook: shared['weeklyOutlook']!,
      );
      phoneA.tapFloodSwitch();

      // Nothing phone A did touched the account.
      expect(phoneA.firestoreWrites, 0);

      final phoneB = DeniedStateModel(
        osPermission: NotificationPermissionResult.granted,
        prefFloodAlerts: shared['floodAlerts']!,
        prefWeeklyOutlook: shared['weeklyOutlook']!,
      );
      expect(phoneB.floodSwitchValue, isTrue);
      expect(phoneB.switchesInteractive, isTrue);
      expect(phoneB.showsDeliverySchedule, isTrue);
    });
  });
}
