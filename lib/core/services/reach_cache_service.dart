// lib/core/services/reach_cache_service.dart

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/core/services/app_logger.dart';
import '../models/reach_data.dart';
import 'i_reach_cache_service.dart';

/// Simple cache service for ReachData objects
/// Stores reach info permanently (6 months) to avoid repeated API calls for static data
class ReachCacheService implements IReachCacheService {
  ReachCacheService();

  SharedPreferences? _prefs;

  int _cacheHits = 0;
  int _cacheMisses = 0;

  // Cache configuration
  static const Duration _cacheMaxAge = Duration(days: 180); // 6 months
  static const Duration _cacheFreshness = Duration(hours: 6); // NWM update cycle
  static const String _keyPrefix = 'reach_cache_';

  /// Initialize the cache service
  @override
  Future<void> initialize() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      AppLogger.info('ReachCacheService', 'Initialized successfully');
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error initializing', e);
    }
  }

  /// Get cached ReachData by reach ID
  /// Returns null if not cached or cache is stale
  @override
  Future<ReachData?> get(String reachId) async {
    try {
      await _ensureInitialized();

      final key = _keyPrefix + reachId;
      final cachedJson = _prefs!.getString(key);

      if (cachedJson == null) {
        _cacheMisses++;
        AppLogger.debug(
          'ReachCacheService',
          'No cache found for reach: $reachId (Miss: $_cacheMisses)',
        );
        return null;
      }

      final data = jsonDecode(cachedJson) as Map<String, dynamic>;
      final reachData = ReachData.fromJson(data);

      // Check if cache is stale (6 months)
      if (reachData.isCacheStale(maxAge: _cacheMaxAge)) {
        _cacheMisses++;
        AppLogger.debug(
          'ReachCacheService',
          'Cache stale for reach: $reachId (${reachData.cachedAt}) (Miss: $_cacheMisses)',
        );
        // Remove stale cache
        await _prefs!.remove(key);
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

  /// Get cached ReachData with freshness information for stale-while-revalidate.
  /// Returns null if not cached or expired (> 180 days).
  /// Returns CacheResult with fresh (< 6 hours) or stale (6h - 180d) status.
  @override
  Future<CacheResult<ReachData>?> getWithFreshness(String reachId) async {
    try {
      await _ensureInitialized();

      final key = _keyPrefix + reachId;
      final cachedJson = _prefs!.getString(key);

      if (cachedJson == null) {
        _cacheMisses++;
        return null;
      }

      final data = jsonDecode(cachedJson) as Map<String, dynamic>;
      final reachData = ReachData.fromJson(data);
      final age = DateTime.now().difference(reachData.cachedAt);

      // Expired (> 180 days): treat as miss
      if (age > _cacheMaxAge) {
        _cacheMisses++;
        await _prefs!.remove(key);
        return null;
      }

      _cacheHits++;

      // Fresh (< 6 hours): no refresh needed
      if (age <= _cacheFreshness) {
        return CacheResult(data: reachData, freshness: CacheFreshness.fresh);
      }

      // Stale (6h - 180d): return data, caller should refresh in background
      return CacheResult(data: reachData, freshness: CacheFreshness.stale);
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error in getWithFreshness for $reachId', e);
      return null;
    }
  }

  /// Store ReachData in cache
  @override
  Future<void> store(ReachData reachData) async {
    try {
      await _ensureInitialized();

      final key = _keyPrefix + reachData.reachId;
      final jsonString = jsonEncode(reachData.toJson());

      await _prefs!.setString(key, jsonString);
      AppLogger.debug(
        'ReachCacheService',
        'Stored reach: ${reachData.reachId} (${reachData.displayName})',
      );
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error storing reach ${reachData.reachId}', e);
      // Don't throw - caching should not break the app
    }
  }

  /// Clear specific reach from cache
  @override
  Future<void> clearReach(String reachId) async {
    try {
      await _ensureInitialized();

      final key = _keyPrefix + reachId;
      await _prefs!.remove(key);
      AppLogger.debug('ReachCacheService', 'Cleared cache for reach: $reachId');
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error clearing reach $reachId', e);
    }
  }

  /// Clear all cached reaches
  @override
  Future<void> clear() async {
    try {
      await _ensureInitialized();

      final keys = _prefs!.getKeys();
      final reachKeys = keys.where((key) => key.startsWith(_keyPrefix));

      for (final key in reachKeys) {
        await _prefs!.remove(key);
      }

      AppLogger.info('ReachCacheService', 'Cleared ${reachKeys.length} cached reaches');
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error clearing all cache', e);
    }
  }

  /// Check if reach is cached and valid
  @override
  Future<bool> isCached(String reachId) async {
    final cached = await get(reachId);
    return cached != null;
  }

  /// Get cache statistics for debugging
  @override
  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      await _ensureInitialized();

      final keys = _prefs!.getKeys();
      final reachKeys = keys
          .where((key) => key.startsWith(_keyPrefix))
          .toList();

      int validCount = 0;
      int staleCount = 0;
      DateTime? oldestCache;
      DateTime? newestCache;

      for (final key in reachKeys) {
        try {
          final cachedJson = _prefs!.getString(key);
          if (cachedJson != null) {
            final data = jsonDecode(cachedJson) as Map<String, dynamic>;
            final reachData = ReachData.fromJson(data);

            if (reachData.isCacheStale(maxAge: _cacheMaxAge)) {
              staleCount++;
            } else {
              validCount++;
            }

            if (oldestCache == null ||
                reachData.cachedAt.isBefore(oldestCache)) {
              oldestCache = reachData.cachedAt;
            }
            if (newestCache == null ||
                reachData.cachedAt.isAfter(newestCache)) {
              newestCache = reachData.cachedAt;
            }
          }
        } catch (e) {
          // Skip invalid entries
          continue;
        }
      }

      return {
        'totalCached': reachKeys.length,
        'validCount': validCount,
        'staleCount': staleCount,
        'oldestCache': oldestCache?.toIso8601String(),
        'newestCache': newestCache?.toIso8601String(),
      };
    } catch (e) {
      AppLogger.error('ReachCacheService', 'Error getting cache stats', e);
      return {'error': e.toString()};
    }
  }

  /// Get cache effectiveness stats
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

  /// Force refresh a reach (clear cache and require fresh API call)
  @override
  Future<void> forceRefresh(String reachId) async {
    AppLogger.debug('ReachCacheService', 'Force refresh requested for reach: $reachId');
    await clearReach(reachId);
  }

  /// Clean up stale cache entries
  @override
  Future<int> cleanupStaleEntries() async {
    try {
      await _ensureInitialized();

      final keys = _prefs!.getKeys();
      final reachKeys = keys.where((key) => key.startsWith(_keyPrefix));
      int cleanedCount = 0;

      for (final key in reachKeys) {
        try {
          final cachedJson = _prefs!.getString(key);
          if (cachedJson != null) {
            final data = jsonDecode(cachedJson) as Map<String, dynamic>;
            final reachData = ReachData.fromJson(data);

            if (reachData.isCacheStale(maxAge: _cacheMaxAge)) {
              await _prefs!.remove(key);
              cleanedCount++;
            }
          }
        } catch (e) {
          // Remove invalid entries too
          await _prefs!.remove(key);
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

  /// Helper method to ensure SharedPreferences is initialized
  Future<void> _ensureInitialized() async {
    if (_prefs == null) {
      await initialize();
    }
  }

  /// Check if cache service is ready
  @override
  bool get isReady => _prefs != null;
}
