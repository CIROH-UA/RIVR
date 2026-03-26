import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/core/models/user_settings.dart';

void main() {
  final now = DateTime(2025, 6, 15, 12, 0);

  UserSettings createSettings({
    String userId = 'user123',
    String email = 'test@example.com',
    String firstName = 'John',
    String lastName = 'Doe',
    FlowUnit preferredFlowUnit = FlowUnit.cfs,
    TimeFormat preferredTimeFormat = TimeFormat.twelveHour,
    bool enableNotifications = true,
    int notificationFrequency = 1,
    List<String> favoriteReachIds = const [],
    String? fcmToken,
    List<String> customBackgroundImagePaths = const [],
    DateTime? lastLoginDate,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return UserSettings(
      userId: userId,
      email: email,
      firstName: firstName,
      lastName: lastName,
      preferredFlowUnit: preferredFlowUnit,
      preferredTimeFormat: preferredTimeFormat,
      enableNotifications: enableNotifications,
      notificationFrequency: notificationFrequency,
      favoriteReachIds: favoriteReachIds,
      fcmToken: fcmToken,
      customBackgroundImagePaths: customBackgroundImagePaths,
      lastLoginDate: lastLoginDate ?? now,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
    );
  }

  group('FlowUnit', () {
    test('value returns name string', () {
      expect(FlowUnit.cfs.value, 'cfs');
      expect(FlowUnit.cms.value, 'cms');
    });
  });

  group('TimeFormat', () {
    test('value returns name string', () {
      expect(TimeFormat.twelveHour.value, 'twelveHour');
      expect(TimeFormat.twentyFourHour.value, 'twentyFourHour');
    });
  });

  group('UserSettings', () {
    group('toJson / fromJson roundtrip', () {
      test('serializes and deserializes all fields', () {
        final original = createSettings(
          preferredFlowUnit: FlowUnit.cms,
          preferredTimeFormat: TimeFormat.twentyFourHour,
          enableNotifications: false,
          notificationFrequency: 3,
          favoriteReachIds: ['123', '456'],
          fcmToken: 'token_abc',
          customBackgroundImagePaths: ['/path/to/img.jpg'],
        );

        final json = original.toJson();
        final restored = UserSettings.fromJson(json);

        expect(restored.userId, original.userId);
        expect(restored.email, original.email);
        expect(restored.firstName, original.firstName);
        expect(restored.lastName, original.lastName);
        expect(restored.preferredFlowUnit, FlowUnit.cms);
        expect(restored.preferredTimeFormat, TimeFormat.twentyFourHour);
        expect(restored.enableNotifications, false);
        expect(restored.notificationFrequency, 3);
        expect(restored.favoriteReachIds, ['123', '456']);
        expect(restored.fcmToken, 'token_abc');
        expect(restored.customBackgroundImagePaths, ['/path/to/img.jpg']);
        expect(restored.lastLoginDate, original.lastLoginDate);
        expect(restored.createdAt, original.createdAt);
        expect(restored.updatedAt, original.updatedAt);
      });

      test('defaults for missing optional fields', () {
        final json = {
          'userId': 'u1',
          'email': 'a@b.com',
          'firstName': 'A',
          'lastName': 'B',
          'preferredFlowUnit': 'cfs',
          'preferredTimeFormat': 'twelveHour',
          'lastLoginDate': now.toIso8601String(),
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
          // enableNotifications, notificationFrequency missing
        };

        final settings = UserSettings.fromJson(json);
        expect(settings.enableNotifications, false);
        expect(settings.notificationFrequency, 1);
        expect(settings.favoriteReachIds, isEmpty);
        expect(settings.fcmToken, isNull);
        expect(settings.customBackgroundImagePaths, isEmpty);
      });

      test('parses CFS flow unit', () {
        final json = createSettings(preferredFlowUnit: FlowUnit.cfs).toJson();
        final restored = UserSettings.fromJson(json);
        expect(restored.preferredFlowUnit, FlowUnit.cfs);
      });

      test('parses CMS flow unit', () {
        final json = createSettings(preferredFlowUnit: FlowUnit.cms).toJson();
        final restored = UserSettings.fromJson(json);
        expect(restored.preferredFlowUnit, FlowUnit.cms);
      });

      test('parses 24-hour time format', () {
        final json = createSettings(
          preferredTimeFormat: TimeFormat.twentyFourHour,
        ).toJson();
        final restored = UserSettings.fromJson(json);
        expect(restored.preferredTimeFormat, TimeFormat.twentyFourHour);
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final original = createSettings();
        final copy = original.copyWith(
          firstName: 'Jane',
          preferredFlowUnit: FlowUnit.cms,
        );

        expect(copy.firstName, 'Jane');
        expect(copy.preferredFlowUnit, FlowUnit.cms);
        expect(copy.userId, original.userId);
        expect(copy.email, original.email);
        expect(copy.createdAt, original.createdAt);
      });

      test('preserves userId and createdAt', () {
        final original = createSettings();
        final copy = original.copyWith(email: 'new@email.com');

        expect(copy.userId, original.userId);
        expect(copy.createdAt, original.createdAt);
      });

      test('updates updatedAt timestamp', () {
        final original = createSettings(updatedAt: DateTime(2020, 1, 1));
        final copy = original.copyWith(firstName: 'Updated');

        expect(copy.updatedAt.isAfter(original.updatedAt), true);
      });
    });

    group('favorite management', () {
      test('addFavorite adds a reach ID', () {
        final settings = createSettings(favoriteReachIds: ['123']);
        final updated = settings.addFavorite('456');

        expect(updated.favoriteReachIds, ['123', '456']);
      });

      test('addFavorite does not duplicate existing ID', () {
        final settings = createSettings(favoriteReachIds: ['123']);
        final updated = settings.addFavorite('123');

        expect(updated.favoriteReachIds, ['123']);
        expect(identical(updated, settings), true);
      });

      test('removeFavorite removes a reach ID', () {
        final settings = createSettings(favoriteReachIds: ['123', '456']);
        final updated = settings.removeFavorite('123');

        expect(updated.favoriteReachIds, ['456']);
      });

      test('removeFavorite handles non-existent ID', () {
        final settings = createSettings(favoriteReachIds: ['123']);
        final updated = settings.removeFavorite('999');

        expect(updated.favoriteReachIds, ['123']);
      });

      test('isFavorite checks membership', () {
        final settings = createSettings(favoriteReachIds: ['123', '456']);

        expect(settings.isFavorite('123'), true);
        expect(settings.isFavorite('456'), true);
        expect(settings.isFavorite('789'), false);
      });
    });

    group('custom background management', () {
      test('addCustomBackground adds a path', () {
        final settings = createSettings();
        final updated = settings.addCustomBackground('/path/img.jpg');

        expect(updated.customBackgroundImagePaths, ['/path/img.jpg']);
      });

      test('addCustomBackground does not duplicate', () {
        final settings = createSettings(
          customBackgroundImagePaths: ['/path/img.jpg'],
        );
        final updated = settings.addCustomBackground('/path/img.jpg');

        expect(updated.customBackgroundImagePaths, ['/path/img.jpg']);
        expect(identical(updated, settings), true);
      });

      test('removeCustomBackground removes a path', () {
        final settings = createSettings(
          customBackgroundImagePaths: ['/a.jpg', '/b.jpg'],
        );
        final updated = settings.removeCustomBackground('/a.jpg');

        expect(updated.customBackgroundImagePaths, ['/b.jpg']);
      });

      test('clearAllCustomBackgrounds empties the list', () {
        final settings = createSettings(
          customBackgroundImagePaths: ['/a.jpg', '/b.jpg'],
        );
        final updated = settings.clearAllCustomBackgrounds();

        expect(updated.customBackgroundImagePaths, isEmpty);
      });

      test('hasCustomBackground checks membership', () {
        final settings = createSettings(
          customBackgroundImagePaths: ['/a.jpg'],
        );

        expect(settings.hasCustomBackground('/a.jpg'), true);
        expect(settings.hasCustomBackground('/b.jpg'), false);
      });

      test('hasCustomBackgrounds checks non-empty', () {
        expect(createSettings().hasCustomBackgrounds, false);
        expect(
          createSettings(customBackgroundImagePaths: ['/a.jpg']).hasCustomBackgrounds,
          true,
        );
      });
    });

    group('helper properties', () {
      test('fullName combines first and last name', () {
        final settings = createSettings(firstName: 'John', lastName: 'Doe');
        expect(settings.fullName, 'John Doe');
      });

      test('fullName trims whitespace', () {
        final settings = createSettings(firstName: '', lastName: 'Doe');
        expect(settings.fullName, 'Doe');
      });

      test('hasValidFCMToken checks for non-null non-empty token', () {
        expect(createSettings(fcmToken: null).hasValidFCMToken, false);
        expect(createSettings(fcmToken: '').hasValidFCMToken, false);
        expect(createSettings(fcmToken: 'token_abc').hasValidFCMToken, true);
      });
    });
  });
}
