import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/core/services/flow_unit_preference_service.dart';

void main() {
  late FlowUnitPreferenceService service;

  setUp(() {
    service = FlowUnitPreferenceService();
    service.resetToDefault();
  });

  group('FlowUnitPreferenceService', () {
    group('currentFlowUnit', () {
      test('defaults to CFS', () {
        expect(service.currentFlowUnit, 'CFS');
      });

      test('setFlowUnit changes current unit', () {
        service.setFlowUnit('CMS');
        expect(service.currentFlowUnit, 'CMS');
      });

      test('setFlowUnit rejects invalid units and defaults to CFS', () {
        service.setFlowUnit('CMS');
        service.setFlowUnit('INVALID');
        expect(service.currentFlowUnit, 'CFS');
      });

      test('isCFS and isCMS reflect current unit', () {
        expect(service.isCFS, true);
        expect(service.isCMS, false);

        service.setFlowUnit('CMS');
        expect(service.isCFS, false);
        expect(service.isCMS, true);
      });

      test('resetToDefault sets back to CFS', () {
        service.setFlowUnit('CMS');
        service.resetToDefault();
        expect(service.currentFlowUnit, 'CFS');
      });

      test('getDisplayUnit returns display label', () {
        expect(service.getDisplayUnit(), 'ft³/s');
        service.setFlowUnit('CMS');
        expect(service.getDisplayUnit(), 'm³/s');
      });
    });

    group('normalizeUnit', () {
      test('normalizes CFS variants', () {
        expect(service.normalizeUnit('cfs'), 'CFS');
        expect(service.normalizeUnit('CFS'), 'CFS');
        expect(service.normalizeUnit('ft³/s'), 'CFS');
      });

      test('normalizes CMS variants', () {
        expect(service.normalizeUnit('cms'), 'CMS');
        expect(service.normalizeUnit('CMS'), 'CMS');
        expect(service.normalizeUnit('m³/s'), 'CMS');
      });

      test('uppercases unknown units', () {
        expect(service.normalizeUnit('liters'), 'LITERS');
      });
    });

    group('convertFlow', () {
      test('returns same value when units match', () {
        expect(service.convertFlow(100.0, 'CFS', 'CFS'), 100.0);
        expect(service.convertFlow(100.0, 'CMS', 'CMS'), 100.0);
      });

      test('returns same value for normalized equivalent units', () {
        expect(service.convertFlow(100.0, 'cfs', 'CFS'), 100.0);
        expect(service.convertFlow(100.0, 'ft³/s', 'CFS'), 100.0);
        expect(service.convertFlow(100.0, 'm³/s', 'CMS'), 100.0);
      });

      test('converts CMS to CFS correctly', () {
        // 1 CMS = 35.3147 CFS
        final result = service.convertFlow(1.0, 'CMS', 'CFS');
        expect(result, closeTo(35.3147, 0.001));
      });

      test('converts CFS to CMS correctly', () {
        // 1 CFS = 0.0283168 CMS
        final result = service.convertFlow(1.0, 'CFS', 'CMS');
        expect(result, closeTo(0.0283168, 0.0001));
      });

      test('roundtrip conversion is accurate', () {
        final original = 500.0;
        final toCms = service.convertFlow(original, 'CFS', 'CMS');
        final backToCfs = service.convertFlow(toCms, 'CMS', 'CFS');
        expect(backToCfs, closeTo(original, 0.01));
      });

      test('handles zero value', () {
        expect(service.convertFlow(0.0, 'CFS', 'CMS'), 0.0);
        expect(service.convertFlow(0.0, 'CMS', 'CFS'), 0.0);
      });

      test('returns original for unknown units', () {
        expect(service.convertFlow(100.0, 'UNKNOWN', 'OTHER'), 100.0);
      });
    });

    group('convertToPreferredUnit', () {
      test('converts to CFS when preferred is CFS', () {
        service.setFlowUnit('CFS');
        final result = service.convertToPreferredUnit(1.0, 'CMS');
        expect(result, closeTo(35.3147, 0.001));
      });

      test('converts to CMS when preferred is CMS', () {
        service.setFlowUnit('CMS');
        final result = service.convertToPreferredUnit(1.0, 'CFS');
        expect(result, closeTo(0.0283168, 0.0001));
      });

      test('no conversion when already in preferred unit', () {
        service.setFlowUnit('CFS');
        expect(service.convertToPreferredUnit(100.0, 'CFS'), 100.0);
      });
    });

    group('convertFromPreferredUnit', () {
      test('converts from CFS to CMS', () {
        service.setFlowUnit('CFS');
        final result = service.convertFromPreferredUnit(35.3147, 'CMS');
        expect(result, closeTo(1.0, 0.001));
      });

      test('no conversion when target matches preferred', () {
        service.setFlowUnit('CFS');
        expect(service.convertFromPreferredUnit(100.0, 'CFS'), 100.0);
      });
    });
  });
}
