// test/services/4_infrastructure/forecast/tap_path_fetches_test.dart
//
// ADR 0011 Phase 1, guard 3 — asserted against the REAL ForecastService.
//
// This exists because two previous attempts at this guard were blind to the
// thing they claimed to prevent:
//
//   1. The widget test records reads at the repository. `reachSummary` pulls
//      medium range two layers below that, inside ForecastService.
//   2. `data_sources_test.dart` fakes `IForecastService`, so it is blind for
//      exactly the same reason one layer down. Review proved it: inserting a
//      real `medium_range` fetch into `ForecastService.loadBasicReachInfo` left
//      all 896 tests passing.
//
// The only way to see it is to run the real ForecastService against a recording
// API client. That is what this does.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_cache_service.dart';
import 'package:rivr/services/4_infrastructure/forecast/forecast_service.dart';

/// Records every endpoint the service actually reaches for.
class _RecordingApi implements INoaaApiService {
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> fetchReachInfo(
    String reachId, {
    bool isOverview = false,
  }) async {
    calls.add('reachInfo');
    return {
      'reachId': reachId,
      'name': 'Test River',
      'latitude': 40.0,
      'longitude': -111.0,
      'streamflow': ['short_range'],
      'city': 'Provo',
      'state': 'UT',
    };
  }

  @override
  Future<Map<String, dynamic>> fetchForecast(
    String reachId,
    String series, {
    bool isOverview = false,
  }) async {
    calls.add('forecast:$series');
    return {'reach': await fetchReachInfo(reachId), series: <String, dynamic>{}};
  }

  @override
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId) async {
    calls.add('currentFlowOnly');
    return fetchForecast(reachId, 'short_range', isOverview: true);
  }

  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    calls.add('returnPeriods');
    return [
      {'feature_id': reachId, 'return_period_2': 100.0},
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double v, String from, String to) => v;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Caches that never hold anything, so every call goes to the API and is seen.
class _NullReachCache implements IReachCacheService {
  @override
  Future<ReachData?> get(String reachId) async => null;
  @override
  Future<void> store(ReachData reach) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullForecastCache implements IForecastCacheService {
  @override
  Future<void> initialize() async {}
  @override
  Future<CacheResult<ForecastResponse>?> getWithFreshness(String r) async =>
      null;
  @override
  Future<void> store(String reachId, ForecastResponse response) async {}
  @override
  Future<void> clearReach(String reachId) async {}
  @override
  Future<void> clearAll() async {}
  @override
  Future<Map<String, dynamic>> getCacheStats() async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _RecordingApi api;
  late ForecastService service;

  setUp(() {
    api = _RecordingApi();
    service = ForecastService(
      apiService: api,
      cacheService: _NullReachCache(),
      forecastCacheService: _NullForecastCache(),
      unitService: _StubUnit(),
    );
  });

  group('guard 3 — the map tap path never reaches medium_range', () {
    // REGRESSION: review inserted a medium_range fetch here and the whole suite
    // stayed green, because every other guard fakes this service away.
    test('loadBasicReachInfo fetches reach info and nothing else', () async {
      await service.loadBasicReachInfo('23021904');

      expect(api.calls, ['reachInfo'],
          reason: 'reachMetadata is the cheap product — one call, no series');
      expect(api.calls.where((c) => c.contains('medium_range')), isEmpty);
    });

    test('the three tap-path products together never fetch medium_range',
        () async {
      // reachMetadata
      await service.loadBasicReachInfo('23021904');
      // analysisAssimilation
      await api.fetchCurrentFlowOnly('23021904');
      // returnPeriods
      await api.fetchReturnPeriods('23021904');

      expect(
        api.calls.where((c) => c.contains('medium_range')),
        isEmpty,
        reason: 'the 156 KB / 30.8 s series must not ride along with a tap',
      );
      expect(api.calls.where((c) => c.contains('long_range')), isEmpty);
    });

    // The contrast that makes the guard meaningful: the bundle DOES pull it.
    // If this ever stops being true the guard above has lost its teeth.
    test('reachSummary by contrast does pull medium_range', () async {
      await service.loadReachDetailsData('23021904');

      expect(
        api.calls.where((c) => c.contains('medium_range')),
        isNotEmpty,
        reason: 'if the bundle stops fetching it, the guard above proves '
            'nothing and this test is the canary',
      );
    });
  });
}
