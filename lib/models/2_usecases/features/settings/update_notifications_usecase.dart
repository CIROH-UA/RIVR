// lib/models/2_usecases/features/settings/update_notifications_usecase.dart

import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';

class UpdateNotificationsUseCase {
  final ISettingsRepository _repository;
  const UpdateNotificationsUseCase(this._repository);

  Future<ServiceResult<UserSettings?>> call(String userId, {required bool enable}) =>
      _repository.updateNotifications(userId, enable);
}
