// lib/models/2_usecases/features/auth/sign_up_usecase.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class SignUpUseCase {
  final IAuthRepository _repository;
  const SignUpUseCase(this._repository);

  Future<ServiceResult<User?>> call({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) =>
      _repository.signUp(
        email: email,
        password: password,
        firstName: firstName,
        lastName: lastName,
      );
}
