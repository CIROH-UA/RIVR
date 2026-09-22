// lib/models/2_usecases/features/auth/sign_in_anonymously_usecase.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

/// ADR 0014 — the app opens as a guest. Returns the existing session when
/// there is one, so calling it on every launch is safe.
class SignInAnonymouslyUseCase {
  final IAuthRepository _repository;
  const SignInAnonymouslyUseCase(this._repository);

  Future<ServiceResult<User?>> call() => _repository.signInAnonymously();
}
