// lib/services/2_coordinators/features/settings/settings_repository_impl.dart

import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';

/// Coordinator that wraps [IUserSettingsService] operations with
/// [ServiceResult] error handling.
///
/// Catches exceptions thrown by the underlying service and maps them
/// to [ServiceException] failures so use cases return structured results
/// instead of throwing.
class SettingsRepositoryImpl implements ISettingsRepository {
  final IUserSettingsService _settingsService;

  const SettingsRepositoryImpl({required IUserSettingsService settingsService})
      : _settingsService = settingsService;

  @override
  Future<ServiceResult<UserSettings?>> getUserSettings(String userId) async {
    try {
      final settings = await _settingsService.getUserSettings(userId);
      return ServiceResult.success(settings);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'getUserSettings'),
      );
    }
  }

  @override
  Future<ServiceResult<UserSettings?>> updateFlowUnit(
    String userId,
    FlowUnit flowUnit,
  ) async {
    try {
      final settings = await _settingsService.updateFlowUnit(userId, flowUnit);
      return ServiceResult.success(settings);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'updateFlowUnit'),
      );
    }
  }

  @override
  Future<ServiceResult<UserSettings?>> updateNotifications(
    String userId,
    bool enableNotifications,
  ) async {
    try {
      final settings = await _settingsService.updateNotifications(
        userId,
        enableNotifications,
      );
      return ServiceResult.success(settings);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'updateNotifications'),
      );
    }
  }

  @override
  Future<ServiceResult<UserSettings?>> updateNotificationFrequency(
    String userId,
    int frequency,
  ) async {
    try {
      final settings = await _settingsService.updateNotificationFrequency(
        userId,
        frequency,
      );
      return ServiceResult.success(settings);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'updateNotificationFrequency'),
      );
    }
  }

  @override
  Future<ServiceResult<UserSettings?>> syncAfterLogin(String userId) async {
    try {
      final settings = await _settingsService.syncAfterLogin(userId);
      return ServiceResult.success(settings);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'syncAfterLogin'),
      );
    }
  }
}
