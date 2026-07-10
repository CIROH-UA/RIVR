// test/services/4_infrastructure/cache/river_data_cache_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/4_infrastructure/cache/river_data_cache.dart';

void main() {
  late Directory tempDir;

  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.shortRange,
  );

  RiverDataEntry entryWith(double value) => RiverDataEntry(
    key: key,
    window: FreshnessWindow(
      fetchedAt: DateTime.utc(2026, 7, 10, 12, 0),
      validUntil: DateTime.utc(2026, 7, 10, 13, 0),
    ),
    payload: {'currentFlow': value, 'unit': 'CMS'},
  );

  RiverDataCache newCache() =>
      RiverDataCache(cacheDirProvider: () async => tempDir);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rivr_cache_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('put then get returns the entry from memory', () async {
    final cache = newCache();
    await cache.initialize();

    await cache.put(entryWith(100));
    final got = await cache.get(key);

    expect(got, isNotNull);
    expect(got!.payload['currentFlow'], 100);
  });

  test('get returns null for an unknown key', () async {
    final cache = newCache();
    await cache.initialize();
    expect(await cache.get(key), isNull);
  });

  test('persists to disk — a fresh instance hydrates from the same dir',
      () async {
    final writer = newCache();
    await writer.initialize();
    await writer.put(entryWith(250));

    // Simulate a new app launch: brand-new cache object, same directory.
    final reader = newCache();
    await reader.initialize();
    final got = await reader.get(key);

    expect(got, isNotNull);
    expect(got!.payload['currentFlow'], 250);
    expect(got.window.validUntil, DateTime.utc(2026, 7, 10, 13, 0));
  });

  test('listenable notifies observers on put (one fetch fans out)', () async {
    final cache = newCache();
    await cache.initialize();

    final listenable = cache.listenable(key);
    var notifications = 0;
    listenable.addListener(() => notifications++);

    expect(listenable.value, isNull);
    await cache.put(entryWith(300));

    expect(notifications, 1);
    expect(listenable.value!.payload['currentFlow'], 300);
  });

  test('evict removes from memory, disk, and observers', () async {
    final cache = newCache();
    await cache.initialize();
    await cache.put(entryWith(400));

    await cache.evict(key);

    expect(await cache.get(key), isNull);
    expect(cache.listenable(key).value, isNull);
    // fresh instance also sees nothing on disk
    final reader = newCache();
    await reader.initialize();
    expect(await reader.get(key), isNull);
  });

  test('clear drops everything', () async {
    final cache = newCache();
    await cache.initialize();
    await cache.put(entryWith(500));

    await cache.clear();

    expect(await cache.get(key), isNull);
  });

  test('put still works before initialize (memory only, no crash)', () async {
    final cache = newCache(); // not initialized -> _dir == null
    await cache.put(entryWith(600));
    expect((await cache.get(key))!.payload['currentFlow'], 600);
  });
}
