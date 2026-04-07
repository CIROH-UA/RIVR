// lib/models/1_domain/shared/failure.dart
//
// The original Failure/NetworkFailure/CacheFailure/AuthFailure hierarchy
// has been replaced by ServiceResult + ServiceException.
//
// Re-export the new types so any existing imports continue to work.
// This file will move to services/4_infrastructure/shared/ in Phase 8.

export 'package:rivr/services/4_infrastructure/shared/service_result.dart';
