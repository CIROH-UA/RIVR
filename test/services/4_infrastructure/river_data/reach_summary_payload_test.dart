// test/services/4_infrastructure/river_data/reach_summary_payload_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_summary_payload.dart';

class _StubUnit implements IFlowUnitPreferenceService {
  _StubUnit({this.current = 'CFS', this.factor = 1.0});
  final String current;
  final double factor;

  @override
  String get currentFlowUnit => current;
  @override
  double convertFlow(double value, String from, String to) => value * factor;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RiverDataEntry _entry(Map<String, dynamic> payload, String unit) => RiverDataEntry(
  key: const RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.reachSummary,
  ),
  window: FreshnessWindow(
    fetchedAt: DateTime.utc(2026, 7, 10, 12, 0),
    validUntil: DateTime.utc(2026, 7, 10, 13, 0),
  ),
  unit: unit,
  payload: payload,
);

void main() {
  const details = ReachDetailsData(
    riverName: 'Provo River',
    formattedLocation: 'Provo, UT',
    currentFlow: 743.0,
    flowCategory: 'Normal',
    latitude: 40.29,
    longitude: -111.82,
    isClassificationAvailable: true,
    returnPeriods: {2: 1000.0, 5: 2000.0, 10: 3000.0},
  );

  test('encode then decode round-trips with an identity conversion', () {
    final decoded = ReachSummaryPayload.decode(
      _entry(ReachSummaryPayload.encode(details), 'CFS'),
      _StubUnit(current: 'CFS'),
    );

    expect(decoded.riverName, 'Provo River');
    expect(decoded.formattedLocation, 'Provo, UT');
    expect(decoded.currentFlow, 743.0);
    expect(decoded.flowCategory, 'Normal');
    expect(decoded.latitude, 40.29);
    expect(decoded.isClassificationAvailable, isTrue);
    // Return periods round-trip (int keys) and are NOT unit-converted here.
    expect(decoded.returnPeriods, {2: 1000.0, 5: 2000.0, 10: 3000.0});
  });

  test('decode converts current flow from the stored unit to the current unit',
      () {
    // Stored CFS, user now on CMS: convertFlow multiplies by 0.0283168.
    final decoded = ReachSummaryPayload.decode(
      _entry(ReachSummaryPayload.encode(details), 'CFS'),
      _StubUnit(current: 'CMS', factor: 0.0283168),
    );

    expect(decoded.currentFlow, closeTo(21.04, 0.01));
    // Category is unit-independent — unchanged.
    expect(decoded.flowCategory, 'Normal');
  });

  test('handles a null current flow', () {
    final decoded = ReachSummaryPayload.decode(
      _entry(ReachSummaryPayload.encode(const ReachDetailsData()), 'CFS'),
      _StubUnit(current: 'CMS', factor: 0.0283168),
    );
    expect(decoded.currentFlow, isNull);
    expect(decoded.isClassificationAvailable, isFalse);
  });
}
