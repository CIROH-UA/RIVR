// lib/services/3_datasources/shared/dtos/favorite_river_dto.dart

import 'package:rivr/models/1_domain/shared/favorite_river.dart';

/// Data Transfer Object for FavoriteRiver.
///
/// Handles JSON serialization/deserialization for SharedPreferences persistence.
/// The pure [FavoriteRiver] entity contains only domain logic.
class FavoriteRiverDto {
  final String reachId;
  final String? customName;
  final String? riverName;
  final String? customImageAsset;
  final int displayOrder;
  final double? lastKnownFlow;
  final String? storedFlowUnit;
  final String? lastUpdated;
  final double? latitude;
  final double? longitude;

  const FavoriteRiverDto({
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

  factory FavoriteRiverDto.fromJson(Map<String, dynamic> json) {
    return FavoriteRiverDto(
      reachId: json['reachId'] as String,
      customName: json['customName'] as String?,
      riverName: json['riverName'] as String?,
      customImageAsset: json['customImageAsset'] as String?,
      displayOrder: json['displayOrder'] as int,
      lastKnownFlow: json['lastKnownFlow'] as double?,
      storedFlowUnit: json['storedFlowUnit'] as String?,
      lastUpdated: json['lastUpdated'] as String?,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'reachId': reachId,
      'customName': customName,
      'riverName': riverName,
      'customImageAsset': customImageAsset,
      'displayOrder': displayOrder,
      'lastKnownFlow': lastKnownFlow,
      'storedFlowUnit': storedFlowUnit,
      'lastUpdated': lastUpdated,
      'latitude': latitude,
      'longitude': longitude,
    };
  }

  FavoriteRiver toEntity() {
    return FavoriteRiver(
      reachId: reachId,
      customName: customName,
      riverName: riverName,
      customImageAsset: customImageAsset,
      displayOrder: displayOrder,
      lastKnownFlow: lastKnownFlow,
      storedFlowUnit: storedFlowUnit,
      lastUpdated:
          lastUpdated != null ? DateTime.parse(lastUpdated!) : null,
      latitude: latitude,
      longitude: longitude,
    );
  }

  static FavoriteRiverDto fromEntity(FavoriteRiver entity) {
    return FavoriteRiverDto(
      reachId: entity.reachId,
      customName: entity.customName,
      riverName: entity.riverName,
      customImageAsset: entity.customImageAsset,
      displayOrder: entity.displayOrder,
      lastKnownFlow: entity.lastKnownFlow,
      storedFlowUnit: entity.storedFlowUnit,
      lastUpdated: entity.lastUpdated?.toIso8601String(),
      latitude: entity.latitude,
      longitude: entity.longitude,
    );
  }
}
