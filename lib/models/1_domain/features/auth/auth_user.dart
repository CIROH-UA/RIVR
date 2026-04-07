// lib/models/1_domain/features/auth/auth_user.dart

import 'package:firebase_auth/firebase_auth.dart';

/// Simple wrapper around Firebase User for RIVR
class AuthUser {
  final String uid;
  final String email;
  final String? displayName;
  final bool isEmailVerified;
  final DateTime? createdAt;

  AuthUser({
    required this.uid,
    required this.email,
    this.displayName,
    required this.isEmailVerified,
    this.createdAt,
  });

  /// Create AuthUser from Firebase User
  factory AuthUser.fromFirebaseUser(User firebaseUser) {
    return AuthUser(
      uid: firebaseUser.uid,
      email: firebaseUser.email ?? '',
      displayName: firebaseUser.displayName,
      isEmailVerified: firebaseUser.emailVerified,
      createdAt: firebaseUser.metadata.creationTime,
    );
  }

  /// Create AuthUser from JSON
  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      uid: json['uid'] as String,
      email: json['email'] as String,
      displayName: json['displayName'] as String?,
      isEmailVerified: json['isEmailVerified'] as bool? ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'email': email,
      'displayName': displayName,
      'isEmailVerified': isEmailVerified,
      'createdAt': createdAt?.toIso8601String(),
    };
  }

  /// Get first name from display name
  String get firstName {
    if (displayName == null || displayName!.isEmpty) return '';
    final parts = displayName!.split(' ');
    return parts.first;
  }

  /// Get last name from display name
  String get lastName {
    if (displayName == null || displayName!.isEmpty) return '';
    final parts = displayName!.split(' ');
    return parts.length > 1 ? parts.sublist(1).join(' ') : '';
  }

  @override
  String toString() =>
      'AuthUser(uid: $uid, email: $email, displayName: $displayName)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthUser && runtimeType == other.runtimeType && uid == other.uid;

  @override
  int get hashCode => uid.hashCode;
}
