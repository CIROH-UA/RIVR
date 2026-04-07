// lib/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class SignInWithBiometricsUseCase {
  final IAuthRepository _repository;
  const SignInWithBiometricsUseCase(this._repository);

  Future<ServiceResult<User?>> call() => _repository.signInWithBiometrics();
}
