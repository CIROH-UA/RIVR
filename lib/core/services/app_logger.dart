// lib/core/services/app_logger.dart
//
// Structured logging utility for RIVR.
// Replaces raw print() calls with leveled, gated logging.
// Debug/info logs are silenced in release builds.

import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

class AppLogger {
  AppLogger._();

  /// Verbose debug information — silenced in release builds.
  static void debug(String tag, String message) {
    if (kDebugMode) {
      developer.log(message, name: tag, level: 500);
    }
  }

  /// Operational info (initialization, success) — silenced in release builds.
  static void info(String tag, String message) {
    if (kDebugMode) {
      developer.log(message, name: tag, level: 800);
    }
  }

  /// Potential issues that don't prevent operation — always logs.
  static void warning(String tag, String message) {
    developer.log('WARNING: $message', name: tag, level: 900);
  }

  /// Errors — always logs.
  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    developer.log(
      'ERROR: $message',
      name: tag,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
