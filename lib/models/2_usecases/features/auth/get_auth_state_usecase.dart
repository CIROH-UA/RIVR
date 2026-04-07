// lib/models/2_usecases/features/auth/get_auth_state_usecase.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class GetAuthStateUseCase {
  final IAuthRepository _repository;
  const GetAuthStateUseCase(this._repository);

  Stream<User?> call() => _repository.authStateChanges;
}
