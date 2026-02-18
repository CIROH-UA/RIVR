// lib/core/services/error_service.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:rivr/core/services/app_logger.dart';

/// Comprehensive error handling service for RIVR
/// Maps Firebase errors to user-friendly messages and provides logging utilities
class ErrorService {

  // MARK: - Firebase Auth Error Mapping

  /// Maps Firebase Auth exceptions to user-friendly error messages
  static String mapFirebaseAuthError(FirebaseAuthException exception) {
    _logError('FirebaseAuth', exception.code, exception.message);

    switch (exception.code) {
      // Email/Password errors
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled. Please contact support.';
      case 'user-not-found':
        return 'No account found with this email address.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'email-already-in-use':
        return 'An account already exists with this email address.';
      case 'weak-password':
        return 'Password must be at least 6 characters long.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled. Please contact support.';

      // Account management errors
      case 'requires-recent-login':
        return 'For security, please sign out and sign back in to continue.';
      case 'account-exists-with-different-credential':
        return 'An account with this email exists with different sign-in credentials.';
      case 'invalid-credential':
        return 'Invalid sign-in credentials. Please try again.';
      case 'credential-already-in-use':
        return 'These credentials are already linked to another account.';

      // Rate limiting and security
      case 'too-many-requests':
        return 'Too many failed attempts. Please wait a few minutes and try again.';
      case 'invalid-verification-code':
        return 'Invalid verification code. Please check and try again.';
      case 'invalid-verification-id':
        return 'Verification failed. Please request a new code.';

      // Network and connectivity
      case 'network-request-failed':
        return 'Network error. Please check your connection and try again.';
      case 'timeout':
        return 'Request timed out. Please check your connection and try again.';

      // Provider-specific errors
      case 'provider-already-linked':
        return 'This sign-in method is already linked to your account.';
      case 'no-such-provider':
        return 'This sign-in method is not linked to your account.';

      // Unknown errors
      default:
        if (exception.message != null && exception.message!.isNotEmpty) {
          return _sanitizeErrorMessage(exception.message!);
        }
        return 'An authentication error occurred. Please try again.';
    }
  }

  /// Get recovery suggestion for specific Firebase Auth error codes
  static String? getAuthRecoverySuggestion(String errorCode) {
    switch (errorCode) {
      case 'wrong-password':
        return 'Try using "Forgot Password" to reset your password.';
      case 'user-not-found':
        return 'Check your email address or create a new account.';
      case 'too-many-requests':
        return 'Wait 5-10 minutes before trying again.';
      case 'network-request-failed':
        return 'Check your internet connection and try again.';
      case 'weak-password':
        return 'Use a mix of letters, numbers, and symbols.';
      case 'requires-recent-login':
        return 'Sign out and sign back in for security verification.';
      default:
        return null;
    }
  }

  // MARK: - Firestore Error Mapping

  /// Maps Firestore exceptions to user-friendly error messages
  static String mapFirestoreError(FirebaseException exception) {
    _logError('Firestore', exception.code, exception.message);

    switch (exception.code) {
      case 'permission-denied':
        return 'Access denied. Please check your permissions.';
      case 'not-found':
        return 'Requested data not found.';
      case 'already-exists':
        return 'This data already exists.';
      case 'resource-exhausted':
        return 'Service temporarily overloaded. Please try again later.';
      case 'failed-precondition':
        return 'Operation failed due to current system state.';
      case 'aborted':
        return 'Operation was aborted. Please try again.';
      case 'out-of-range':
        return 'Invalid data range provided.';
      case 'unimplemented':
        return 'This feature is not yet available.';
      case 'internal':
        return 'Internal server error. Please try again later.';
      case 'unavailable':
        return 'Service temporarily unavailable. Please try again.';
      case 'deadline-exceeded':
        return 'Request timed out. Please try again.';
      case 'cancelled':
        return 'Operation was cancelled.';
      case 'invalid-argument':
        return 'Invalid data provided. Please check your input.';
      default:
        if (exception.message != null && exception.message!.isNotEmpty) {
          return _sanitizeErrorMessage(exception.message!);
        }
        return 'Database error occurred. Please try again.';
    }
  }

  // MARK: - Network Error Mapping

  /// Maps common network and platform errors to user-friendly messages
  static String mapNetworkError(dynamic error) {
    final errorString = error.toString().toLowerCase();

    if (error is PlatformException) {
      _logError('Platform', error.code, error.message);

      switch (error.code) {
        case 'network_error':
          return 'Network connection failed. Please check your internet.';
        case 'timeout':
          return 'Request timed out. Please try again.';
        case 'cancelled':
          return 'Operation was cancelled.';
        default:
          return 'Platform error: ${error.message ?? 'Unknown error'}';
      }
    }

    // Check for common network error patterns
    if (errorString.contains('socketexception') ||
        errorString.contains('network is unreachable')) {
      return 'No internet connection. Please check your network settings.';
    }

    if (errorString.contains('timeout')) {
      return 'Connection timed out. Please try again.';
    }

    if (errorString.contains('host lookup failed') ||
        errorString.contains('failed host lookup')) {
      return 'Unable to connect to server. Please check your internet connection.';
    }

    if (errorString.contains('connection refused')) {
      return 'Unable to connect to server. Please try again later.';
    }

    if (errorString.contains('certificate') || errorString.contains('ssl')) {
      return 'Security certificate error. Please check your device time settings.';
    }

    return 'Network error occurred. Please check your connection and try again.';
  }

  // MARK: - General Error Handling

  /// Handles any type of error and returns appropriate user message
  static String handleError(dynamic error, {String? context}) {
    if (context != null) {
      _logError(context, 'unknown', error.toString());
    }

    if (error is FirebaseAuthException) {
      return mapFirebaseAuthError(error);
    }

    if (error is FirebaseException) {
      return mapFirestoreError(error);
    }

    if (error is PlatformException) {
      return mapNetworkError(error);
    }

    // Handle timeout exceptions
    if (error.toString().contains('TimeoutException')) {
      return 'Operation timed out. Please check your connection and try again.';
    }

    // Handle format exceptions
    if (error is FormatException) {
      return 'Invalid data format. Please check your input.';
    }

    // Generic error handling
    final errorMessage = _sanitizeErrorMessage(error.toString());
    return 'An error occurred: $errorMessage';
  }

  /// Get appropriate retry suggestion based on error type
  static String? getRetrySuggestion(dynamic error) {
    if (error is FirebaseAuthException) {
      return getAuthRecoverySuggestion(error.code);
    }

    final errorString = error.toString().toLowerCase();

    if (errorString.contains('network') || errorString.contains('timeout')) {
      return 'Check your internet connection and try again.';
    }

    if (errorString.contains('permission')) {
      return 'Please ensure you have proper permissions.';
    }

    if (errorString.contains('rate limit') ||
        errorString.contains('too many')) {
      return 'Please wait a few minutes before trying again.';
    }

    return 'Please try again. If the problem persists, contact support.';
  }

  // MARK: - Error Logging

  /// Log error with context for debugging
  static void _logError(String source, String code, String? message) {
    AppLogger.error('ErrorService', '$source Error: $code - ${message ?? 'No message'}');

    // In production, you might want to send this to Firebase Analytics or Crashlytics
    // FirebaseCrashlytics.instance.recordError(...);
  }

  /// Log general application errors
  static void logError(
    String context,
    dynamic error, {
    StackTrace? stackTrace,
  }) {
    AppLogger.error('ErrorService', '$context: ${error.toString()}', error, stackTrace);

    // In production, send to crash reporting service
    // FirebaseCrashlytics.instance.recordError(error, stackTrace, context: context);
  }

  /// Log informational messages for debugging
  static void logInfo(String context, String message) {
    AppLogger.info('ErrorService', '$context: $message');
  }

  // MARK: - Utility Methods

  /// Sanitize error messages to remove sensitive information
  static String _sanitizeErrorMessage(String message) {
    // Remove common sensitive patterns
    String sanitized = message
        .replaceAll(RegExp(r'uid:\s*[A-Za-z0-9]+'), 'uid: [REDACTED]')
        .replaceAll(RegExp(r'email:\s*[^\s]+@[^\s]+'), 'email: [REDACTED]')
        .replaceAll(RegExp(r'token:\s*[A-Za-z0-9]+'), 'token: [REDACTED]')
        .replaceAll(RegExp(r'password'), '[PASSWORD]');

    // Truncate very long messages
    if (sanitized.length > 200) {
      sanitized = '${sanitized.substring(0, 200)}...';
    }

    return sanitized;
  }

  /// Check if an error is likely due to network connectivity
  static bool isNetworkError(dynamic error) {
    final errorString = error.toString().toLowerCase();
    return errorString.contains('network') ||
        errorString.contains('timeout') ||
        errorString.contains('connection') ||
        errorString.contains('unreachable') ||
        errorString.contains('host lookup failed') ||
        (error is FirebaseException && error.code == 'unavailable');
  }

  /// Check if an error suggests the user should retry
  static bool isRetryableError(dynamic error) {
    if (isNetworkError(error)) return true;

    if (error is FirebaseException) {
      return [
        'unavailable',
        'deadline-exceeded',
        'aborted',
        'resource-exhausted',
      ].contains(error.code);
    }

    if (error is FirebaseAuthException) {
      return [
        'network-request-failed',
        'timeout',
        'too-many-requests',
      ].contains(error.code);
    }

    return false;
  }

  /// Check if an error requires user intervention (not just retry)
  static bool requiresUserAction(dynamic error) {
    if (error is FirebaseAuthException) {
      return [
        'invalid-email',
        'wrong-password',
        'user-not-found',
        'weak-password',
        'email-already-in-use',
        'requires-recent-login',
      ].contains(error.code);
    }

    if (error is FirebaseException) {
      return ['permission-denied', 'invalid-argument'].contains(error.code);
    }

    return false;
  }
}
