// test/ui/2_presentation/shared/widgets/app_version_label_test.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rivr/ui/2_presentation/shared/widgets/app_version_label.dart';

void main() {
  group('formatAppVersion', () {
    test('joins version and build the way Apple writes them', () {
      expect(formatAppVersion('2026.2.1', '786'), 'RIVR 2026.2.1 (786)');
    });

    test('drops the parentheses when there is no build number', () {
      // Some desktop and web builds report an empty buildNumber. Showing
      // "RIVR 2026.2.1 ()" would look like a defect.
      expect(formatAppVersion('2026.2.1', ''), 'RIVR 2026.2.1');
      expect(formatAppVersion('2026.2.1', '   '), 'RIVR 2026.2.1');
    });

    test('returns empty when there is no version, so the label hides', () {
      expect(formatAppVersion('', '786'), '');
      expect(formatAppVersion('  ', '786'), '');
    });
  });

  group('AppVersionLabel', () {
    testWidgets('shows the version the platform reports', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'RIVR',
        packageName: 'com.hydromap.rivr',
        version: '2026.2.1',
        buildNumber: '786',
        buildSignature: '',
      );

      await tester.pumpWidget(
        const CupertinoApp(home: Center(child: AppVersionLabel())),
      );
      // The plugin call is async: the first frame is deliberately empty.
      expect(find.textContaining('RIVR'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('RIVR 2026.2.1 (786)'), findsOneWidget);
    });

    testWidgets('tracks whatever the bundle carries, not a constant', (
      tester,
    ) async {
      // The whole point of the widget: change the compiled version and the
      // label changes with it. A hardcoded string would pass the test above
      // and fail this one.
      PackageInfo.setMockInitialValues(
        appName: 'RIVR',
        packageName: 'com.hydromap.rivr',
        version: '2027.0.0',
        buildNumber: '1001',
        buildSignature: '',
      );

      await tester.pumpWidget(
        const CupertinoApp(home: Center(child: AppVersionLabel())),
      );
      await tester.pumpAndSettle();

      expect(find.text('RIVR 2027.0.0 (1001)'), findsOneWidget);
    });
  });
}
