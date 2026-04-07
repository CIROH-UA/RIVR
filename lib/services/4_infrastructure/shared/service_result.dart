// lib/services/4_infrastructure/shared/service_result.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/4_infrastructure/shared/error_service.dart';

/// Categorizes errors by domain so the UI can react appropriately
/// (e.g., show a login prompt for [authentication], a retry button for [network]).
enum ServiceErrorType {
  network,
  authentication,
  validation,
  notFound,
  cache,
  configuration,
  unknown,
}

/// Typed error with a user-friendly message and optional technical detail for logging.
class ServiceException implements Exception {
  final ServiceErrorType type;

  /// User-friendly message suitable for display in the UI.
  final String message;

  /// Technical detail for logging / debugging. Never shown to users.
  final String? technicalDetail;

  const ServiceException({
    required this.type,
    required this.message,
    this.technicalDetail,
  });

  // ── Named constructors ──────────────────────────────────────────────────

  const ServiceException.network(this.message, {String? detail})
      : type = ServiceErrorType.network,
        technicalDetail = detail;

  const ServiceException.auth(this.message, {String? detail})
      : type = ServiceErrorType.authentication,
        technicalDetail = detail;

  const ServiceException.validation(this.message, {String? detail})
      : type = ServiceErrorType.validation,
        technicalDetail = detail;

  const ServiceException.notFound(this.message, {String? detail})
      : type = ServiceErrorType.notFound,
        technicalDetail = detail;

  const ServiceException.cache(this.message, {String? detail})
      : type = ServiceErrorType.cache,
        technicalDetail = detail;

  const ServiceException.configuration(this.message, {String? detail})
      : type = ServiceErrorType.configuration,
        technicalDetail = detail;

  const ServiceException.unknown(this.message, {String? detail})
      : type = ServiceErrorType.unknown,
        technicalDetail = detail;

  // ── Factory constructors from existing error types ──────────────────────

  /// Create from a [FirebaseAuthException], delegating message mapping
  /// to [ErrorService.mapFirebaseAuthError].
  factory ServiceException.fromFirebaseAuth(FirebaseAuthException e) {
    final isNetwork = e.code == 'network-request-failed' || e.code == 'timeout';
    return ServiceException(
      type: isNetwork ? ServiceErrorType.network : ServiceErrorType.authentication,
      message: ErrorService.mapFirebaseAuthError(e),
      technicalDetail: 'FirebaseAuth ${e.code}: ${e.message}',
    );
  }

  /// Create from a [FirebaseException] (Firestore, Storage, etc.), delegating
  /// message mapping to [ErrorService.mapFirestoreError].
  factory ServiceException.fromFirebase(FirebaseException e) {
    ServiceErrorType type;
    switch (e.code) {
      case 'permission-denied':
        type = ServiceErrorType.authentication;
      case 'not-found':
        type = ServiceErrorType.notFound;
      case 'unavailable':
      case 'deadline-exceeded':
        type = ServiceErrorType.network;
      case 'invalid-argument':
      case 'out-of-range':
        type = ServiceErrorType.validation;
      default:
        type = ServiceErrorType.unknown;
    }
    return ServiceException(
      type: type,
      message: ErrorService.mapFirestoreError(e),
      technicalDetail: 'Firebase ${e.code}: ${e.message}',
    );
  }

  /// Create from a generic error, delegating to [ErrorService.handleError].
  factory ServiceException.fromError(dynamic error, {String? context}) {
    if (error is FirebaseAuthException) {
      return ServiceException.fromFirebaseAuth(error);
    }
    if (error is FirebaseException) {
      return ServiceException.fromFirebase(error);
    }

    final isNetwork = ErrorService.isNetworkError(error);
    return ServiceException(
      type: isNetwork ? ServiceErrorType.network : ServiceErrorType.unknown,
      message: ErrorService.handleError(error, context: context),
      technicalDetail: error.toString(),
    );
  }

  @override
  String toString() => 'ServiceException($type): $message';
}

/// A result wrapper that makes success and failure explicit at every layer
/// boundary. Replaces thrown exceptions with a type-safe union of data or error.
///
/// ```dart
/// final result = await repository.loadOverview(reachId);
/// if (result.isSuccess) {
///   // use result.data
/// } else {
///   // show result.errorMessage
/// }
/// ```
class ServiceResult<T> {
  final bool isSuccess;
  final T? _data;
  final ServiceException? exception;

  const ServiceResult._({
    required this.isSuccess,
    T? data,
    this.exception,
  }) : _data = data;

  /// Create a successful result wrapping [data].
  factory ServiceResult.success(T data) =>
      ServiceResult._(isSuccess: true, data: data);

  /// Create a failed result wrapping [exception].
  factory ServiceResult.failure(ServiceException exception) =>
      ServiceResult._(isSuccess: false, exception: exception);

  bool get isFailure => !isSuccess;

  /// The success data. Throws [StateError] if accessed on a failure result.
  T get data {
    if (isFailure) {
      throw StateError(
        'Cannot access data on a failed ServiceResult. '
        'Check isSuccess before accessing data. Error: ${exception?.message}',
      );
    }
    return _data as T;
  }

  /// User-friendly error message, or null on success.
  String? get errorMessage => exception?.message;

  /// The error type, or null on success.
  ServiceErrorType? get errorType => exception?.type;

  /// Transform the success data while preserving failures.
  ///
  /// ```dart
  /// final names = result.map((users) => users.map((u) => u.name).toList());
  /// ```
  ServiceResult<R> map<R>(R Function(T data) mapper) {
    if (isSuccess) {
      return ServiceResult.success(mapper(_data as T));
    }
    return ServiceResult.failure(exception!);
  }

  /// Chain an async operation that itself returns a [ServiceResult].
  /// Short-circuits on failure — the [next] callback is only called on success.
  ///
  /// ```dart
  /// final result = await loadUser(id)
  ///     .then((user) => loadProfile(user.profileId));
  /// ```
  Future<ServiceResult<R>> then<R>(
    Future<ServiceResult<R>> Function(T data) next,
  ) async {
    if (isFailure) {
      return ServiceResult.failure(exception!);
    }
    return next(_data as T);
  }
}
