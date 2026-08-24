// test/services/2_coordinators/features/favorites/favorites_repository_impl_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/2_coordinators/features/favorites/favorites_repository_impl.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────

class _StubFavoritesService implements IFavoritesService {
  List<FavoriteRiver>? favoritesToReturn;
  bool successToReturn = true;
  Exception? exceptionToThrow;

  @override
  Future<List<FavoriteRiver>> loadFavorites() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return favoritesToReturn ?? [];
  }

  @override
  Future<bool> addFavorite(String reachId,
      {String? customName,
      double? latitude,
      double? longitude,
      ForecastSource source = ForecastSource.nwm}) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  @override
  Future<bool> removeFavorite(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  @override
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
    double? lastKnownFlow,
    DateTime? lastUpdated,
    double? latitude,
    double? longitude,
  }) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  @override
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  // ── Unused methods ──
  @override
  Future<bool> saveFavorites(List<FavoriteRiver> favorites) async => true;
  @override
  Future<bool> isFavorite(String reachId) async => false;
  @override
  Future<int> getFavoritesCount() async => 0;
  @override
  Future<bool> clearAllFavorites() async => true;
}

class _StubFlowUnitPreferenceService implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  bool get isCFS => true;
  @override
  bool get isCMS => false;
  @override
  void setFlowUnit(String unit) {}
  @override
  String normalizeUnit(String unit) => unit;
  @override
  double convertFlow(double value, String fromUnit, String toUnit) => value;
  @override
  double convertToPreferredUnit(double value, String fromUnit) => value;
  @override
  double convertFromPreferredUnit(double value, String toUnit) => value;
  @override
  String getDisplayUnit() => 'CFS';
  @override
  void resetToDefault() {}
}

// ── Helpers ────────────────────────────────────────────────────────────────

FavoriteRiver _createFavorite({
  String reachId = '12345',
  String riverName = 'Test River',
}) {
  return FavoriteRiver(
    reachId: reachId,
    riverName: riverName,
    displayOrder: 0,
    lastKnownFlow: 150.0,
    storedFlowUnit: 'CFS',
    lastUpdated: DateTime(2026, 4, 6),
    latitude: 35.0,
    longitude: -90.0,
  );
}


// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  late _StubFavoritesService stubFavoritesService;
  late _StubFlowUnitPreferenceService stubUnitService;
  late FavoritesRepositoryImpl repository;

  setUp(() {
    stubFavoritesService = _StubFavoritesService();
    stubUnitService = _StubFlowUnitPreferenceService();
    repository = FavoritesRepositoryImpl(
      favoritesService: stubFavoritesService,
      unitService: stubUnitService,
    );
  });

  group('FavoritesRepositoryImpl — loadFavorites', () {
    test('returns success with favorites list', () async {
      stubFavoritesService.favoritesToReturn = [
        _createFavorite(),
        _createFavorite(reachId: '67890', riverName: 'Other River'),
      ];

      final result = await repository.loadFavorites();
      expect(result.isSuccess, isTrue);
      expect(result.data.length, 2);
      expect(result.data[0].reachId, '12345');
    });

    test('returns success with empty list', () async {
      stubFavoritesService.favoritesToReturn = [];

      final result = await repository.loadFavorites();
      expect(result.isSuccess, isTrue);
      expect(result.data, isEmpty);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Firestore unavailable');

      final result = await repository.loadFavorites();
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('FavoritesRepositoryImpl — addFavorite', () {
    test('returns success with true when added', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.addFavorite('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns success with false when add failed', () async {
      stubFavoritesService.successToReturn = false;

      final result = await repository.addFavorite('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data, isFalse);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Permission denied');

      final result = await repository.addFavorite('12345');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('FavoritesRepositoryImpl — removeFavorite', () {
    test('returns success with true when removed', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.removeFavorite('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Network error');

      final result = await repository.removeFavorite('12345');
      expect(result.isFailure, isTrue);
    });
  });

  group('FavoritesRepositoryImpl — updateFavorite', () {
    test('returns success when updated', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.updateFavorite(
        '12345',
        customName: 'My River',
      );
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Update failed');

      final result = await repository.updateFavorite('12345');
      expect(result.isFailure, isTrue);
    });
  });

  group('FavoritesRepositoryImpl — reorderFavorites', () {

  });

  group('FavoritesRepositoryImpl — ServiceResult properties', () {
    test('failure result has ServiceException with context', () async {
      stubFavoritesService.exceptionToThrow = Exception('Some error');

      final result = await repository.loadFavorites();
      expect(result.isFailure, isTrue);
      expect(result.exception, isNotNull);
      expect(result.exception!.technicalDetail, isNotNull);
    });

    test('success result has no exception', () async {
      stubFavoritesService.favoritesToReturn = [_createFavorite()];

      final result = await repository.loadFavorites();
      expect(result.isSuccess, isTrue);
      expect(result.exception, isNull);
    });
  });
}
