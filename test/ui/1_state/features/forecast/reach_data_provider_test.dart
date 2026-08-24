// test/ui/1_state/features/forecast/reach_data_provider_test.dart
//
// ADR 0011 Phase 3: the provider reads through IRiverDataRepository — the ONE
// data path — and holds no cache of its own. The old suite drove four use-case
// fakes and two provider-owned caches, all of which are deleted; this one
// drives a repository fake and asserts the phase's core properties:
//
//  * phased loading still works (overview awaited, sections parallel);
//  * one fetch per key even with concurrent consumers (guard 3 is the
//    repository's dedup; here we pin that the provider READS, never refreshes);
//  * a unit flip re-renders from the same cached entries with zero fetches
//    (guard 4);
//  * background revalidations arriving through watch() merge into the page
//    (guard 2's mechanism);
//  * generation-based cancellation and error paths survive the rewire.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/1_state/shared/section_load_state.dart';

/// Real CMS/CFS arithmetic and a MUTABLE preference, so the unit-flip guard
/// can drive the actual conversion path.
class _Unit implements IFlowUnitPreferenceService {
  _Unit(this.current);
  String current;

  @override
  String get currentFlowUnit => current;
  @override
  String getDisplayUnit() => current == 'CFS' ? 'ft³/s' : 'm³/s';
  @override
  String normalizeUnit(String unit) {
    final u = unit.toUpperCase();
    if (u.contains('CFS') || u.contains('FT')) return 'CFS';
    if (u.contains('CMS') || u.contains('M³') || u.contains('M3')) return 'CMS';
    return u;
  }

  @override
  double convertFlow(double v, String from, String to) {
    final f = normalizeUnit(from);
    final t = normalizeUnit(to);
    if (f == t) return v;
    if (f == 'CMS' && t == 'CFS') return v * 35.3147;
    if (f == 'CFS' && t == 'CMS') return v / 35.3147;
    return v;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Repository fake: counts reads/refreshes per product, serves canned raw-NOAA
/// payloads (the shape the real cache holds), and exposes its watch notifiers
/// so a test can push a "background revalidation" into the provider.
class _Repo implements IRiverDataRepository {
  _Repo({this.failProducts = const {}, this.delay});

  final Set<ForecastProduct> failProducts;
  final Duration? delay;

  final List<ForecastProduct> reads = [];
  final List<ForecastProduct> refreshes = [];
  final Map<String, ValueNotifier<RiverDataEntry?>> notifiers = {};

  /// Flow value served for short_range — mutable so a revalidation can differ.
  double shortRangeFlow = 640;

  RiverDataEntry entryFor(ForecastProduct p) {
    Map<String, dynamic> payload;
    switch (p) {
      case ForecastProduct.shortRange:
        payload = {
          'reach': {
            'reachId': '123',
            'name': 'Test River',
            'latitude': 40.0,
            'longitude': -111.0,
            'streamflow': ['short_range'],
          },
          'shortRange': {
            'series': {
              'referenceTime': '2026-08-23T12:00:00',
              'units': 'ft³/s',
              // Anchored at "now" so the current-hour-forward filter always
              // keeps them, whenever the test runs.
              'data': [
                {
                  'validTime': DateTime.now()
                      .toUtc()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                  'flow': shortRangeFlow,
                },
                {
                  'validTime': DateTime.now()
                      .toUtc()
                      .add(const Duration(hours: 2))
                      .toIso8601String(),
                  'flow': shortRangeFlow + 5,
                },
              ],
            },
          },
        };
      case ForecastProduct.mediumRange:
        payload = {
          'reach': {
            'reachId': '123',
            'name': 'Test River',
            'latitude': 40.0,
            'longitude': -111.0,
            'streamflow': ['short_range'],
          },
          'mediumRange': {
            'mean': {
              'referenceTime': '2026-08-23T06:00:00',
              'units': 'ft³/s',
              'data': [
                {'validTime': '2026-08-24T00:00:00', 'flow': 700.0},
              ],
            },
          },
        };
      case ForecastProduct.longRange:
        payload = {
          'reach': {
            'reachId': '123',
            'name': 'Test River',
            'latitude': 40.0,
            'longitude': -111.0,
            'streamflow': ['short_range'],
          },
          'longRange': {
            'member1': {
              'referenceTime': '2026-08-23T00:00:00',
              'units': 'ft³/s',
              'data': [
                {'validTime': '2026-08-26T00:00:00', 'flow': 800.0},
              ],
            },
          },
        };
      case ForecastProduct.returnPeriods:
        payload = {
          'returnPeriods': [
            {
              'feature_id': '123',
              'return_period_2': 1200.0,
              'return_period_5': 2400.0,
              'return_period_10': 3600.0,
              'return_period_25': 5800.0,
            },
          ],
        };
      default:
        payload = const {};
    }
    return RiverDataEntry(
      key: RiverDataKey(
          source: ForecastSource.nwm, reachId: '123', product: p),
      window: FreshnessWindow(
        fetchedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
      unit: 'CFS',
      payload: payload,
    );
  }

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    reads.add(key.product);
    if (delay != null) await Future<void>.delayed(delay!);
    if (failProducts.contains(key.product)) {
      throw Exception('simulated failure for ${key.product}');
    }
    final entry = entryFor(key.product);
    notifiers
        .putIfAbsent(key.storageKey, () => ValueNotifier(null))
        .value = entry;
    return entry;
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) async {
    refreshes.add(key.product);
    return read(key);
  }

  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) =>
      notifiers.putIfAbsent(key.storageKey, () => ValueNotifier(null));

  /// Push a fresh entry through the watch channel — what a background
  /// revalidation (from ANY surface) looks like to the provider.
  void pushRevalidation(ForecastProduct p) {
    final key = RiverDataKey(
        source: ForecastSource.nwm, reachId: '123', product: p);
    notifiers
        .putIfAbsent(key.storageKey, () => ValueNotifier(null))
        .value = entryFor(p);
  }

  @override
  Future<void> ingest(RiverDataEntry e) async {}
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('loadAllData — overview first, then parallel', () {
    test('returns true with reach + hourly data when short range lands',
        () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      final ok = await p.loadAllData('123');
      await _settle();

      expect(ok, isTrue);
      expect(p.currentReach?.riverName, 'Test River');
      expect(p.hasHourlyForecast, isTrue);
      expect(p.hasDailyForecast, isTrue);
      expect(p.hasExtendedForecast, isTrue);
      expect(p.hasSupplementaryData, isTrue,
          reason: 'return periods merged onto the reach');
      expect(p.loadingPhase, 'complete');
    });

    test('reads the four products, never as a forced refresh', () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      await p.loadAllData('123');
      await _settle();

      expect(
          repo.reads,
          containsAll([
            ForecastProduct.shortRange,
            ForecastProduct.mediumRange,
            ForecastProduct.longRange,
            ForecastProduct.returnPeriods,
          ]));
      expect(repo.refreshes, isEmpty,
          reason: 'refresh() bypasses the shared cache — the provider must '
              'read through it so it hits what the sheet warmed (guard 3)');
    });

    test('a failed overview is an error, not a crash', () async {
      final repo = _Repo(failProducts: {ForecastProduct.shortRange});
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      final ok = await p.loadAllData('123');

      expect(ok, isFalse);
      expect(p.errorMessage, isNotNull);
      expect(p.loadingPhase, 'none');
    });

    test('a failed section does not block the others', () async {
      final repo = _Repo(failProducts: {ForecastProduct.mediumRange});
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      final ok = await p.loadAllData('123');
      await _settle();

      expect(ok, isTrue);
      expect(p.dailyState, SectionLoadState.error);
      expect(p.hasExtendedForecast, isTrue,
          reason: 'long range landed regardless of medium failing');
      expect(p.hasSupplementaryData, isTrue);
    });
  });

  group('the sections load in parallel, after the overview', () {
    // REGRESSION (phase 3 mutation M5): serialising the section loads behind
    // the overview await left the suite green — the exact 3-await-chain shape
    // Phase 1 killed on the forecast page. loadAllData must RETURN when the
    // overview lands, with the other three still in flight.
    test('loadAllData returns while the other sections are still loading',
        () async {
      final repo = _Repo(delay: const Duration(milliseconds: 40));
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      final ok = await p.loadAllData('123');

      expect(ok, isTrue);
      expect(p.hasOverviewData, isTrue,
          reason: 'the overview is what the await was for');
      expect(p.dailyState.isLoading || p.extendedState.isLoading, isTrue,
          reason: 'the remaining sections must be IN FLIGHT when loadAllData '
              'returns — awaiting them serially is a 3× slower first paint');

      // Drain so the test ends clean.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
  });

  group('generation-based cancellation', () {
    test('clearCurrentReach discards in-flight section results', () async {
      final repo = _Repo(delay: const Duration(milliseconds: 50));
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      final loading = p.loadAllData('123');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      p.clear();
      await loading;
      await _settle();

      expect(p.currentForecast, isNull,
          reason: 'results from a cleared generation must not resurrect');
      expect(p.hasData, isFalse);
    });
  });

  group('guard 4 — a unit flip refetches nothing', () {
    test('flipping the unit converts the displayed flow with zero reads',
        () async {
      final unit = _Unit('CFS');
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: unit);

      await p.loadAllData('123');
      await _settle();
      final before = p.getCurrentFlow();
      expect(before, isNotNull);
      final readsBefore = repo.reads.length;

      // The user flips the preference; the settings page notifies providers.
      unit.current = 'CMS';
      p.recomputeForUnitChange();

      expect(repo.reads.length, readsBefore,
          reason: 'a unit flip must never fetch — the entries are cached and '
              'decode converts (Phase 2 guard 6, app-wide as of Phase 3)');
      expect(repo.refreshes, isEmpty);
      expect(p.getCurrentFlow(), closeTo(before! / 35.3147, 0.01),
          reason: 'same cached bytes, re-derived in the new unit');
    });

    test('clearUnitDependentCaches is the same zero-fetch recompute',
        () async {
      final unit = _Unit('CFS');
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: unit);

      await p.loadAllData('123');
      await _settle();
      final readsBefore = repo.reads.length;

      unit.current = 'CMS';
      p.clearUnitDependentCaches(); // the legacy name the unit-flip handler calls

      expect(repo.reads.length, readsBefore);
      expect(repo.refreshes, isEmpty,
          reason: 'the OLD implementation of this method wiped the forecast '
              'disk cache and forced refetches on every surface — the exact '
              'behaviour Phase 3 deletes');
    });
  });

  group('guard 2 mechanism — revalidations merge through watch()', () {
    test('a background revalidation updates the open page', () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      await p.loadAllData('123');
      await _settle();
      expect(p.getCurrentFlow(), closeTo(640, 0.1),
          reason: 'short-range value of the first load');

      // Some other surface (the sheet, a favourites refresh) revalidated the
      // same key and the cache notified.
      repo.shortRangeFlow = 900;
      repo.pushRevalidation(ForecastProduct.shortRange);
      await _settle();

      expect(p.getCurrentFlow(), closeTo(900, 0.1),
          reason: 'the provider must follow the shared cache, not a private '
              'copy — this is how every surface shows the same value');
    });

    test('a revalidation for a CLEARED reach does not resurrect it', () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      await p.loadAllData('123');
      await _settle();
      p.clear();

      repo.pushRevalidation(ForecastProduct.shortRange);
      await _settle();

      expect(p.currentForecast, isNull);
    });
  });

  group('the merge preserves return periods across watch events', () {
    // SAME-PASS item from review round 1: _mergeForecastData keeps the richer
    // reach, so a revalidation landing AFTER the return-period merge must not
    // strip the thresholds — mutating the merge to always take newData.reach
    // survived the whole suite.
    test('a late revalidation does not drop merged return periods', () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      await p.loadAllData('123');
      await _settle();
      expect(p.hasSupplementaryData, isTrue,
          reason: 'precondition: the thresholds have merged');

      // A background revalidation of short range arrives through the watch —
      // its decoded reach carries NO return periods.
      repo.pushRevalidation(ForecastProduct.shortRange);
      await _settle();

      expect(p.hasSupplementaryData, isTrue,
          reason: 'the merge must keep the reach that has the thresholds — '
              'taking the newcomer wholesale silently kills every flood '
              'category on the open page');
    });
  });

  group('comprehensiveRefresh', () {
    test('forces a refetch of all four products through the one cache',
        () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      await p.loadAllData('123');
      await _settle();

      final ok = await p.comprehensiveRefresh('123');
      await _settle();

      expect(ok, isTrue);
      expect(
          repo.refreshes,
          containsAll([
            ForecastProduct.shortRange,
            ForecastProduct.mediumRange,
            ForecastProduct.longRange,
            ForecastProduct.returnPeriods,
          ]),
          reason: 'pull-to-refresh is the ONE place a forced fetch is right');
    });
  });

  group('display derivations (ex-mixin API, now pure)', () {
    test('getCurrentFlow / getFlowCategory / types derive from the response',
        () async {
      final repo = _Repo();
      final p = ReachDataProvider(repository: repo, unitService: _Unit('CFS'));

      await p.loadAllData('123');
      await _settle();

      expect(p.getCurrentFlow(), isNotNull);
      expect(p.getFlowCategory(), isNot('Unknown'));
      expect(p.getShortRangeHourlyData(), isNotEmpty);
    });
  });
}
