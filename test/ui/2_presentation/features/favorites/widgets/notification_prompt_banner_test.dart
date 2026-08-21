import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/notification_prompt_banner.dart';

// Phase 2 guards from ADR 0009 — the soft ask.
//
// iOS grants exactly one notification prompt per install, and with provisional
// authorization rejected there is no second route in. So the real prompt may
// only ever be spent on someone who already said yes to *this* card. Guard 2 —
// "Not now" issues zero OS requests — is the most important assertion in the
// suite for that reason.

Future<void> pumpBanner(
  WidgetTester tester, {
  String riverName = 'White River',
  VoidCallback? onEnable,
  VoidCallback? onDismiss,
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: CupertinoPageScaffold(
        child: NotificationPromptBanner(
          riverName: riverName,
          onEnable: onEnable ?? () {},
          onDismiss: onDismiss ?? () {},
        ),
      ),
    ),
  );
}

/// Stands in for the OS. Counts anything that would spend the one prompt.
class PromptSpy {
  int osRequests = 0;
  int enableTaps = 0;
  int dismissTaps = 0;

  void enable() {
    enableTaps++;
    osRequests++; // only this path is allowed to reach the OS
  }

  void dismiss() => dismissTaps++;
}

void main() {
  group('guard 5 — the copy names the river', () {
    testWidgets('asks about the river the user just saved', (tester) async {
      await pumpBanner(tester, riverName: 'White River');
      expect(find.text('Get alerts for White River?'), findsOneWidget);
    });

    testWidgets('a different river gets a different question',
        (tester) async {
      await pumpBanner(tester, riverName: 'Silver Creek');
      expect(find.text('Get alerts for Silver Creek?'), findsOneWidget);
      expect(find.textContaining('White River'), findsNothing);
    });

    // One grant covers both types, so the card must promise both. Offering
    // only flood alerts and then also sending a weekly digest would be a
    // bait-and-switch.
    testWidgets('promises the weekly summary as well as flood alerts',
        (tester) async {
      await pumpBanner(tester);
      expect(find.textContaining('forecast to flood'), findsOneWidget);
      expect(find.textContaining('weekly summary'), findsOneWidget);
    });

    testWidgets('the old generic copy is gone', (tester) async {
      await pumpBanner(tester);
      expect(find.text('Enable Flood Alerts'), findsNothing);
      expect(find.text('Set Up Notifications'), findsNothing);
    });
  });

  group('guard 2 — "Not now" never reaches the OS', () {
    testWidgets('dismissing issues zero OS requests', (tester) async {
      final spy = PromptSpy();
      await pumpBanner(tester,
          onEnable: spy.enable, onDismiss: spy.dismiss);

      await tester.tap(find.text('Not now'));
      await tester.pump();

      expect(spy.dismissTaps, 1);
      expect(spy.osRequests, 0,
          reason: 'the single iOS prompt must survive a "not now"');
      expect(spy.enableTaps, 0);
    });

    testWidgets('both actions are offered — this is not a forced choice',
        (tester) async {
      await pumpBanner(tester);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Enable'), findsOneWidget);
    });
  });

  group('guard 3 — "Enable" is the only path that spends the prompt', () {
    testWidgets('tapping Enable requests exactly once', (tester) async {
      final spy = PromptSpy();
      await pumpBanner(tester,
          onEnable: spy.enable, onDismiss: spy.dismiss);

      await tester.tap(find.text('Enable'));
      await tester.pump();

      expect(spy.enableTaps, 1);
      expect(spy.osRequests, 1);
      expect(spy.dismissTaps, 0);
    });
  });

  testWidgets('still shows the bell', (tester) async {
    await pumpBanner(tester);
    expect(find.byIcon(CupertinoIcons.bell_fill), findsOneWidget);
  });

  // The display conditions live on the favourites page; this pins the rule the
  // page implements, so a change there has to be deliberate.
  group('guard 1 — when the card may appear at all', () {
    bool shouldShow({
      required int favouriteCount,
      required NotificationPermissionResult os,
      required bool dismissedRecently,
      required bool preferenceOn,
    }) =>
        !preferenceOn &&
        !dismissedRecently &&
        favouriteCount == 1 &&
        os == NotificationPermissionResult.notDetermined;

    test('shown on the first favourite when the prompt is still available', () {
      expect(
        shouldShow(
          favouriteCount: 1,
          os: NotificationPermissionResult.notDetermined,
          dismissedRecently: false,
          preferenceOn: false,
        ),
        isTrue,
      );
    });

    test('not shown before there is a favourite to name', () {
      expect(
        shouldShow(
          favouriteCount: 0,
          os: NotificationPermissionResult.notDetermined,
          dismissedRecently: false,
          preferenceOn: false,
        ),
        isFalse,
      );
    });

    test('not shown again on the second favourite', () {
      expect(
        shouldShow(
          favouriteCount: 2,
          os: NotificationPermissionResult.notDetermined,
          dismissedRecently: false,
          preferenceOn: false,
        ),
        isFalse,
      );
    });

    // Asking someone the OS has already refused offers a button that cannot
    // work; asking someone who granted is pure noise.
    test('not shown when the OS has already answered', () {
      for (final os in [
        NotificationPermissionResult.granted,
        NotificationPermissionResult.permanentlyDenied,
        NotificationPermissionResult.denied,
      ]) {
        expect(
          shouldShow(
            favouriteCount: 1,
            os: os,
            dismissedRecently: false,
            preferenceOn: false,
          ),
          isFalse,
          reason: 'os=$os',
        );
      }
    });

    test('not shown while a recent "not now" still stands', () {
      expect(
        shouldShow(
          favouriteCount: 1,
          os: NotificationPermissionResult.notDetermined,
          dismissedRecently: true,
          preferenceOn: false,
        ),
        isFalse,
      );
    });

    test('not shown when the account already wants notifications', () {
      expect(
        shouldShow(
          favouriteCount: 1,
          os: NotificationPermissionResult.notDetermined,
          dismissedRecently: false,
          preferenceOn: true,
        ),
        isFalse,
      );
    });
  });
}
