// lib/models/2_usecases/features/auth/delete_account_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';

class DeleteAccountUseCase {
  final IAuthRepository _repository;
  const DeleteAccountUseCase(this._repository);

  Future<ServiceResult<void>> call({required String password}) =>
      _repository.deleteAccount(password: password);
}
