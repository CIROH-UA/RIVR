// lib/models/2_usecases/shared/base_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Marker type for use cases that require no input parameters.
class NoParams {
  const NoParams();
}

/// Base contract for all use cases.
///
/// [Out] — the **success** type wrapped in [ServiceResult].
/// [Params] — the input type (use [NoParams] when no input is needed).
///
/// Each concrete use case is a callable class:
/// ```dart
/// final result = await myUseCase(params);
/// if (result.isSuccess) {
///   // use result.data
/// }
/// ```
///
/// Note: existing use cases define their own `call()` signatures and do not
/// extend this class yet. This base documents the target pattern — concrete
/// use cases will adopt it incrementally during Phases 2-7.
abstract class UseCase<Out, Params> {
  Future<ServiceResult<Out>> call(Params params);
}
