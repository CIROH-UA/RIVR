// lib/services/1_contracts/features/settings/i_settings_repository.dart

import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

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
