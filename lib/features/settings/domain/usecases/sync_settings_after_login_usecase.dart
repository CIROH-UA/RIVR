// lib/features/settings/domain/usecases/sync_settings_after_login_usecase.dart

import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_settings_repository.dart';

class SyncSettingsAfterLoginUseCase {
  final ISettingsRepository _repository;
  const SyncSettingsAfterLoginUseCase(this._repository);

  Future<ServiceResult<UserSettings?>> call(String userId) =>
      _repository.syncAfterLogin(userId);
}
