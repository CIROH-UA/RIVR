// lib/models/2_usecases/features/auth/sign_in_usecase.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class SignInUseCase {
  final IAuthRepository _repository;
  const SignInUseCase(this._repository);

  Future<ServiceResult<User?>> call({
    required String email,
    required String password,
  }) =>
      _repository.signIn(email: email, password: password);
}
