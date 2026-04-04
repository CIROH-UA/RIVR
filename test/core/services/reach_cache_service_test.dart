import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rivr/core/services/reach_cache_service.dart';

import '../../helpers/fake_data.dart';

// ---------------------------------------------------------------------------
// Minimal PathProviderPlatform mock that routes getApplicationCachePath to
// a temporary directory created for the test run.
// ---------------------------------------------------------------------------
class _TempPathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String tempPath;
  _TempPathProvider(this.tempPath);

  @override
  Future<String?> getApplicationCachePath() async => tempPath;

  // All other path methods are unused by ReachCacheService — throw to make
  // any unexpected call visible rather than silently returning null.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not mocked');
}

// ---------------------------------------------------------------------------

void main() {
  late ReachCacheService cache;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('rivr_cache_test_');
    PathProviderPlatform.instance = _TempPathProvider(tempDir.path);
  });

  tearDownAll(() async {
    // Clean up temp directory after all tests complete
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    cache = ReachCacheService();
    await cache.initialize();
    await cache.clear();
  });

  group('ReachCacheService', () {
    group('store & get', () {
      test('stores and retrieves a reach', () async {
        final reach = createTestReachData(
          reachId: '12345',
          riverName: 'Test Creek',
          cachedAt: DateTime.now(),
        );

        await cache.store(reach);
        final retrieved = await cache.get('12345');

        expect(retrieved, isNotNull);
        expect(retrieved!.reachId, '12345');
        expect(retrieved.riverName, 'Test Creek');
      });

      test('stores multiple reaches independently', () async {
        final reach1 = createTestReachData(
          reachId: '111',
          riverName: 'River One',
          cachedAt: DateTime.now(),
        );
        final reach2 = createTestReachData(
          reachId: '222',
          riverName: 'River Two',
          cachedAt: DateTime.now(),
        );

        await cache.store(reach1);
        await cache.store(reach2);

        final r1 = await cache.get('111');
        final r2 = await cache.get('222');

        expect(r1?.riverName, 'River One');
        expect(r2?.riverName, 'River Two');
      });

      test('overwrites existing cache for same reachId', () async {
        final original = createTestReachData(
          reachId: '111',
          riverName: 'Original',
          cachedAt: DateTime.now(),
        );
        final updated = createTestReachData(
          reachId: '111',
          riverName: 'Updated',
          cachedAt: DateTime.now(),
        );

        await cache.store(original);
        await cache.store(updated);

        final retrieved = await cache.get('111');
        expect(retrieved?.riverName, 'Updated');
      });
    });

    group('cache miss', () {
      test('returns null for non-existent reachId', () async {
        final result = await cache.get('nonexistent');
        expect(result, isNull);
      });
    });

    group('cache staleness', () {
      test('returns null for data cached > 180 days ago', () async {
        // Store via cache.store() — the data has a stale cachedAt
        final staleReach = createTestReachData(
          reachId: '999',
          cachedAt: DateTime.now().subtract(const Duration(days: 200)),
        );
        await cache.store(staleReach);

        // get() checks staleness and should return null
        final result = await cache.get('999');
        expect(result, isNull);
      });

      test('returns data for recently cached entry', () async {
        final freshReach = createTestReachData(
          reachId: '888',
          cachedAt: DateTime.now().subtract(const Duration(days: 10)),
        );

        await cache.store(freshReach);
        final result = await cache.get('888');

        expect(result, isNotNull);
        expect(result!.reachId, '888');
      });
    });

    group('clearReach', () {
      test('removes specific entry', () async {
        await cache.store(createTestReachData(
          reachId: 'A',
          cachedAt: DateTime.now(),
        ));
        await cache.store(createTestReachData(
          reachId: 'B',
          cachedAt: DateTime.now(),
        ));

        await cache.clearReach('A');

        expect(await cache.get('A'), isNull);
        expect(await cache.get('B'), isNotNull);
      });
    });

    group('clear', () {
      test('removes all cached reaches', () async {
        await cache.store(createTestReachData(
          reachId: 'X',
          cachedAt: DateTime.now(),
        ));
        await cache.store(createTestReachData(
          reachId: 'Y',
          cachedAt: DateTime.now(),
        ));

        await cache.clear();

        expect(await cache.get('X'), isNull);
        expect(await cache.get('Y'), isNull);
      });
    });

    group('isCached', () {
      test('returns true for cached reach', () async {
        await cache.store(createTestReachData(
          reachId: '100',
          cachedAt: DateTime.now(),
        ));

        expect(await cache.isCached('100'), true);
      });

      test('returns false for missing reach', () async {
        expect(await cache.isCached('missing'), false);
      });
    });

    group('getCacheStats', () {
      test('reports correct counts with fresh and stale entries', () async {
        // Store 2 fresh entries
        await cache.store(createTestReachData(
          reachId: 'fresh1',
          cachedAt: DateTime.now(),
        ));
        await cache.store(createTestReachData(
          reachId: 'fresh2',
          cachedAt: DateTime.now(),
        ));

        // Store 1 stale entry (store() doesn't check staleness)
        await cache.store(createTestReachData(
          reachId: 'stale1',
          cachedAt: DateTime.now().subtract(const Duration(days: 200)),
        ));

        final stats = await cache.getCacheStats();

        expect(stats['totalCached'], 3);
        expect(stats['validCount'], 2);
        expect(stats['staleCount'], 1);
      });
    });

    group('getCacheEffectiveness', () {
      test('tracks hits and misses', () async {
        await cache.store(createTestReachData(
          reachId: 'hit1',
          cachedAt: DateTime.now(),
        ));

        // Generate some hits and misses
        await cache.get('hit1'); // hit
        await cache.get('miss1'); // miss
        await cache.get('miss2'); // miss

        final effectiveness = cache.getCacheEffectiveness();

        expect(effectiveness['hits'], isA<int>());
        expect(effectiveness['misses'], isA<int>());
        expect(effectiveness['total'], isA<int>());
        expect(effectiveness['hitRate'], isA<double>());
        expect(effectiveness['total'] as int, greaterThan(0));
      });
    });

    group('cleanupStaleEntries', () {
      test('removes stale entries and returns count', () async {
        // Fresh entry
        await cache.store(createTestReachData(
          reachId: 'fresh',
          cachedAt: DateTime.now(),
        ));

        // Stale entry via cache.store() (store doesn't check staleness)
        await cache.store(createTestReachData(
          reachId: 'old',
          cachedAt: DateTime.now().subtract(const Duration(days: 200)),
        ));

        final cleanedCount = await cache.cleanupStaleEntries();

        expect(cleanedCount, 1);
        expect(await cache.get('fresh'), isNotNull);
        expect(await cache.get('old'), isNull);
      });

      test('returns 0 when no stale entries', () async {
        await cache.store(createTestReachData(
          reachId: 'ok',
          cachedAt: DateTime.now(),
        ));

        final count = await cache.cleanupStaleEntries();
        expect(count, 0);
      });
    });

    group('forceRefresh', () {
      test('removes cached entry', () async {
        await cache.store(createTestReachData(
          reachId: 'refresh_me',
          cachedAt: DateTime.now(),
        ));

        await cache.forceRefresh('refresh_me');
        expect(await cache.get('refresh_me'), isNull);
      });
    });

    group('isReady', () {
      test('is true after initialization', () async {
        await cache.initialize();
        expect(cache.isReady, true);
      });
    });
  });
}
