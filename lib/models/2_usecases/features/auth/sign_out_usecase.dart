// lib/models/2_usecases/features/auth/sign_out_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class SignOutUseCase {
  final IAuthRepository _repository;
  const SignOutUseCase(this._repository);

  Future<ServiceResult<void>> call() => _repository.signOut();
}
