// lib/models/2_usecases/features/auth/disable_biometric_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class DisableBiometricUseCase {
  final IAuthRepository _repository;
  const DisableBiometricUseCase(this._repository);

  Future<ServiceResult<void>> call() => _repository.disableBiometric();
}
