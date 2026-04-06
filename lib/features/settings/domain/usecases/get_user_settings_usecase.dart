// lib/features/settings/domain/usecases/get_user_settings_usecase.dart

import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_settings_repository.dart';

class GetUserSettingsUseCase {
  final ISettingsRepository _repository;
  const GetUserSettingsUseCase(this._repository);

  Future<ServiceResult<UserSettings?>> call(String userId) =>
      _repository.getUserSettings(userId);
}
