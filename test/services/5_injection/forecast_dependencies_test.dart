// test/services/5_injection/forecast_dependencies_test.dart
//
// The production wiring itself, exercised.
//
// REGRESSION: `IGeocodingService`'s registration could be deleted outright and
// the whole suite passed — nothing exercised `setupForecastDependencies()`. The
// blast radius was not cosmetic: on the NWM forecast page the place-label fill
// used to sit inside the load's `try`, so a throw from resolving an
// unregistered type landed in the `catch` and replaced a page that had already
// rendered correctly with "Failed to load reach details".
//
// It also caught a live trap: the registration sat *after*
// `if (sl.isRegistered<INoaaApiService>()) return;`, and the integration-test
// harness registers `INoaaApiService` itself — so any integration test reaching
// the sheet or the forecast page would have thrown.

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/5_injection/forecast_dependencies.dart';

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

class _StubNoaa implements INoaaApiService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final sl = GetIt.instance;

  setUp(() {
    sl.reset();
    sl.registerLazySingleton<IFlowUnitPreferenceService>(() => _StubUnit());
  });
  tearDown(() => sl.reset());

  test('the geocoder is registered and resolvable', () {
    setupForecastDependencies();

    expect(sl.isRegistered<IGeocodingService>(), isTrue);
    expect(() => sl<IGeocodingService>(), returnsNormally,
        reason: 'every consumer resolves this at runtime; an unregistered type '
            'throws where the throw is caught and shown as a load failure');
  });

  // REGRESSION: registering INoaaApiService first used to short-circuit past
  // the geocoder registration entirely. The integration harness does exactly
  // this.
  test('it is registered even when another service short-circuits setup', () {
    sl.registerLazySingleton<INoaaApiService>(() => _StubNoaa());

    setupForecastDependencies();

    expect(sl.isRegistered<IGeocodingService>(), isTrue,
        reason: 'the registration must sit above the early-return');
  });

  test('setup is idempotent — calling twice does not throw', () {
    setupForecastDependencies();
    expect(setupForecastDependencies, returnsNormally);
    expect(sl.isRegistered<IGeocodingService>(), isTrue);
  });

  // Not asserted here: resolving IForecastService, which needs the cache
  // services this harness does not register. The geocoder is the type this
  // guard exists for, and it resolves standalone (`const MapboxGeocodingService`).
}
