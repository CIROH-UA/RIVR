// test/services/4_infrastructure/river_data/narrow_nwm_payloads_test.dart
//
// Guards for the read-side codecs behind the map detail sheet's narrow reads.
//
// The return-period conversion is the dangerous one. Thresholds arrive in
// native CMS regardless of what the forecast values were converted to, so they
// must be converted FROM CMS — not from `entry.unit`, which records the user's
// unit preference at fetch time and is not what these numbers are in. Getting
// it backwards silently misclassifies every flood category, and review proved
// the previous suite could not tell: swapping 'CMS' for `entry.unit` left all
// 881 tests green, because the only stub in play converted with the identity
// function.
//
// These use a REAL conversion so the direction is observable.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';

const _cmsToCfs = 35.3147;

/// A unit service that really converts, so a wrong `from` unit is visible.
class _RealUnit implements IFlowUnitPreferenceService {
  _RealUnit(this._current);
  final String _current;

  @override
  String get currentFlowUnit => _current;
  @override
  String getDisplayUnit() => _current == 'CFS' ? 'ft³/s' : 'm³/s';
  @override
  double convertFlow(double value, String from, String to) {
    if (from == to) return value;
    if (from == 'CMS' && to == 'CFS') return value * _cmsToCfs;
    if (from == 'CFS' && to == 'CMS') return value / _cmsToCfs;
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RiverDataEntry _entry({required String unit, required Object? returnPeriods}) =>
    RiverDataEntry(
      key: const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '9962444',
        product: ForecastProduct.returnPeriods,
      ),
      window: FreshnessWindow(
        fetchedAt: DateTime.utc(2026, 8, 22, 12),
        validUntil: DateTime.utc(2026, 9, 21, 12),
      ),
      unit: unit,
      payload: {'returnPeriods': returnPeriods},
    );

List<Map<String, dynamic>> _api({double twoYear = 100.0}) => [
      {'feature_id': '9962444', 'return_period_2': twoYear},
    ];

void main() {
  group('ReturnPeriodPayload — thresholds are always native CMS', () {
    // REGRESSION: fails if the source converts from `entry.unit` instead of
    // from CMS. With entry.unit == 'CFS' and target CFS, that path is a no-op
    // and would return 100.0 rather than the converted value.
    test('converted from CMS even when the entry was stored tagged CFS', () {
      final result = ReturnPeriodPayload.decode(
        _entry(unit: 'CFS', returnPeriods: _api()),
        _RealUnit('CFS'),
      );
      expect(result, isNotNull);
      expect(result![2], closeTo(100.0 * _cmsToCfs, 0.01),
          reason: 'thresholds are CMS on the wire regardless of entry.unit');
      expect(result[2], isNot(closeTo(100.0, 0.01)),
          reason: 'returning the raw number means the conversion was skipped');
    });

    test('a CMS user gets the raw native values back unchanged', () {
      final result = ReturnPeriodPayload.decode(
        _entry(unit: 'CFS', returnPeriods: _api()),
        _RealUnit('CMS'),
      );
      expect(result![2], closeTo(100.0, 0.0001));
    });
  });

  group('ReturnPeriodPayload — unreadable input degrades, never throws', () {
    test('missing key returns null', () {
      final e = _entry(unit: 'CFS', returnPeriods: null);
      expect(ReturnPeriodPayload.decode(e, _RealUnit('CFS')), isNull);
    });

    test('empty list returns null', () {
      final e = _entry(unit: 'CFS', returnPeriods: <dynamic>[]);
      expect(ReturnPeriodPayload.decode(e, _RealUnit('CFS')), isNull);
    });

    // The shape the DTO cannot parse. Before review this threw and took the
    // whole sheet load down with it instead of costing only the category.
    test('a shape the DTO cannot parse returns null instead of throwing', () {
      final e = _entry(unit: 'CFS', returnPeriods: [
        {'unexpected': 'shape'},
      ]);
      expect(() => ReturnPeriodPayload.decode(e, _RealUnit('CFS')),
          returnsNormally);
      expect(ReturnPeriodPayload.decode(e, _RealUnit('CFS')), isNull);
    });

    test('a list of the wrong type returns null', () {
      final e = _entry(unit: 'CFS', returnPeriods: ['not', 'objects']);
      expect(ReturnPeriodPayload.decode(e, _RealUnit('CFS')), isNull);
    });
  });
}
