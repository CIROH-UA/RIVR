// lib/features/settings/domain/repositories/i_settings_repository.dart

import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/service_result.dart';

/// Repository contract for user settings operations.
///
/// All methods return [ServiceResult] so that use cases and UI can handle
/// success/failure without catching exceptions.
abstract class ISettingsRepository {
  Future<ServiceResult<UserSettings?>> getUserSettings(String userId);
  Future<ServiceResult<UserSettings?>> updateFlowUnit(String userId, FlowUnit flowUnit);
  Future<ServiceResult<UserSettings?>> updateNotifications(String userId, bool enableNotifications);
  Future<ServiceResult<UserSettings?>> updateNotificationFrequency(String userId, int frequency);
  Future<ServiceResult<UserSettings?>> syncAfterLogin(String userId);
}
