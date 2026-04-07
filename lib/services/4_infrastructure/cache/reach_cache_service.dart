// lib/services/4_infrastructure/cache/reach_cache_service.dart

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';

/// File-based cache service for ReachData objects.
/// Stores one JSON file per reach under:
///   `<cacheDir>/rivr_reach_cache/<reachId>.json`
///
/// File format: `{ "timestamp": <epochMs>, "data": { ...reachData toJson()... } }`
class ReachCacheService implements IReachCacheService {
  ReachCacheService();

  Directory? _cacheDir;

  int _cacheHits = 0;
  int _cacheMisses = 0;

  // Cache configuration
  static const Duration _cacheMaxAge = Duration(days: 180); // 6 months
  static const Duration _cacheFreshness = Duration(hours: 6); // NWM update cycle
  static const String _cacheDirName = 'rivr_reach_cache';

  // ── Initialisation ───────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    try {
      final base = await getApplicationCacheDirectory();
      _cacheDir = Directory('${base.path}/$_cacheDirName');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      AppLogger.info('ReachCacheService', 'Initialized at ${_cacheDir!.path}');
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error initializing', e);
    }
  }

  // ── Core CRUD ────────────────────────────────────────────────────────────────

  @override
  Future<ReachData?> get(String reachId) async {
    try {
      await _ensureInitialized();

      final file = _fileFor(reachId);
      if (!await file.exists()) {
        _cacheMisses++;
        AppLogger.debug(
          'ReachCacheService',
          'No cache found for reach: $reachId (Miss: $_cacheMisses)',
        );
        return null;
      }

      final wrapper = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final reachData = ReachDataDto.fromJson(wrapper['data'] as Map<String, dynamic>).toEntity();

      // Check expiry (6 months)
      if (reachData.isCacheStale(maxAge: _cacheMaxAge)) {
        _cacheMisses++;
        AppLogger.debug(
          'ReachCacheService',
          'Cache stale for reach: $reachId (${reachData.cachedAt}) (Miss: $_cacheMisses)',
        );
        await file.delete();
        return null;
      }

      _cacheHits++;
      AppLogger.debug('ReachCacheService', 'Cache hit for reach: $reachId (Hits: $_cacheHits)');
      return reachData;
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error getting cached reach $reachId', e);
      return null;
    }
  }

  @override
  Future<CacheResult<ReachData>?> getWithFreshness(String reachId) async {
    try {
      await _ensureInitialized();

      final file = _fileFor(reachId);
      if (!await file.exists()) {
        _cacheMisses++;
        return null;
      }

      final wrapper = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final reachData = ReachDataDto.fromJson(wrapper['data'] as Map<String, dynamic>).toEntity();
      final age = DateTime.now().difference(reachData.cachedAt);

      // Expired (> 180 days): treat as miss
      if (age > _cacheMaxAge) {
        _cacheMisses++;
        await file.delete();
        return null;
      }

      _cacheHits++;

      // Fresh (< 6 hours): no refresh needed
      if (age <= _cacheFreshness) {
        return CacheResult(data: reachData, freshness: CacheFreshness.fresh);
      }

      // Stale (6h – 180d): return data, caller should refresh in background
      return CacheResult(data: reachData, freshness: CacheFreshness.stale);
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error in getWithFreshness for $reachId', e);
      return null;
    }
  }

  @override
  Future<void> store(ReachData reachData) async {
    try {
      await _ensureInitialized();

      final wrapper = {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'data': ReachDataDto.fromEntity(reachData).toJson(),
      };
      await _fileFor(reachData.reachId).writeAsString(jsonEncode(wrapper));
      AppLogger.debug(
        'ReachCacheService',
        'Stored reach: ${reachData.reachId} (${reachData.displayName})',
      );
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error storing reach ${reachData.reachId}', e);
      // Don't throw — caching should not break the app
    }
  }

  @override
  Future<void> clearReach(String reachId) async {
    try {
      await _ensureInitialized();

      final file = _fileFor(reachId);
      if (await file.exists()) {
        await file.delete();
      }
      AppLogger.debug('ReachCacheService', 'Cleared cache for reach: $reachId');
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error clearing reach $reachId', e);
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _ensureInitialized();

      final files = await _listCacheFiles();
      for (final file in files) {
        await file.delete();
      }
      AppLogger.info('ReachCacheService', 'Cleared ${files.length} cached reaches');
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error clearing all cache', e);
    }
  }

  @override
  Future<bool> isCached(String reachId) async {
    final cached = await get(reachId);
    return cached != null;
  }

  @override
  Future<void> forceRefresh(String reachId) async {
    AppLogger.debug('ReachCacheService', 'Force refresh requested for reach: $reachId');
    await clearReach(reachId);
  }

  // ── Stats ────────────────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      await _ensureInitialized();

      final files = await _listCacheFiles();
      int validCount = 0;
      int staleCount = 0;
      int totalBytes = 0;
      DateTime? oldestCache;
      DateTime? newestCache;

      for (final file in files) {
        try {
          final stat = await file.stat();
          totalBytes += stat.size;

          final wrapper = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          final reachData = ReachDataDto.fromJson(wrapper['data'] as Map<String, dynamic>).toEntity();

          if (reachData.isCacheStale(maxAge: _cacheMaxAge)) {
            staleCount++;
          } else {
            validCount++;
          }

          if (oldestCache == null || reachData.cachedAt.isBefore(oldestCache)) {
            oldestCache = reachData.cachedAt;
          }
          if (newestCache == null || reachData.cachedAt.isAfter(newestCache)) {
            newestCache = reachData.cachedAt;
          }
        } catch (_) {
          // Skip invalid entries
        }
      }

      return {
        'totalCached': files.length,
        'validCount': validCount,
        'staleCount': staleCount,
        'totalBytes': totalBytes,
        'oldestCache': oldestCache?.toIso8601String(),
        'newestCache': newestCache?.toIso8601String(),
      };
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error getting cache stats', e);
      return {'error': e.toString()};
    }
  }

  @override
  Map<String, dynamic> getCacheEffectiveness() {
    final total = _cacheHits + _cacheMisses;
    final hitRate = total > 0 ? (_cacheHits / total) * 100 : 0.0;

    AppLogger.debug(
      'ReachCacheService',
      'Cache stats: Hits=$_cacheHits, Misses=$_cacheMisses, Rate=${hitRate.toStringAsFixed(1)}%',
    );

    return {
      'hits': _cacheHits,
      'misses': _cacheMisses,
      'total': total,
      'hitRate': hitRate,
    };
  }

  @override
  Future<int> cleanupStaleEntries() async {
    try {
      await _ensureInitialized();

      final files = await _listCacheFiles();
      int cleanedCount = 0;

      for (final file in files) {
        try {
          final wrapper = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          final reachData = ReachDataDto.fromJson(wrapper['data'] as Map<String, dynamic>).toEntity();

          if (reachData.isCacheStale(maxAge: _cacheMaxAge)) {
            await file.delete();
            cleanedCount++;
          }
        } catch (_) {
          // Remove invalid/corrupt entries too
          await file.delete();
          cleanedCount++;
        }
      }

      if (cleanedCount > 0) {
        AppLogger.info('ReachCacheService', 'Cleaned up $cleanedCount stale cache entries');
      }

      return cleanedCount;
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error during cleanup', e);
      return 0;
    }
  }

  // ── isReady ──────────────────────────────────────────────────────────────────

  @override
  bool get isReady => _cacheDir != null;

  // ── Helpers ──────────────────────────────────────────────────────────────────

  File _fileFor(String reachId) => File('${_cacheDir!.path}/$reachId.json');

  Future<List<File>> _listCacheFiles() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) return [];
    return _cacheDir!
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
  }

  Future<void> _ensureInitialized() async {
    if (_cacheDir == null) {
      await initialize();
    }
  }
}
