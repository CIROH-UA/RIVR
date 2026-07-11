// test/services/4_infrastructure/river_data/river_data_repository_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
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

  @override
  Set<ForecastProduct> get supportedProducts => ForecastProduct.values.toSet();

  @override
  DateTime validUntil(ForecastProduct product, DateTime now) =>
      now.toUtc().add(validFor);

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    fetchCount++;
    return SourceFetchResult(payload: {'value': nextValue}, unit: 'CMS');
  }
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
}
