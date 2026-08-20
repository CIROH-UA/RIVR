import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';
import 'package:rivr/ui/2_presentation/shared/widgets/offline_banner.dart';

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

Future<FakeConnectivity> pump(WidgetTester tester, {bool offline = true}) async {
  final conn = FakeConnectivity(offline);
  await tester.pumpWidget(
    ChangeNotifierProvider<ConnectivityProvider>.value(
      value: conn,
      child: const CupertinoApp(
        home: CupertinoPageScaffold(
          child: Column(children: [OfflineBanner(), Expanded(child: SizedBox())]),
        ),
      ),
    ),
  );
  return conn;
}

void main() {
  testWidgets('silent while online', (tester) async {
    await pump(tester, offline: false);
    expect(find.text('No internet connection'), findsNothing);
  });

  testWidgets('shows when offline', (tester) async {
    await pump(tester);
    expect(find.text('No internet connection'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsOneWidget);
  });

  // No recovery toast by design — the warning stopping is the message.
  testWidgets('just goes away when the connection returns', (tester) async {
    final conn = await pump(tester);
    expect(find.text('No internet connection'), findsOneWidget);

    conn.offline = false;
    await tester.pumpAndSettle();
    expect(find.text('No internet connection'), findsNothing);
    expect(find.textContaining('online'), findsNothing);
    expect(find.textContaining('Back'), findsNothing);
  });

  // White on systemOrange measures 2.2:1, under the 4.5:1 AA needs at this
  // size. The fix was the foreground, not the colour — this stops a future
  // restyle quietly putting white back.
  testWidgets('uses dark text, never white', (tester) async {
    await pump(tester);
    final text = tester.widget<Text>(find.text('No internet connection'));
    final color = text.style!.color!;
    expect(color, isNot(CupertinoColors.white));
    expect(color.computeLuminance(), lessThan(0.1),
        reason: 'must stay dark enough to clear AA on orange');
  });

  testWidgets('announces itself to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    expect(
      find.bySemanticsLabel(
        'No internet connection. Data may be out of date.',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  // It sits in a Column above the list, so it must claim real height rather
  // than overlaying — the old Positioned(top: 0) hid the first favourite.
  testWidgets('takes real height when shown, none when hidden',
      (tester) async {
    final conn = await pump(tester, offline: false);
    expect(tester.getSize(find.byType(OfflineBanner)).height, 0);

    conn.offline = true;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(OfflineBanner)).height, greaterThan(20));
  });
}
