// lib/features/settings/domain/usecases/update_notification_frequency_usecase.dart

import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_settings_repository.dart';

class UpdateNotificationFrequencyUseCase {
  final ISettingsRepository _repository;
  const UpdateNotificationFrequencyUseCase(this._repository);

  Future<ServiceResult<UserSettings?>> call(String userId, int frequency) =>
      _repository.updateNotificationFrequency(userId, frequency);
}
