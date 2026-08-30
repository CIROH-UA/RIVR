// test/services/4_infrastructure/river_data/one_data_path_test.dart
//
// ADR 0011 Phase 3 guards, asserted mechanically:
//
//  1. lib/ui/ holds no reference to the fetch layer (the ADR's literal grep,
//     as a test — so the next widget that reaches for IForecastService fails
//     CI, not a review round);
//  2. every surface derives the same value from the same entry;
//  3. two consumers mounting the same reach fund ONE fetch (the repository's
//     in-flight dedup serves both);
//  5. exactly one cache class holds forecast values.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/services/4_infrastructure/forecast/forecast_values.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';

class _Unit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String normalizeUnit(String unit) => unit.toUpperCase();
  @override
  double convertFlow(double v, String from, String to) => v;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _MemCache implements IRiverDataCache {
  final Map<String, RiverDataEntry> _mem = {};
  final Map<String, ValueNotifier<RiverDataEntry?>> _n = {};

  @override
  Future<void> initialize() async {}
  @override
  bool get isReady => true;
  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async => _mem[key.storageKey];
  @override
  Future<void> put(RiverDataEntry entry) async {
    _mem[entry.key.storageKey] = entry;
    _n.putIfAbsent(entry.key.storageKey, () => ValueNotifier(null)).value =
        entry;
  }

  @override
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key) =>
      _n.putIfAbsent(key.storageKey, () => ValueNotifier(_mem[key.storageKey]));
  @override
  void setPinnedReaches(Set<String> reachIds) {}
  @override
  Future<void> evict(RiverDataKey key) async {}
  @override
  Future<void> clear() async {}
}

/// Slow source, so concurrent readers overlap and the dedup is observable.
class _Source implements IRiverDataSource {
  int fetches = 0;

  @override
  ForecastSource get source => ForecastSource.nwm;
  @override
  Set<ForecastProduct> get supportedProducts => ForecastProduct.values.toSet();
  @override
  DateTime validUntil(ForecastProduct product, DateTime now,
          {required String reachId}) =>
      now.add(const Duration(hours: 1));

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    fetches++;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return SourceFetchResult(
      payload: {
        'reach': {
          'reachId': key.reachId,
          'name': 'Shared River',
          'latitude': 40.0,
          'longitude': -111.0,
          'streamflow': ['short_range'],
        },
        'shortRange': {
          'series': {
            'referenceTime': '2026-08-23T12:00:00',
            'units': 'ft³/s',
            'data': [
              {
                'validTime': DateTime.now()
                    .toUtc()
                    .add(const Duration(hours: 1))
                    .toIso8601String(),
                'flow': 640.0,
              },
            ],
          },
        },
      },
      unit: 'CFS',
    );
  }
}

void main() {
  group('guard 1 — lib/ui never references the fetch layer', () {
    test('no IForecastService / NoaaApiService / legacy cache in lib/ui', () {
      final offenders = <String>[];
      final dir = Directory('lib/ui');
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final content = f.readAsStringSync();
        for (final banned in [
          'IForecastService',
          'NoaaApiService',
          'IForecastCacheService',
        ]) {
          if (content.contains(banned)) {
            offenders.add('${f.path}: $banned');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'Phase 3: there is ONE way for a value to reach the screen. '
              'A widget that imports the fetch layer can fetch on its own, '
              'and the divergence this ADR exists to remove grows back.');
    });
  });

  group('guards 2 + 3 — one fetch, one value, every consumer', () {
    test('provider and codec derive the same flow from one shared fetch',
        () async {
      final source = _Source();
      final repo = RiverDataRepository(
        cache: _MemCache(),
        registry: SourceRegistry([source]),
      );
      final unit = _Unit();

      // Two consumers of the same reach at the same moment: the provider (the
      // forecast page) and a direct codec reader (the map sheet's shape).
      final provider = ReachDataProvider(repository: repo, unitService: unit);
      const key = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '123',
        product: ForecastProduct.shortRange,
      );

      final results = await Future.wait([
        provider.loadAllData('123'),
        repo.read(key),
      ]);
      final sheetEntry = results[1] as RiverDataEntry?;

      expect(source.fetches, 1,
          reason: 'both consumers arrived inside one fetch window — the '
              'repository must fund ONE request between them (guard 3)');

      final sheetFlow = CurrentFlowPayload.decode(sheetEntry!, unit);
      final pageFlow = provider.getCurrentFlow();
      expect(pageFlow, sheetFlow,
          reason: 'same entry, same derivation — the sheet and the page can '
              'never disagree (guard 2), because there is nothing else to '
              'read from');
      // And the full-response decode agrees too.
      final decoded = NwmForecastPayload.decode(sheetEntry, unit)!;
      expect(ForecastValues.currentFlow(decoded), sheetFlow);
    });
  });

  group('guard 5 — exactly one cache holds forecast values', () {
    test('no cache-shaped field survives outside RiverDataCache', () {
      // The classes Phase 3 deleted, by name — recreating any of them under
      // the same name fails here; recreating the SHAPE is what review hunts.
      final banned = <String, List<String>>{
        'lib/services/4_infrastructure/forecast/forecast_service.dart': [
          '_currentFlowCache',
          '_flowCategoryCache',
          '_recentResponseCache',
          '_forecastCacheService',
        ],
        'lib/ui/1_state/features/forecast/reach_data_provider.dart': [
          'sessionCache',
          '_currentFlowCache',
        ],
      };
      final offenders = <String>[];
      banned.forEach((path, names) {
        final content = File(path).readAsStringSync();
        for (final n in names) {
          if (content.contains(n)) offenders.add('$path: $n');
        }
      });
      expect(offenders, isEmpty,
          reason: 'two caches with different TTLs holding the same reach is '
              'the divergence this ADR exists to remove');
    });

    test('the legacy forecast cache files are gone', () {
      expect(
          File('lib/services/4_infrastructure/cache/forecast_cache_service.dart')
              .existsSync(),
          isFalse);
      expect(
          File('lib/services/1_contracts/shared/i_forecast_cache_service.dart')
              .existsSync(),
          isFalse);
      expect(
          File('lib/ui/1_state/features/forecast/reach_data_cache_mixin.dart')
              .existsSync(),
          isFalse,
          reason: 'the mixin was the session cache + computed caches — its '
              'return under any refactor is guard 5 failing');
    });
  });
}
