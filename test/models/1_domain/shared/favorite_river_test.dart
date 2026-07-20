import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/shared/dtos/favorite_river_dto.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';

void main() {
  group('FavoriteRiver', () {
    FavoriteRiver createFavorite({
      String reachId = '23021904',
      String? customName,
      String? riverName = 'Deep Creek',
      String? customImageAsset,
      int displayOrder = 0,
      double? lastKnownFlow,
      String? storedFlowUnit,
      DateTime? lastUpdated,
      double? latitude = 47.6588,
      double? longitude = -117.4260,
    }) {
      return FavoriteRiver(
        reachId: reachId,
        customName: customName,
        riverName: riverName,
        customImageAsset: customImageAsset,
        displayOrder: displayOrder,
        lastKnownFlow: lastKnownFlow,
        storedFlowUnit: storedFlowUnit,
        lastUpdated: lastUpdated,
        latitude: latitude,
        longitude: longitude,
      );
    }

    group('constructor', () {
      test('creates instance with required fields', () {
        final fav = createFavorite();
        expect(fav.reachId, '23021904');
        expect(fav.displayOrder, 0);
        expect(fav.riverName, 'Deep Creek');
      });

      test('optional fields default to null', () {
        const fav = FavoriteRiver(reachId: '123', displayOrder: 0);
        expect(fav.customName, isNull);
        expect(fav.riverName, isNull);
        expect(fav.lastKnownFlow, isNull);
        expect(fav.storedFlowUnit, isNull);
        expect(fav.lastUpdated, isNull);
        expect(fav.latitude, isNull);
        expect(fav.longitude, isNull);
      });
    });

    group('toJson / fromJson roundtrip', () {
      test('serializes and deserializes all fields', () {
        final original = createFavorite(
          customName: 'My Creek',
          customImageAsset: 'assets/images/rivers/mountain/river1.webp',
          lastKnownFlow: 250.5,
          storedFlowUnit: 'CFS',
          lastUpdated: DateTime(2025, 6, 15, 12, 0),
        );

        final json = FavoriteRiverDto.fromEntity(original).toJson();
        final restored = FavoriteRiverDto.fromJson(json).toEntity();

        expect(restored.reachId, original.reachId);
        expect(restored.customName, original.customName);
        expect(restored.riverName, original.riverName);
        expect(restored.customImageAsset, original.customImageAsset);
        expect(restored.displayOrder, original.displayOrder);
        expect(restored.lastKnownFlow, original.lastKnownFlow);
        expect(restored.storedFlowUnit, original.storedFlowUnit);
        expect(restored.lastUpdated, original.lastUpdated);
        expect(restored.latitude, original.latitude);
        expect(restored.longitude, original.longitude);
      });

      test('handles null optional fields', () {
        const original = FavoriteRiver(reachId: '123', displayOrder: 1);
        final json = FavoriteRiverDto.fromEntity(original).toJson();
        final restored = FavoriteRiverDto.fromJson(json).toEntity();

        expect(restored.customName, isNull);
        expect(restored.lastKnownFlow, isNull);
        expect(restored.storedFlowUnit, isNull);
        expect(restored.lastUpdated, isNull);
        expect(restored.latitude, isNull);
        expect(restored.longitude, isNull);
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final original = createFavorite();
        final copy = original.copyWith(
          customName: 'Renamed',
          displayOrder: 5,
        );

        expect(copy.customName, 'Renamed');
        expect(copy.displayOrder, 5);
        expect(copy.reachId, original.reachId);
        expect(copy.riverName, original.riverName);
      });

      test('preserves all fields when no changes', () {
        final original = createFavorite(
          customName: 'Test',
          lastKnownFlow: 100.0,
          storedFlowUnit: 'CMS',
        );
        final copy = original.copyWith();

        expect(copy.customName, original.customName);
        expect(copy.lastKnownFlow, original.lastKnownFlow);
        expect(copy.storedFlowUnit, original.storedFlowUnit);
      });
    });

    group('displayName', () {
      test('returns customName when set', () {
        final fav = createFavorite(customName: 'My Creek', riverName: 'Deep Creek');
        expect(fav.displayName, 'My Creek');
      });

      test('returns riverName when no customName', () {
        final fav = createFavorite(customName: null, riverName: 'Deep Creek');
        expect(fav.displayName, 'Deep Creek');
      });

      test('returns riverName when customName is empty', () {
        final fav = createFavorite(customName: '', riverName: 'Deep Creek');
        expect(fav.displayName, 'Deep Creek');
      });

      test('falls back to station ID when no names', () {
        final fav = createFavorite(
          reachId: '99999',
          customName: null,
          riverName: null,
        );
        expect(fav.displayName, 'Station 99999');
      });

      test('falls back to station ID when both names are empty', () {
        final fav = createFavorite(customName: '', riverName: '');
        expect(fav.displayName, 'Station 23021904');
      });

      test('unnamed GEOGLOWS reach falls back to "Global Reach <id>"', () {
        const fav = FavoriteRiver(
          reachId: '670068119',
          displayOrder: 0,
          source: ForecastSource.geoglows,
        );
        expect(fav.displayName, 'Global Reach 670068119');
      });
    });

    group('hasCoordinates', () {
      test('true when both lat and lng are set', () {
        final fav = createFavorite(latitude: 47.0, longitude: -117.0);
        expect(fav.hasCoordinates, true);
      });

      test('false when latitude is null', () {
        final fav = createFavorite(latitude: null, longitude: -117.0);
        expect(fav.hasCoordinates, false);
      });

      test('false when longitude is null', () {
        final fav = createFavorite(latitude: 47.0, longitude: null);
        expect(fav.hasCoordinates, false);
      });

      test('false when both are null', () {
        final fav = createFavorite(latitude: null, longitude: null);
        expect(fav.hasCoordinates, false);
      });
    });

    group('isFlowDataStale', () {
      test('true when lastUpdated is null', () {
        final fav = createFavorite(lastUpdated: null);
        expect(fav.isFlowDataStale, true);
      });

      test('true when lastUpdated is older than 2 hours', () {
        final fav = createFavorite(
          lastUpdated: DateTime.now().subtract(const Duration(hours: 3)),
        );
        expect(fav.isFlowDataStale, true);
      });

      test('false when lastUpdated is within 2 hours', () {
        final fav = createFavorite(
          lastUpdated: DateTime.now().subtract(const Duration(hours: 1)),
        );
        expect(fav.isFlowDataStale, false);
      });
    });

    group('equality', () {
      test('two favorites with same reachId are equal', () {
        final a = createFavorite(reachId: '123');
        final b = createFavorite(reachId: '123', riverName: 'Other');
        expect(a, equals(b));
      });

      test('two favorites with different reachId are not equal', () {
        final a = createFavorite(reachId: '123');
        final b = createFavorite(reachId: '456');
        expect(a, isNot(equals(b)));
      });

      test('hashCode is based on reachId', () {
        final a = createFavorite(reachId: '123');
        final b = createFavorite(reachId: '123');
        expect(a.hashCode, equals(b.hashCode));
      });
    });
  });
}
