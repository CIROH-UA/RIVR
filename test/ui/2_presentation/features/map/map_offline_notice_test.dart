import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/map_offline_notice.dart';

/// Drives [ConnectivityProvider.isOffline] without touching the platform
/// connectivity stream.
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
          child: Center(child: MapOfflineNotice()),
        ),
      ),
    ),
  );
  return conn;
}

void main() {
  testWidgets('says nothing while online', (tester) async {
    await pump(tester, offline: false);
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsNothing);
    expect(find.textContaining('Offline'), findsNothing);
  });

  // Mapbox caches tiles, so going offline does not blank the map — visited
  // areas still draw and only new ones come up empty. The wording has to name
  // that, or the user reads a fine-looking map and a message that contradicts
  // it.
  testWidgets('explains that NEW areas are what fail', (tester) async {
    await pump(tester);
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsOneWidget);
    expect(find.text('Offline · new areas won’t load'), findsOneWidget);
  });

  testWidgets('appears when the connection drops', (tester) async {
    final conn = await pump(tester, offline: false);
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsNothing);

    conn.offline = true;
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsOneWidget);
  });

  testWidgets('goes away again when it comes back', (tester) async {
    final conn = await pump(tester);
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsOneWidget);

    conn.offline = false;
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsNothing);
    expect(find.textContaining('Offline'), findsNothing);
  });

  // It sits over a live map, so it must not swell to cover it.
  testWidgets('stays inside a narrow width budget', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ConnectivityProvider>.value(
        value: FakeConnectivity(true),
        child: CupertinoApp(
          home: CupertinoPageScaffold(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: const MapOfflineNotice(),
              ),
            ),
          ),
        ),
      ),
    );
    final w = tester.getSize(find.byType(MapOfflineNotice)).width;
    expect(w, lessThanOrEqualTo(240));
  });

  // Orange is the Moderate rung of the flood ladder on this screen; a
  // connectivity message must not borrow a flood colour.
  testWidgets('uses no flood-ladder colour', (tester) async {
    await pump(tester);
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(MapOfflineNotice),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    final resolved = decoration.color!;
    const flood = [
      Color(0xFFFFC400), // Action
      Color(0xFFFF8C00), // Moderate
      Color(0xFFE53935), // Major
      Color(0xFF8E24AA), // Extreme
    ];
    for (final c in flood) {
      expect(resolved.toARGB32(), isNot(c.toARGB32()));
    }
  });
}
