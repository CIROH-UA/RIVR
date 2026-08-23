// test/services/4_infrastructure/river_data/river_data_repository_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';

/// In-memory [IRiverDataCache] so repository tests are isolated from disk /
/// path_provider (the real RiverDataCache is covered by its own test).
class _MemoryCache implements IRiverDataCache {
  final Map<String, RiverDataEntry> _mem = {};
  final Map<String, ValueNotifier<RiverDataEntry?>> _notifiers = {};

  ValueNotifier<RiverDataEntry?> _n(RiverDataKey k) => _notifiers.putIfAbsent(
    k.storageKey,
    () => ValueNotifier(_mem[k.storageKey]),
  );

  @override
  Future<void> initialize() async {}
  @override
  bool get isReady => true;
  @override
  void setPinnedReaches(Set<String> reachIds) {}
  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async => _mem[key.storageKey];
  @override
  Future<void> put(RiverDataEntry entry) async {
    _mem[entry.key.storageKey] = entry;
    _n(entry.key).value = entry;
  }

  @override
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key) => _n(key);
  @override
  Future<void> evict(RiverDataKey key) async {
    _mem.remove(key.storageKey);
    _notifiers[key.storageKey]?.value = null;
  }

  @override
  Future<void> clear() async {
    _mem.clear();
    for (final n in _notifiers.values) {
      n.value = null;
    }
  }
}

/// A source whose fetches are counted and whose freshness window is fixed by
/// [validFor], so freshness is driven entirely by the injected clock.
class _ControllableSource implements IRiverDataSource {
  _ControllableSource({required this.source, required this.validFor});

  @override
  final ForecastSource source;
  final Duration validFor;

  int fetchCount = 0;
  double nextValue = 1.0;

  /// The network is down. Guard: "a stream you looked at earlier still draws
  /// instantly with the network off" — round 1 found no test anywhere made a
  /// source throw, so the stale-serve-on-failed-revalidation path (the entire
  /// mechanism behind offline draw) was unguarded.
  bool offline = false;

  /// Payload override, for tests that decode the fetched entry for real.
  Map<String, dynamic>? nextPayload;

  @override
  Set<ForecastProduct> get supportedProducts => ForecastProduct.values.toSet();

  @override
  DateTime validUntil(ForecastProduct product, DateTime now) =>
      now.toUtc().add(validFor);

  /// The model run the next fetch reports, when set.
  String? nextRunId;

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    fetchCount++;
    if (offline) throw Exception('network unreachable');
    return SourceFetchResult(
        payload: nextPayload ?? {'value': nextValue},
        unit: 'CMS',
        runId: nextRunId);
  }
}

class _StubUnit implements IFlowUnitPreferenceService {
  _StubUnit({required this.current});

  /// Mutable: guard 6's driveable input IS the preference changing mid-test.
  String current;
  @override
  String get currentFlowUnit => current;
  @override
  String getDisplayUnit() => current == 'CFS' ? 'ft³/s' : 'm³/s';
  @override
  double convertFlow(double v, String from, String to) {
    if (from == to) return v;
    if (from == 'CMS' && to == 'CFS') return v * 35.3147;
    if (from == 'CFS' && to == 'CMS') return v / 35.3147;
    return v;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.shortRange,
  );

  late _ControllableSource source;
  late _MemoryCache cache;
  late DateTime now;
  late RiverDataRepository repo;

  setUp(() {
    source = _ControllableSource(
      source: ForecastSource.nwm,
      validFor: const Duration(hours: 1),
    );
    cache = _MemoryCache();
    now = DateTime.utc(2026, 7, 10, 12, 0);
    repo = RiverDataRepository(
      cache: cache,
      registry: SourceRegistry([source]),
      clock: () => now,
    );
  });

  test('read miss fetches, caches, and returns the value', () async {
    final entry = await repo.read(key);
    expect(entry, isNotNull);
    expect(entry!.payload['value'], 1.0);
    expect(entry.unit, 'CMS');
    expect(source.fetchCount, 1);
  });

  test('read within the freshness window serves cache, no second fetch',
      () async {
    await repo.read(key);
    now = now.add(const Duration(minutes: 30)); // still < 1h
    final again = await repo.read(key);

    expect(source.fetchCount, 1);
    expect(again!.payload['value'], 1.0);
  });

  test('read past validUntil serves stale then revalidates in background',
      () async {
    await repo.read(key); // value 1.0, fetchCount 1
    now = now.add(const Duration(hours: 2)); // now stale
    source.nextValue = 2.0;

    final stale = await repo.read(key);
    expect(stale!.payload['value'], 1.0); // served stale immediately

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(source.fetchCount, 2); // background revalidation ran
    final refreshed = await cache.get(key);
    expect(refreshed!.payload['value'], 2.0);
    expect(cache.listenable(key).value!.payload['value'], 2.0);
  });

  test('concurrent reads on a cold key share one fetch', () async {
    final results = await Future.wait([repo.read(key), repo.read(key)]);
    expect(source.fetchCount, 1);
    expect(results.every((e) => e!.payload['value'] == 1.0), isTrue);
  });

  test('refresh always fetches, even when fresh', () async {
    await repo.read(key); // fetchCount 1
    source.nextValue = 5.0;
    final refreshed = await repo.refresh(key);

    expect(source.fetchCount, 2);
    expect(refreshed!.payload['value'], 5.0);
  });

  test('watch returns an observable that populates after read', () async {
    final listenable = repo.watch(key);
    expect(listenable.value, isNull);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(listenable.value, isNotNull);
    expect(listenable.value!.payload['value'], 1.0);
  });

  test('ingest inserts an externally-produced entry and notifies', () async {
    final pushed = RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        fetchedAt: now,
        validUntil: now.add(const Duration(hours: 1)),
      ),
      unit: 'CMS',
      payload: const {'value': 99.0},
    );

    await repo.ingest(pushed);

    expect((await cache.get(key))!.payload['value'], 99.0);
    expect(cache.listenable(key).value!.payload['value'], 99.0);
    expect(source.fetchCount, 0); // no network involved
  });
  // ADR 0011 Phase 1 — the claim that "See forecast" is warm with nothing
  // warming it. The sheet and the forecast page were made to read the SAME
  // three narrow keys; that is only worth anything if the second surface
  // genuinely hits cache. Asserted rather than assumed, because the previous
  // design achieved warmth by an explicit background warm that also pulled a
  // 156 KB series and duplicated the entry.
  // ─── ADR 0011 Phase 2, guards 1 and 6 ─────────────────────────────────────

  group('entries record their run (ADR 0011 Phase 2 build line)', () {
    // Round 5 found the "entries record the run they came from" build line
    // unimplemented: the entry carried only a schedule window, so what a
    // revalidation brought back was not decidable from the stored data.
    test('the run id travels from source to cached entry', () async {
      source.nextRunId = '2026-08-23T12:00:00Z';

      final entry = await repo.read(key);

      expect(entry!.runId, '2026-08-23T12:00:00Z',
          reason: 'without it, two fetches of the same run are '
              'indistinguishable from a real update');
      // And it survives the JSON round-trip the disk tier uses.
      final rt = RiverDataEntry.fromJson(entry.toJson());
      expect(rt.runId, '2026-08-23T12:00:00Z');
    });

    // The no-run-identity case is guarded at the SOURCE layer
    // (data_sources_test: returnPeriods → null, GEOGLOWS fallback → null),
    // where the decision lives. A repository-level copy only pinned the
    // fake's default and was cut in round 7 as vacuous.
  });

  group('offline — a cached reach still draws with the network off', () {
    // The phase's "you are done when" names this outright, and round 1 proved
    // the whole 1019-test suite green with the revalidation made blocking and
    // throwing — offline would have shown a network error instead of the
    // cached river, and nothing could see it.
    test('a stale entry is served even though revalidation throws', () async {
      await repo.read(key); // fetch 1, cached
      now = now.add(const Duration(hours: 2)); // past the window
      source.offline = true;

      final got = await repo.read(key);

      expect(got, isNotNull,
          reason: 'the cached value is the only value there is — offline, '
              'stale-and-served beats fresh-and-thrown every time');
      expect(got!.payload['value'], 1.0);
      // Let the failed background revalidation settle.
      await Future<void>.delayed(Duration.zero);
      expect(source.fetchCount, 2,
          reason: 'the revalidation was attempted — offline serving must not '
              'come from skipping revalidation entirely');
    });

    test('a fresh entry offline is served without any attempt', () async {
      await repo.read(key);
      source.offline = true;

      final got = await repo.read(key);

      expect(got, isNotNull);
      expect(source.fetchCount, 1);
    });

    test('a cold miss offline propagates — there is nothing to serve',
        () async {
      source.offline = true;

      await expectLater(repo.read(key), throwsA(isA<Exception>()),
          reason: 'inventing data would be worse; the surfaces render their '
              'named error states from this');
    });
  });

  // Guard 1's "ONE background revalidation": the stale path shares the same
  // _inFlight dedup as the cold path, asserted here rather than inferred.
  test('concurrent stale reads share one revalidation', () async {
    await repo.read(key); // fetch 1
    now = now.add(const Duration(hours: 2)); // stale

    await Future.wait([repo.read(key), repo.read(key), repo.read(key)]);
    await Future<void>.delayed(Duration.zero);

    expect(source.fetchCount, 2,
        reason: 'three stale readers must fund ONE revalidate between them — '
            'the original fetch plus one, not plus three');
  });

  group('guard 1 — run supersession, not wall-clock', () {
    // "Tap → back → tap again issues nothing." The window encodes the next
    // possible publish, so inside it a re-read must cost zero fetches no
    // matter how much wall-clock time the entry has already survived.
    test('a wall-clock-old entry inside its run window fetches nothing',
        () async {
      await repo.read(key); // fetch 1, valid for 1 h
      // 55 minutes pass — old by any TTL habit, current by run schedule.
      now = now.add(const Duration(minutes: 55));

      await repo.read(key); // tap
      await repo.read(key); // back, tap again

      expect(source.fetchCount, 1,
          reason: 'the upstream run has not advanced; any refetch here is '
              'spend without information');
    });
  });

  group('guard 6 — a unit-preference change costs zero refetches', () {
    // The driveable input is the preference itself, flipped mid-test on ONE
    // mutable service — the shape the app actually produces (the settings page
    // mutates the singleton and surfaces re-render). Zero refetches falls out
    // structurally: the unit is not part of RiverDataKey, so the second read
    // resolves the identical entry; conversion happens at decode, per render.
    // Round 2 rejected a version that flipped nothing and asserted a property
    // two other tests already pinned.
    test('flipping the preference re-renders from the same entry, no fetch',
        () async {
      source.nextPayload = {
        'returnPeriods': [
          {'feature_id': '23021904', 'return_period_2': 100.0},
        ],
      };
      const rpKey = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.returnPeriods,
      );
      final unitService = _StubUnit(current: 'CMS');

      // Render #1 under CMS.
      final entry = await repo.read(rpKey);
      final before = ReturnPeriodPayload.decode(entry!, unitService);
      expect(before![2], 100.0);

      // The user flips the preference; the surface re-renders.
      unitService.current = 'CFS';
      final again = await repo.read(rpKey);
      final after = ReturnPeriodPayload.decode(again!, unitService);

      expect(source.fetchCount, 1,
          reason: 'the flip must cost zero fetches — the unit is not part of '
              'the key, so the cache cannot even distinguish the two reads');
      expect(identical(entry, again), isTrue,
          reason: 'literally the same cached entry, not a refetched copy');
      expect(after![2], closeTo(3531.47, 0.1),
          reason: 'and the re-render converts: same bytes, new preference');
    });
  });

  group('sheet -> forecast page is a cache hit', () {
    const products = [
      ForecastProduct.reachMetadata,
      ForecastProduct.analysisAssimilation,
      ForecastProduct.returnPeriods,
    ];

    RiverDataKey keyFor(ForecastProduct p) => RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '23021904',
          product: p,
        );

    test('the forecast page issues zero fetches after the sheet has loaded',
        () async {
      // Sheet opens.
      for (final p in products) {
        await repo.read(keyFor(p));
      }
      final afterSheet = source.fetchCount;
      expect(afterSheet, products.length);

      // User taps "See forecast" — same keys.
      for (final p in products) {
        await repo.read(keyFor(p));
      }

      expect(source.fetchCount, afterSheet,
          reason: 'the page must not refetch what the sheet already holds');
    });

    test('the two surfaces receive the identical entry, not equal copies',
        () async {
      final fromSheet = await repo.read(keyFor(ForecastProduct.analysisAssimilation));
      source.nextValue = 999.0; // would differ if the page refetched
      final fromPage = await repo.read(keyFor(ForecastProduct.analysisAssimilation));

      expect(fromPage!.payload['value'], fromSheet!.payload['value'],
          reason: 'one cache entry per value is what stops the gauge and the '
              'sheet disagreeing');
      expect(fromPage.payload['value'], 1.0);
    });
  });

}
