// lib/core/models/favorite_river.dart

import 'package:rivrflow/core/services/flow_unit_preference_service.dart';

/// Simple model for storing user's favorite rivers
/// Designed for JSON serialization with SharedPreferences
/// FIXED: Added unit tracking to prevent double conversion
class FavoriteRiver {
  final String reachId; // Links to existing ReachData
  final String? customName; // User override for display name
  final String? riverName; // NOAA river name (cached from API)
  final String?
  customImageAsset; // Asset path like 'assets/images/rivers/mountain/river1.webp'
  final int displayOrder; // For user reordering (0 = first)
  final double? lastKnownFlow; // Cached flow value for offline display
  final String?
  storedFlowUnit; // CRITICAL FIX: Track what unit the stored flow is in
  final DateTime? lastUpdated; // When flow was last refreshed

  // Cached coordinates for efficient map marker positioning
  final double? latitude; // Cached reach latitude
  final double? longitude; // Cached reach longitude

  const FavoriteRiver({
    required this.reachId,
    this.customName,
    this.riverName,
    this.customImageAsset,
    required this.displayOrder,
    this.lastKnownFlow,
    this.storedFlowUnit, // FIXED: Add unit tracking parameter
    this.lastUpdated,
    this.latitude,
    this.longitude,
  });

  /// Create from JSON (for SharedPreferences loading)
  factory FavoriteRiver.fromJson(Map<String, dynamic> json) {
    return FavoriteRiver(
      reachId: json['reachId'] as String,
      customName: json['customName'] as String?,
      riverName: json['riverName'] as String?,
      customImageAsset: json['customImageAsset'] as String?,
      displayOrder: json['displayOrder'] as int,
      lastKnownFlow: json['lastKnownFlow'] as double?,
      storedFlowUnit:
          json['storedFlowUnit'] as String?, // FIXED: Load stored unit
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
    );
  }

  /// Convert to JSON (for SharedPreferences storage)
  Map<String, dynamic> toJson() {
    return {
      'reachId': reachId,
      'customName': customName,
      'riverName': riverName,
      'customImageAsset': customImageAsset,
      'displayOrder': displayOrder,
      'lastKnownFlow': lastKnownFlow,
      'storedFlowUnit': storedFlowUnit, // FIXED: Save stored unit
      'lastUpdated': lastUpdated?.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
    };
  }

  /// Create a copy with updated values
  FavoriteRiver copyWith({
    String? reachId,
    String? customName,
    String? riverName,
    String? customImageAsset,
    int? displayOrder,
    double? lastKnownFlow,
    String? storedFlowUnit, // FIXED: Add to copyWith method
    DateTime? lastUpdated,
    double? latitude,
    double? longitude,
  }) {
    return FavoriteRiver(
      reachId: reachId ?? this.reachId,
      customName: customName ?? this.customName,
      riverName: riverName ?? this.riverName,
      customImageAsset: customImageAsset ?? this.customImageAsset,
      displayOrder: displayOrder ?? this.displayOrder,
      lastKnownFlow: lastKnownFlow ?? this.lastKnownFlow,
      storedFlowUnit:
          storedFlowUnit ?? this.storedFlowUnit, // FIXED: Include in copy
      lastUpdated: lastUpdated ?? this.lastUpdated,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
    );
  }

  /// Check if coordinates are cached and available for map markers
  bool get hasCoordinates {
    return latitude != null && longitude != null;
  }

  /// Get display name with enhanced priority logic:
  /// 1. Custom name (if user renamed it)
  /// 2. NOAA river name (from API)
  /// 3. Fallback to station ID
  String get displayName {
    // 1. Custom name (highest priority)
    if (customName != null && customName!.isNotEmpty) {
      return customName!;
    }
    // 2. NOAA river name
    if (riverName != null && riverName!.isNotEmpty) {
      return riverName!;
    }
    // 3. Fallback to station ID
    return 'Station $reachId';
  }

  /// Check if flow data is stale (older than 2 hours)
  bool get isFlowDataStale {
    if (lastUpdated == null) return true;
    return DateTime.now().difference(lastUpdated!).inHours > 2;
  }

  /// Get formatted flow display with proper unit conversion
  /// CRITICAL FIX: Now uses stored unit information to prevent double conversion
  String get formattedFlow {
    if (lastKnownFlow == null) return 'No data';

    final unitService = FlowUnitPreferenceService();
    final currentUnit = unitService.currentFlowUnit;

    // CRITICAL FIX: Use stored unit if available, otherwise assume CFS for backward compatibility
    final actualStoredUnit = storedFlowUnit ?? 'CFS';

    print(
      'FAVORITE_RIVER: Converting flow for $reachId: $lastKnownFlow $actualStoredUnit → $currentUnit',
    );

    // Convert from actual stored unit to user's preferred unit
    final convertedFlow = unitService.convertFlow(
      lastKnownFlow!,
      actualStoredUnit, // FIXED: Use actual stored unit instead of assuming CFS
      currentUnit,
    );

    return '${convertedFlow.toStringAsFixed(0)} $currentUnit';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FavoriteRiver && other.reachId == reachId;
  }

  @override
  int get hashCode => reachId.hashCode;

  @override
  String toString() {
    return 'FavoriteRiver{reachId: $reachId, customName: $customName, riverName: $riverName, displayOrder: $displayOrder, hasCoords: $hasCoordinates, storedUnit: $storedFlowUnit}';
  }
}
