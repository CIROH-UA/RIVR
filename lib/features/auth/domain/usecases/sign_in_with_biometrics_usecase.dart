// lib/features/auth/domain/usecases/sign_in_with_biometrics_usecase.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_auth_repository.dart';

class SignInWithBiometricsUseCase {
  final IAuthRepository _repository;
  const SignInWithBiometricsUseCase(this._repository);

  Future<ServiceResult<User?>> call() => _repository.signInWithBiometrics();
}
