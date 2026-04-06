// lib/features/settings/data/datasources/settings_firestore_datasource.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rivr/core/models/user_settings.dart';

/// Raw Firestore CRUD operations for user settings.
///
/// This datasource has no caching, no business logic, and no error mapping.
/// It simply executes Firestore operations and lets exceptions propagate
/// for the coordinator (repository) to handle.
class SettingsFirestoreDatasource {
  final FirebaseFirestore _firestore;

  SettingsFirestoreDatasource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _usersCollection =>
      _firestore.collection('users');

  /// Fetch user settings from Firestore.
  /// Returns null if the document does not exist.
  Future<UserSettings?> getSettings(String userId) async {
    final doc = await _usersCollection
        .doc(userId)
        .get()
        .timeout(const Duration(seconds: 10));

    if (!doc.exists || doc.data() == null) return null;
    return UserSettings.fromJson(doc.data()!);
  }

  /// Write a complete settings object to Firestore.
  Future<void> saveSettings(UserSettings settings) async {
    await _usersCollection
        .doc(settings.userId)
        .set(settings.toJson())
        .timeout(const Duration(seconds: 10));
  }

  /// Partial field update. Automatically appends `updatedAt`.
  Future<void> updateFields(
    String userId,
    Map<String, dynamic> updates,
  ) async {
    final updateData = {
      ...updates,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await _usersCollection
        .doc(userId)
        .update(updateData)
        .timeout(const Duration(seconds: 10));
  }

  /// Check whether a settings document exists for [userId].
  Future<bool> exists(String userId) async {
    final doc = await _usersCollection
        .doc(userId)
        .get()
        .timeout(const Duration(seconds: 5));
    return doc.exists;
  }
}
