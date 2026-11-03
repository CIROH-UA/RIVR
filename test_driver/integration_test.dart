import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Writes each screenshot the test asks for into SHOT_DIR (or ./screenshots).
Future<void> main() async {
  final dir = Platform.environment['SHOT_DIR'] ?? 'screenshots';
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? a]) async {
      final f = File('$dir/$name.png');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(bytes);
      stdout.writeln('SHOT ${f.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
