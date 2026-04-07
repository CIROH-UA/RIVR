// test/services/3_datasources/features/settings/settings_firestore_datasource_test.dart

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/shared/dtos/user_settings_dto.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/3_datasources/features/settings/settings_firestore_datasource.dart';

UserSettings _createSettings({
  String userId = 'user1',
  String email = 'test@example.com',
  String firstName = 'Test',
  String lastName = 'User',
  FlowUnit flowUnit = FlowUnit.cfs,
}) {
  final now = DateTime(2026, 4, 6);
  return UserSettings(
    userId: userId,
    email: email,
    firstName: firstName,
    lastName: lastName,
    preferredFlowUnit: flowUnit,
    preferredTimeFormat: TimeFormat.twelveHour,
    enableNotifications: false,
    favoriteReachIds: [],
    lastLoginDate: now,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late FakeFirebaseFirestore fakeFirestore;
  late SettingsFirestoreDatasource datasource;

  setUp(() {
    fakeFirestore = FakeFirebaseFirestore();
    datasource = SettingsFirestoreDatasource(firestore: fakeFirestore);
  });

  group('SettingsFirestoreDatasource — getSettings', () {
    test('returns null when document does not exist', () async {
      final result = await datasource.getSettings('nonexistent');
      expect(result, isNull);
    });

    test('returns UserSettings when document exists', () async {
      final settings = _createSettings();
      await fakeFirestore
          .collection('users')
          .doc('user1')
          .set(UserSettingsDto.fromEntity(settings).toJson());

      final result = await datasource.getSettings('user1');
      expect(result, isNotNull);
      expect(result!.userId, 'user1');
      expect(result.email, 'test@example.com');
      expect(result.firstName, 'Test');
      expect(result.preferredFlowUnit, FlowUnit.cfs);
    });
  });

  group('SettingsFirestoreDatasource — saveSettings', () {
    test('creates document in Firestore', () async {
      final settings = _createSettings();
      await datasource.saveSettings(settings);

      final doc = await fakeFirestore.collection('users').doc('user1').get();
      expect(doc.exists, isTrue);
      expect(doc.data()!['email'], 'test@example.com');
    });

    test('overwrites existing document', () async {
      final original = _createSettings(firstName: 'Original');
      await datasource.saveSettings(original);

      final updated = _createSettings(firstName: 'Updated');
      await datasource.saveSettings(updated);

      final doc = await fakeFirestore.collection('users').doc('user1').get();
      expect(doc.data()!['firstName'], 'Updated');
    });
  });

  group('SettingsFirestoreDatasource — updateFields', () {
    test('updates specific fields and adds updatedAt', () async {
      final settings = _createSettings();
      await fakeFirestore
          .collection('users')
          .doc('user1')
          .set(UserSettingsDto.fromEntity(settings).toJson());

      await datasource.updateFields('user1', {'firstName': 'NewName'});

      final doc = await fakeFirestore.collection('users').doc('user1').get();
      expect(doc.data()!['firstName'], 'NewName');
      expect(doc.data()!['updatedAt'], isNotNull);
    });

    test('preserves fields not included in update', () async {
      final settings = _createSettings(
        firstName: 'Test',
        lastName: 'User',
      );
      await fakeFirestore
          .collection('users')
          .doc('user1')
          .set(UserSettingsDto.fromEntity(settings).toJson());

      await datasource.updateFields('user1', {'firstName': 'NewName'});

      final doc = await fakeFirestore.collection('users').doc('user1').get();
      expect(doc.data()!['firstName'], 'NewName');
      expect(doc.data()!['lastName'], 'User');
    });
  });

  group('SettingsFirestoreDatasource — exists', () {
    test('returns false when document does not exist', () async {
      final result = await datasource.exists('nonexistent');
      expect(result, isFalse);
    });

    test('returns true when document exists', () async {
      final settings = _createSettings();
      await fakeFirestore
          .collection('users')
          .doc('user1')
          .set(UserSettingsDto.fromEntity(settings).toJson());

      final result = await datasource.exists('user1');
      expect(result, isTrue);
    });
  });
}
