// lib/models/1_domain/shared/favorite_river.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';

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

  /// Which model this reach's forecast comes from (NWM vs GEOGLOWS). Drives
  /// opening the correct forecast page and refreshing from the right API.
  final ForecastSource source;

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
    this.source = ForecastSource.nwm,
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
    ForecastSource? source,
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
      source: source ?? this.source,
    );
  }

  bool get hasCoordinates => latitude != null && longitude != null;

  /// Display name priority: custom name > river name > id. GEOGLOWS reaches are
  /// unnamed, so their fallback reads `Global Reach {id}` rather than "Station".
  String get displayName {
    if (customName != null && customName!.isNotEmpty) return customName!;
    if (riverName != null && riverName!.isNotEmpty) return riverName!;
    return source.isGeoglows ? 'Global Reach $reachId' : 'Station $reachId';
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
