// test/features/settings/data/repositories/settings_repository_impl_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';
import 'package:rivr/features/settings/data/repositories/settings_repository_impl.dart';

/// Stub that returns canned responses or throws on demand.
class _StubSettingsService implements IUserSettingsService {
  UserSettings? settingsToReturn;
  Exception? exceptionToThrow;

  @override
  Future<UserSettings?> getUserSettings(String userId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return settingsToReturn;
  }

  @override
  Future<UserSettings?> updateFlowUnit(String userId, FlowUnit flowUnit) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return settingsToReturn?.copyWith(preferredFlowUnit: flowUnit);
  }

  @override
  Future<UserSettings?> updateNotifications(
    String userId,
    bool enableNotifications,
  ) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return settingsToReturn?.copyWith(
      enableNotifications: enableNotifications,
    );
  }

  @override
  Future<UserSettings?> updateNotificationFrequency(
    String userId,
    int frequency,
  ) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return settingsToReturn?.copyWith(notificationFrequency: frequency);
  }

  @override
  Future<UserSettings?> syncAfterLogin(String userId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return settingsToReturn;
  }

  // ── Unused methods (required by interface) ──────────────────────────────

  @override
  Future<void> saveUserSettings(UserSettings settings) async {}
  @override
  Future<void> updateUserSettings(
    String userId,
    Map<String, dynamic> updates,
  ) async {}
  @override
  Future<UserSettings?> addCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async =>
      null;
  @override
  Future<UserSettings?> removeCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async =>
      null;
  @override
  Future<List<String>> getUserCustomBackgrounds(String userId) async => [];
  @override
  Future<UserSettings?> validateCustomBackgrounds(String userId) async => null;
  @override
  Future<UserSettings?> clearAllCustomBackgrounds(String userId) async => null;
  @override
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async =>
      throw UnimplementedError();
  @override
  Future<UserSettings?> addFavoriteReach(String userId, String reachId) async =>
      null;
  @override
  Future<UserSettings?> removeFavoriteReach(
    String userId,
    String reachId,
  ) async =>
      null;
  @override
  void clearCache() {}
  @override
  Future<bool> userHasSettings(String userId) async => false;
  @override
  Future<void> syncFlowUnitPreference(String userId) async {}
}

UserSettings _createSettings({
  String userId = 'user1',
  FlowUnit flowUnit = FlowUnit.cfs,
  bool enableNotifications = false,
  int notificationFrequency = 1,
}) {
  final now = DateTime(2026, 4, 6);
  return UserSettings(
    userId: userId,
    email: 'test@example.com',
    firstName: 'Test',
    lastName: 'User',
    preferredFlowUnit: flowUnit,
    preferredTimeFormat: TimeFormat.twelveHour,
    enableNotifications: enableNotifications,
    notificationFrequency: notificationFrequency,
    favoriteReachIds: [],
    lastLoginDate: now,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late _StubSettingsService stubService;
  late SettingsRepositoryImpl repository;

  setUp(() {
    stubService = _StubSettingsService();
    repository = SettingsRepositoryImpl(settingsService: stubService);
  });

  group('SettingsRepositoryImpl — getUserSettings', () {
    test('returns success with settings', () async {
      stubService.settingsToReturn = _createSettings();

      final result = await repository.getUserSettings('user1');
      expect(result.isSuccess, isTrue);
      expect(result.data, isNotNull);
      expect(result.data!.userId, 'user1');
    });

    test('returns success with null when no settings exist', () async {
      stubService.settingsToReturn = null;

      final result = await repository.getUserSettings('user1');
      expect(result.isSuccess, isTrue);
      expect(result.data, isNull);
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Firestore unavailable');

      final result = await repository.getUserSettings('user1');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('SettingsRepositoryImpl — updateFlowUnit', () {
    test('returns success with updated settings', () async {
      stubService.settingsToReturn = _createSettings(flowUnit: FlowUnit.cfs);

      final result = await repository.updateFlowUnit('user1', FlowUnit.cms);
      expect(result.isSuccess, isTrue);
      expect(result.data!.preferredFlowUnit, FlowUnit.cms);
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Network error');

      final result = await repository.updateFlowUnit('user1', FlowUnit.cms);
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('SettingsRepositoryImpl — updateNotifications', () {
    test('returns success with updated settings', () async {
      stubService.settingsToReturn = _createSettings();

      final result = await repository.updateNotifications('user1', true);
      expect(result.isSuccess, isTrue);
      expect(result.data!.enableNotifications, isTrue);
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Permission denied');

      final result = await repository.updateNotifications('user1', true);
      expect(result.isFailure, isTrue);
    });
  });

  group('SettingsRepositoryImpl — updateNotificationFrequency', () {
    test('returns success with updated frequency', () async {
      stubService.settingsToReturn = _createSettings();

      final result = await repository.updateNotificationFrequency('user1', 3);
      expect(result.isSuccess, isTrue);
      expect(result.data!.notificationFrequency, 3);
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Timeout');

      final result = await repository.updateNotificationFrequency('user1', 3);
      expect(result.isFailure, isTrue);
    });
  });

  group('SettingsRepositoryImpl — syncAfterLogin', () {
    test('returns success with synced settings', () async {
      stubService.settingsToReturn = _createSettings();

      final result = await repository.syncAfterLogin('user1');
      expect(result.isSuccess, isTrue);
      expect(result.data, isNotNull);
    });

    test('returns success with null when no settings', () async {
      stubService.settingsToReturn = null;

      final result = await repository.syncAfterLogin('user1');
      expect(result.isSuccess, isTrue);
      expect(result.data, isNull);
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Sync failed');

      final result = await repository.syncAfterLogin('user1');
      expect(result.isFailure, isTrue);
    });
  });

  group('SettingsRepositoryImpl — ServiceResult properties', () {
    test('failure result has ServiceException with context', () async {
      stubService.exceptionToThrow = Exception('Some error');

      final result = await repository.getUserSettings('user1');
      expect(result.isFailure, isTrue);
      expect(result.exception, isNotNull);
      expect(result.exception!.technicalDetail, isNotNull);
    });

    test('success result has no exception', () async {
      stubService.settingsToReturn = _createSettings();

      final result = await repository.getUserSettings('user1');
      expect(result.isSuccess, isTrue);
      expect(result.exception, isNull);
    });
  });
}
