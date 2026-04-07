// lib/models/1_domain/shared/favorite_river.dart

/// Pure domain entity for a user's favorite river.
///
/// No framework imports (GetIt, Firebase, etc.) — serialization is handled
/// by [FavoriteRiverDto]. Unit conversion is performed by callers that have
/// access to IFlowUnitPreferenceService.
class FavoriteRiver {
  final String reachId;
  final String? customName;
  final String? riverName;
  final String? customImageAsset;
  final int displayOrder;
  final double? lastKnownFlow;
  final String? storedFlowUnit;
  final DateTime? lastUpdated;
  final double? latitude;
  final double? longitude;

  const FavoriteRiver({
    required this.reachId,
    this.customName,
    this.riverName,
    this.customImageAsset,
    required this.displayOrder,
    this.lastKnownFlow,
    this.storedFlowUnit,
    this.lastUpdated,
    this.latitude,
    this.longitude,
  });

  FavoriteRiver copyWith({
    String? reachId,
    String? customName,
    String? riverName,
    String? customImageAsset,
    int? displayOrder,
    double? lastKnownFlow,
    String? storedFlowUnit,
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
      storedFlowUnit: storedFlowUnit ?? this.storedFlowUnit,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
    );
  }

  bool get hasCoordinates => latitude != null && longitude != null;

  /// Display name priority: custom name > NOAA river name > station ID.
  String get displayName {
    if (customName != null && customName!.isNotEmpty) return customName!;
    if (riverName != null && riverName!.isNotEmpty) return riverName!;
    return 'Station $reachId';
  }

  bool get isFlowDataStale {
    if (lastUpdated == null) return true;
    return DateTime.now().difference(lastUpdated!).inHours > 2;
  }

  /// Format flow for display using the provided conversion function.
  ///
  /// [convertFlow] converts a value from [fromUnit] to [toUnit].
  /// [currentUnit] is the user's preferred display unit (e.g. "CFS").
  String formattedFlow({
    required double Function(double value, String fromUnit, String toUnit)
        convertFlow,
    required String currentUnit,
  }) {
    if (lastKnownFlow == null) return 'No data';

    final actualStoredUnit = storedFlowUnit ?? 'CFS';
    final converted = convertFlow(lastKnownFlow!, actualStoredUnit, currentUnit);
    return '${converted.toStringAsFixed(0)} $currentUnit';
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
