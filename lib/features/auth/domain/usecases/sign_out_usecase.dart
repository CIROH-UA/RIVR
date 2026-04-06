// lib/features/auth/domain/usecases/sign_out_usecase.dart

import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_auth_repository.dart';

class SignOutUseCase {
  final IAuthRepository _repository;
  const SignOutUseCase(this._repository);

  Future<ServiceResult<void>> call() => _repository.signOut();
}
