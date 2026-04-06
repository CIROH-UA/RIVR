// lib/features/settings/domain/usecases/update_notifications_usecase.dart

import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_settings_repository.dart';

class UpdateNotificationsUseCase {
  final ISettingsRepository _repository;
  const UpdateNotificationsUseCase(this._repository);

  Future<ServiceResult<UserSettings?>> call(String userId, {required bool enable}) =>
      _repository.updateNotifications(userId, enable);
}
