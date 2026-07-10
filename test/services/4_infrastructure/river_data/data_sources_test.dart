// test/services/4_infrastructure/river_data/data_sources_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';

class _FakeNoaa implements INoaaApiService {
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId) async {
    calls.add('current:$reachId');
    return {'flow': 42.0};
  }

  @override
  Future<Map<String, dynamic>> fetchForecast(
    String reachId,
    String series, {
    bool isOverview = false,
  }) async {
    calls.add('forecast:$series:$reachId');
    return {'series': series, 'reachId': reachId};
  }

  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    calls.add('rp:$reachId');
    return [2, 5, 10];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGeoglows implements IGeoglowsApiService {
  final List<String> calls = [];

  @override
  Future<GeoglowsForecast> fetchForecast(String riverId) async {
    calls.add('gforecast:$riverId');
    return GeoglowsForecast(
      riverId: riverId,
      unit: 'ft³/s',
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
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUnit implements IFlowUnitPreferenceService {
  _FakeUnit(this._unit);
  final String _unit;
  @override
  String get currentFlowUnit => _unit;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('NwmDataSource', () {
    late _FakeNoaa api;
    late NwmDataSource nwm;

    setUp(() {
      api = _FakeNoaa();
      nwm = NwmDataSource(api: api, unitService: _FakeUnit('CFS'));
    });

    test('identifies as NWM and supports the NWM products', () {
      expect(nwm.source, ForecastSource.nwm);
      expect(nwm.supportedProducts, contains(ForecastProduct.shortRange));
      expect(nwm.supportedProducts, contains(ForecastProduct.returnPeriods));
      expect(
        nwm.supportedProducts,
        isNot(contains(ForecastProduct.geoglowsForecast)),
      );
    });

    test('validUntil: hourly products round to next top-of-hour + skew', () {
      expect(
        nwm.validUntil(
          ForecastProduct.shortRange,
          DateTime.utc(2026, 7, 10, 12, 30),
        ),
        DateTime.utc(2026, 7, 10, 13, 5),
      );
    });

    test('validUntil: 6-hourly products round to next cycle + skew', () {
      expect(
        nwm.validUntil(
          ForecastProduct.mediumRange,
          DateTime.utc(2026, 7, 10, 13, 10),
        ),
        DateTime.utc(2026, 7, 10, 18, 5),
      );
    });

    test('validUntil: return periods are effectively static (~30 days)', () {
      final now = DateTime.utc(2026, 7, 10, 12, 0);
      expect(
        nwm.validUntil(ForecastProduct.returnPeriods, now),
        now.add(const Duration(days: 30)),
      );
    });

    test('validUntil throws for unsupported products', () {
      expect(
        () => nwm.validUntil(ForecastProduct.geoglowsForecast, DateTime.now()),
        throwsArgumentError,
      );
    });

    test('fetch maps products to NWM API calls, tagging the current unit',
        () async {
      final short = await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.shortRange,
      ));
      expect(short.unit, 'CFS');
      expect(short.payload['series'], 'short_range');
      expect(api.calls, contains('forecast:short_range:23021904'));

      await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.analysisAssimilation,
      ));
      expect(api.calls, contains('current:23021904'));

      final rp = await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.returnPeriods,
      ));
      expect(rp.payload['returnPeriods'], [2, 5, 10]);
    });

    test('fetch throws for an unsupported product', () {
      expect(
        () => nwm.fetch(const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '1',
          product: ForecastProduct.geoglowsForecast,
        )),
        throwsArgumentError,
      );
    });
  });

  group('GeoglowsDataSource', () {
    late _FakeGeoglows api;
    late GeoglowsDataSource geoglows;

    setUp(() {
      api = _FakeGeoglows();
      geoglows = GeoglowsDataSource(api: api, unitService: _FakeUnit('CFS'));
    });

    test('identifies as GEOGLOWS and supports the forecast product', () {
      expect(geoglows.source, ForecastSource.geoglows);
      expect(geoglows.supportedProducts, {ForecastProduct.geoglowsForecast});
    });

    test('validUntil: forecast valid until next 00Z + skew', () {
      expect(
        geoglows.validUntil(
          ForecastProduct.geoglowsForecast,
          DateTime.utc(2026, 7, 10, 15, 20),
        ),
        DateTime.utc(2026, 7, 11, 0, 15),
      );
    });

    test('fetch serializes the forecast and tags the canonical unit', () async {
      final result = await geoglows.fetch(const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '210230337',
        product: ForecastProduct.geoglowsForecast,
      ));
      expect(result.unit, 'CFS'); // canonical token, not the 'ft³/s' label
      final points = result.payload['points'] as List;
      expect(points.length, 2);
      expect((points.first as Map)['median'], 10);
      expect(api.calls, contains('gforecast:210230337'));
    });
  });
}
