// test/services/4_infrastructure/river_data/geoglows_forecast_payload_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';

class _StubUnit implements IFlowUnitPreferenceService {
  _StubUnit({this.current = 'CMS', this.display = 'm³/s', this.factor = 1.0});
  final String current;
  final String display;
  final double factor;

  @override
  String get currentFlowUnit => current;
  @override
  String getDisplayUnit() => display;
  @override
  double convertFlow(double value, String from, String to) => value * factor;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RiverDataEntry _entryFor(GeoglowsForecast fc, String unit) => RiverDataEntry(
  key: const RiverDataKey(
    source: ForecastSource.geoglows,
    reachId: '210230337',
    product: ForecastProduct.geoglowsForecast,
  ),
  window: FreshnessWindow(
    fetchedAt: DateTime.utc(2026, 7, 10, 0, 30),
    validUntil: DateTime.utc(2026, 7, 11, 0, 15),
  ),
  unit: unit,
  payload: GeoglowsForecastPayload.encode(fc),
);

void main() {
  final forecast = GeoglowsForecast(
    riverId: '210230337',
    unit: 'm³/s',
    generatedAt: DateTime.utc(2026, 7, 10, 0, 0),
    points: [
      GeoglowsForecastPoint(
        validTime: DateTime.utc(2026, 7, 10, 3),
        median: 10,
        lower: 8,
        upper: 12,
      ),
      GeoglowsForecastPoint(
        validTime: DateTime.utc(2026, 7, 10, 6),
        median: 11,
        lower: 9,
        upper: 13,
      ),
    ],
  );

  test('encode then decode round-trips with an identity conversion', () {
    final decoded = GeoglowsForecastPayload.decode(
      _entryFor(forecast, 'CMS'),
      _StubUnit(current: 'CMS', display: 'm³/s'),
    );

    expect(decoded.riverId, '210230337');
    expect(decoded.generatedAt, DateTime.utc(2026, 7, 10, 0, 0));
    expect(decoded.points.length, 2);
    expect(decoded.points.first.median, 10);
    expect(decoded.points.first.lower, 8);
    expect(decoded.points.last.upper, 13);
    expect(decoded.unit, 'm³/s');
  });

  test('decode converts flow values from the stored unit to the current unit',
      () {
    // Stored CMS, user now wants CFS: convertFlow multiplies by 35.3147.
    final decoded = GeoglowsForecastPayload.decode(
      _entryFor(forecast, 'CMS'),
      _StubUnit(current: 'CFS', display: 'ft³/s', factor: 35.3147),
    );

    expect(decoded.points.first.median, closeTo(353.147, 0.01));
    expect(decoded.unit, 'ft³/s');
  });

  test('return periods round-trip and convert with the flow', () {
    final withRp = GeoglowsForecast(
      riverId: '210230337',
      unit: 'm³/s',
      generatedAt: DateTime.utc(2026, 7, 10, 0, 0),
      points: forecast.points,
      returnPeriods: const {2: 100, 5: 200, 10: 300, 25: 400},
    );

    // Identity conversion preserves the thresholds and their int keys.
    final same = GeoglowsForecastPayload.decode(
      _entryFor(withRp, 'CMS'),
      _StubUnit(current: 'CMS', display: 'm³/s'),
    );
    expect(same.returnPeriods, {2: 100, 5: 200, 10: 300, 25: 400});

    // CMS -> CFS converts each threshold alongside the flow.
    final converted = GeoglowsForecastPayload.decode(
      _entryFor(withRp, 'CMS'),
      _StubUnit(current: 'CFS', display: 'ft³/s', factor: 35.3147),
    );
    expect(converted.returnPeriods![2], closeTo(3531.47, 0.1));
    expect(converted.returnPeriods![25], closeTo(14125.88, 0.1));
  });

  test('missing return periods decode to null', () {
    final decoded = GeoglowsForecastPayload.decode(
      _entryFor(forecast, 'CMS'),
      _StubUnit(current: 'CMS', display: 'm³/s'),
    );
    expect(decoded.returnPeriods, isNull);
  });
}
