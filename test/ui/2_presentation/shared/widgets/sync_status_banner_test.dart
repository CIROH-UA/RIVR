// test/ui/2_presentation/shared/widgets/sync_status_banner_test.dart
//
// ADR 0011 Phase 7 guards 2 and 3, plus everything the old OfflineBanner test
// protected — this file replaces it, because the banner replaced the widget.
//
// Phase 7's promise is that SILENCE MEANS CURRENT. Every test here is really
// one of two questions: does the app stay quiet when it is entitled to, and
// does it speak up when it is not?

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';
import 'package:rivr/ui/2_presentation/shared/widgets/sync_status_banner.dart';

class FakeConnectivity extends ChangeNotifier implements ConnectivityProvider {
  FakeConnectivity(this._offline);
  bool _offline;

  @override
  bool get isOffline => _offline;

  set offline(bool v) {
    if (_offline == v) return;
    _offline = v;
    notifyListeners();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRepo implements IRiverDataRepository {
  final ValueNotifier<bool> _outOfSync = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get outOfSync => _outOfSync;

  set stale(bool v) => _outOfSync.value = v;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _offlineText = 'No internet connection';
const _stalePrefix = 'These numbers may not be current';

Future<(FakeConnectivity, FakeRepo)> pump(
  WidgetTester tester, {
  bool offline = false,
  bool stale = false,
}) async {
  final conn = FakeConnectivity(offline);
  final repo = FakeRepo()..stale = stale;
  await tester.pumpWidget(
    ChangeNotifierProvider<ConnectivityProvider>.value(
      value: conn,
      child: CupertinoApp(
        home: CupertinoPageScaffold(
          child: Column(
            children: [
              SyncStatusBanner(repository: repo),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
  return (conn, repo);
}

void main() {
  // ── Guard 2: healthy shows nothing ────────────────────────────────────────
  group('silence is the default', () {
    testWidgets('online and in sync shows nothing at all', (tester) async {
      await pump(tester);
      expect(find.text(_offlineText), findsNothing);
      expect(find.textContaining(_stalePrefix), findsNothing);
    });

    // The whole trust model in one assertion: with the timestamps removed, an
    // app that renders anything here is making a claim it has not earned.
    testWidgets('a healthy banner claims no height', (tester) async {
      await pump(tester);
      expect(tester.getSize(find.byType(SyncStatusBanner)).height, 0);
    });

    // A fetch can fail while every value on screen is still inside its window.
    // The user has lost nothing, and a warning here is the noise that teaches
    // people to ignore the strip before the day it matters.
    testWidgets('a failure that left fresh data on screen stays quiet',
        (tester) async {
      final (_, repo) = await pump(tester);
      repo.stale = false; // fetch failed, but nothing was served past its window
      await tester.pumpAndSettle();
      expect(find.textContaining(_stalePrefix), findsNothing);
    });
  });

  // ── Guard 2: offline shows the indicator ──────────────────────────────────
  group('offline', () {
    testWidgets('shows when offline', (tester) async {
      await pump(tester, offline: true);
      expect(find.text(_offlineText), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.wifi_slash), findsOneWidget);
    });

    // No recovery toast by design — the warning stopping is the message.
    testWidgets('just goes away when the connection returns', (tester) async {
      final (conn, _) = await pump(tester, offline: true);
      expect(find.text(_offlineText), findsOneWidget);

      conn.offline = false;
      await tester.pumpAndSettle();
      expect(find.text(_offlineText), findsNothing);
      expect(find.textContaining('online'), findsNothing);
      expect(find.textContaining('Back'), findsNothing);
    });

    testWidgets('takes real height when shown, none when hidden',
        (tester) async {
      final (conn, _) = await pump(tester);
      expect(tester.getSize(find.byType(SyncStatusBanner)).height, 0);

      conn.offline = true;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SyncStatusBanner)).height,
          greaterThan(20));
    });
  });

  // ── Guard 3: a frozen store raises the indicator, with no error ───────────
  group('out of sync', () {
    // Guard 3. `outOfSync` is what the repository raises when it served a
    // value past its window and the revalidation that should have replaced it
    // failed — which is what a store frozen past its cycle produces on device.
    testWidgets('a value served past its window raises the strip',
        (tester) async {
      final (_, repo) = await pump(tester);
      repo.stale = true;
      await tester.pumpAndSettle();
      expect(find.textContaining(_stalePrefix), findsOneWidget);
    });

    // "without a user-visible error" — the strip is the whole response. No
    // dialog, no retry button, no exception text leaking a class name.
    testWidgets('raises no error dialog and no failure jargon',
        (tester) async {
      final (_, repo) = await pump(tester);
      repo.stale = true;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      for (final jargon in ['Error', 'error', 'Exception', 'failed', 'Retry']) {
        expect(find.textContaining(jargon), findsNothing,
            reason: 'the strip must read as information, not as a failure');
      }
    });

    testWidgets('clears itself when the data comes back', (tester) async {
      final (_, repo) = await pump(tester, stale: true);
      expect(find.textContaining(_stalePrefix), findsOneWidget);

      repo.stale = false;
      await tester.pumpAndSettle();
      expect(find.textContaining(_stalePrefix), findsNothing);
    });
  });

  // ── One indicator, not two ────────────────────────────────────────────────
  group('the ADR asks for ONE indicator', () {
    // Offline wins: it is the more actionable of the two, and it explains the
    // other. Showing both would be two competing claims about one question.
    testWidgets('offline and stale together show only the offline message',
        (tester) async {
      await pump(tester, offline: true, stale: true);
      expect(find.text(_offlineText), findsOneWidget);
      expect(find.textContaining(_stalePrefix), findsNothing);
    });
  });

  // ── Carried over from offline_banner_test.dart ────────────────────────────
  group('accessibility, kept from the widget this replaces', () {
    // White on systemOrange measures 2.2:1, under the 4.5:1 AA needs at this
    // size. The fix was the foreground, not the colour — this stops a future
    // restyle quietly putting white back.
    testWidgets('uses dark text, never white', (tester) async {
      await pump(tester, offline: true);
      final text = tester.widget<Text>(find.text(_offlineText));
      final color = text.style!.color!;
      expect(color, isNot(CupertinoColors.white));
      expect(color.computeLuminance(), lessThan(0.1),
          reason: 'must stay dark enough to clear AA on orange');
    });

    testWidgets('both messages announce themselves to screen readers',
        (tester) async {
      final handle = tester.ensureSemantics();

      final (conn, repo) = await pump(tester, offline: true);
      expect(
        find.bySemanticsLabel('No internet connection. Data may be out of date.'),
        findsOneWidget,
      );

      conn.offline = false;
      repo.stale = true;
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp('These numbers may not be current')),
        findsOneWidget,
        reason: 'the stale case is silent to VoiceOver without its own label',
      );
      handle.dispose();
    });
  });

  // ── Degrading safely ──────────────────────────────────────────────────────
  // "We do not know" must never render as "we know it is stale". With no
  // repository the banner still reports offline, but never invents a warning.
  group('with no repository available', () {
    Future<void> pumpBare(WidgetTester tester, {required bool offline}) {
      return tester.pumpWidget(
        ChangeNotifierProvider<ConnectivityProvider>.value(
          value: FakeConnectivity(offline),
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: Column(
                children: [
                  SyncStatusBanner(),
                  Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('online shows nothing rather than a warning', (tester) async {
      await pumpBare(tester, offline: false);
      await tester.pumpAndSettle();
      expect(find.textContaining(_stalePrefix), findsNothing);
      expect(find.text(_offlineText), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline still reports offline', (tester) async {
      await pumpBare(tester, offline: true);
      await tester.pumpAndSettle();
      expect(find.text(_offlineText), findsOneWidget);
    });
  });
}
