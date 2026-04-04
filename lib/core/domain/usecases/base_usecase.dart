// lib/core/domain/usecases/base_usecase.dart

/// Marker type for use cases that require no input parameters.
class NoParams {
  const NoParams();
}

/// Base contract for all use cases.
///
/// [Out] — the return type of the use case.
/// [Params] — the input type (use [NoParams] when no input is needed).
///
/// Each concrete use case is a callable class:
/// ```dart
/// final result = await myUseCase(params);
/// ```
abstract class UseCase<Out, Params> {
  Future<Out> call(Params params);
}
