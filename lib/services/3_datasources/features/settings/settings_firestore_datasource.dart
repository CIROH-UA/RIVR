// lib/services/3_datasources/features/settings/settings_firestore_datasource.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rivr/services/3_datasources/shared/dtos/user_settings_dto.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';

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
    return UserSettingsDto.fromJson(doc.data()!, fallbackUserId: doc.id)
        .toEntity();
  }

  /// Fields the SERVER owns. The client may read them; it must never write
  /// them back.
  ///
  /// Every one of these is written by a Cloud Function and was being
  /// overwritten from a client-side cache with no expiry:
  ///
  ///   * `fcmTokens` — the server prunes tokens Apple and Google have
  ///     rejected. Writing a stale copy back RESURRECTS a dead token, and
  ///     every flood alert to that device then keeps failing silently.
  ///   * `weeklyDigestsSinceOpen` — a server-side counter. Writing it back
  ///     rewinds it and the digest cadence drifts.
  ///   * `accountPromptShown` — recorded on the document precisely so it
  ///     survives a reinstall.
  ///
  /// Measured 2026-11-09: tapping the ft³/s ↔ m³/s toggle did all three.
  static const Set<String> _serverOwnedFields = {
    'fcmTokens',
    'weeklyDigestsSinceOpen',
    'accountPromptShown',
  };

  /// Write the settings this client owns, without touching anything else.
  ///
  /// This was a whole-document `set()` with no merge, fed by an in-memory
  /// cache that no server write invalidates. So a settings save did not
  /// write settings — it rewrote all 22 fields of the user document from
  /// whatever this device last read, deleting any field the Dart DTO does
  /// not model and reverting every field the server owns.
  ///
  /// Two changes, and both are needed. `merge: true` stops fields the DTO
  /// has never heard of being deleted. Stripping the server-owned keys stops
  /// the ones it HAS heard of being reverted; merge alone would not, because
  /// a merge still writes the keys you give it.
  Future<void> saveSettings(UserSettings settings) async {
    final json = UserSettingsDto.fromEntity(settings).toJson()
      ..removeWhere((key, _) => _serverOwnedFields.contains(key));

    await _usersCollection
        .doc(settings.userId)
        .set(json, SetOptions(merge: true))
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

  /// Permanently delete the user's settings document.
  /// No-op if the document does not exist.
  Future<void> deleteSettings(String userId) async {
    await _usersCollection
        .doc(userId)
        .delete()
        .timeout(const Duration(seconds: 10));
  }
}
