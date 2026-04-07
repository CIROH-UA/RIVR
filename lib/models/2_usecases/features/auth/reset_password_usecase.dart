// lib/models/2_usecases/features/auth/reset_password_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class ResetPasswordUseCase {
  final IAuthRepository _repository;
  const ResetPasswordUseCase(this._repository);

  Future<ServiceResult<void>> call({required String email}) =>
      _repository.resetPassword(email: email);
}
