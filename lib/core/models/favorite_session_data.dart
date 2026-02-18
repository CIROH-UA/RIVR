// lib/core/models/favorite_session_data.dart

/// Grouped session data for a single favorite river.
/// Replaces the 7 parallel maps previously in FavoritesProvider.
/// This data is ephemeral (refreshed each session) except for
/// customName and customImageAsset which are persisted locally.
class FavoriteSessionData {
  final String? riverName;
  final double? lastKnownFlow;
  final String? flowUnit;
  final DateTime? lastUpdated;
  final ({double lat, double lon})? coordinates;
  final String? customName;
  final String? customImageAsset;

  const FavoriteSessionData({
    this.riverName,
    this.lastKnownFlow,
    this.flowUnit,
    this.lastUpdated,
    this.coordinates,
    this.customName,
    this.customImageAsset,
  });

  /// Create a copy with updated fields. Pass [_sentinel] to explicitly
  /// clear a nullable field (distinguish "not provided" from "set to null").
  FavoriteSessionData copyWith({
    String? riverName,
    Object? lastKnownFlow = _sentinel,
    String? flowUnit,
    Object? lastUpdated = _sentinel,
    ({double lat, double lon})? coordinates,
    String? customName,
    Object? customImageAsset = _sentinel,
  }) {
    return FavoriteSessionData(
      riverName: riverName ?? this.riverName,
      lastKnownFlow: lastKnownFlow == _sentinel
          ? this.lastKnownFlow
          : lastKnownFlow as double?,
      flowUnit: flowUnit ?? this.flowUnit,
      lastUpdated: lastUpdated == _sentinel
          ? this.lastUpdated
          : lastUpdated as DateTime?,
      coordinates: coordinates ?? this.coordinates,
      customName: customName ?? this.customName,
      customImageAsset: customImageAsset == _sentinel
          ? this.customImageAsset
          : customImageAsset as String?,
    );
  }

  /// Return a copy with flow-related fields cleared (for unit changes).
  FavoriteSessionData clearFlowData() {
    return FavoriteSessionData(
      riverName: riverName,
      coordinates: coordinates,
      customName: customName,
      customImageAsset: customImageAsset,
    );
  }

  static const empty = FavoriteSessionData();
}

const _sentinel = Object();
