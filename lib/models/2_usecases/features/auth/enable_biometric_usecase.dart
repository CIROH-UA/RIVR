// lib/models/2_usecases/features/auth/enable_biometric_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class EnableBiometricUseCase {
  final IAuthRepository _repository;
  const EnableBiometricUseCase(this._repository);

  Future<ServiceResult<void>> call() => _repository.enableBiometric();
}
