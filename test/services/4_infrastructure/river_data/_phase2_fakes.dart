// Shared fakes for the Phase 2 baseline tests. Self-contained so these files
// can move into test/ unchanged when Phase 2 starts.
import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';

/// `fetchReturnPeriods` whose result is scriptable; everything else unused.
class ScriptedNoaa implements INoaaApiService {
  ScriptedNoaa(this.returnPeriodResult, {this.failWith});
  List<dynamic> returnPeriodResult;
  int returnPeriodCalls = 0;

  /// Set to make the fetch FAIL rather than answer.
  ///
  /// The first version of this fake could only return a value, so the only
  /// way to express "the fetch failed" was to hand back the empty list that
  /// the old code produced on failure. That tested the SYMPTOM of the bug
  /// rather than the cause, and it meant the fake could not exercise a fix
  /// that works by distinguishing the two — which is the fix that landed.
  ///
  /// Now a failure is a failure and an empty list means upstream answered
  /// and this reach has no thresholds. The tests below use both.
  Object? failWith;

  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    returnPeriodCalls++;
    final f = failWith;
    if (f != null) throw f;
    return returnPeriodResult;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class UnusedForecastService implements IForecastService {
  @override
  Future<ReachData> loadBasicReachInfo(String reachId) async =>
      throw StateError('not used by this test');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class NullGeocoder implements IGeocodingService {
  @override
  Future<Map<String, String?>> reverseGeocode(double lat, double lon) async =>
      const {};
  @override
  Future<String?> placeLabel(double? lat, double? lon) async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// In-memory IRiverDataCache — the disk tier is irrelevant to these defects.
class MemoryCache implements IRiverDataCache {
  final Map<String, RiverDataEntry> entries = {};
  final Map<String, ValueNotifier<RiverDataEntry?>> notifiers = {};

  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async =>
      entries[key.storageKey];

  @override
  Future<void> put(RiverDataEntry entry) async {
    entries[entry.key.storageKey] = entry;
    notifiers[entry.key.storageKey]?.value = entry;
  }

  @override
  Future<void> evict(RiverDataKey key) async {
    entries.remove(key.storageKey);
    notifiers[key.storageKey]?.value = null;
  }

  @override
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key) =>
      notifiers.putIfAbsent(
          key.storageKey, () => ValueNotifier(entries[key.storageKey]));

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
