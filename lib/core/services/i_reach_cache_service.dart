// lib/core/services/i_reach_cache_service.dart

import '../models/reach_data.dart';

/// Cache freshness level for stale-while-revalidate pattern.
enum CacheFreshness { fresh, stale }

/// Wrapper for cached data with freshness information.
class CacheResult<T> {
  final T data;
  final CacheFreshness freshness;

  const CacheResult({required this.data, required this.freshness});

  bool get isFresh => freshness == CacheFreshness.fresh;
  bool get isStale => freshness == CacheFreshness.stale;
}

/// Interface for caching ReachData objects
abstract class IReachCacheService {
  Future<void> initialize();
  bool get isReady;
  Future<ReachData?> get(String reachId);
  Future<CacheResult<ReachData>?> getWithFreshness(String reachId);
  Future<void> store(ReachData reachData);
  Future<void> clearReach(String reachId);
  Future<void> clear();
  Future<bool> isCached(String reachId);
  Future<Map<String, dynamic>> getCacheStats();
  Map<String, dynamic> getCacheEffectiveness();
  Future<void> forceRefresh(String reachId);
  Future<int> cleanupStaleEntries();
}
