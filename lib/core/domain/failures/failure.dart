// lib/core/domain/failures/failure.dart

/// Base failure type for the domain layer.
/// Concrete subtypes describe the category of error without exposing
/// implementation details (HTTP status codes, Firestore error codes, etc.)
/// to the presentation layer.
abstract class Failure {
  final String message;
  const Failure(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// A network-level error (no connectivity, timeout, server error).
class NetworkFailure extends Failure {
  const NetworkFailure([super.message = 'A network error occurred.']);
}

/// A cache read/write error.
class CacheFailure extends Failure {
  const CacheFailure([super.message = 'A cache error occurred.']);
}

/// An authentication error (not signed in, token expired, permission denied).
class AuthFailure extends Failure {
  const AuthFailure([super.message = 'An authentication error occurred.']);
}
