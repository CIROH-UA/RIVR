// lib/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart

import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';

class SyncSettingsAfterLoginUseCase {
  final ISettingsRepository _repository;
  const SyncSettingsAfterLoginUseCase(this._repository);

  Future<ServiceResult<UserSettings?>> call(String userId) =>
      _repository.syncAfterLogin(userId);
}
