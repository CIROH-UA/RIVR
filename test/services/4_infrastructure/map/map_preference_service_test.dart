// test/services/4_infrastructure/map/map_preference_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/services/4_infrastructure/map/map_preference_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapPreferenceService.colorByCondition', () {
    test('defaults to on when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await MapPreferenceService.loadColorByCondition(), isTrue);
      expect(MapPreferenceService.colorByConditionDefault, isTrue);
    });

    test('round-trips a saved off value', () async {
      SharedPreferences.setMockInitialValues({});
      await MapPreferenceService.saveColorByCondition(false);
      expect(await MapPreferenceService.loadColorByCondition(), isFalse);

      await MapPreferenceService.saveColorByCondition(true);
      expect(await MapPreferenceService.loadColorByCondition(), isTrue);
    });
  });
}
