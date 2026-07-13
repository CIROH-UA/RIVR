import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/shared/dtos/user_settings_dto.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';

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
    Map<String, String> favoriteSources = const {},
    List<String> fcmTokens = const [],
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
      favoriteSources: favoriteSources,
      fcmTokens: fcmTokens,
      customBackgroundImagePaths: customBackgroundImagePaths,
      lastLoginDate: lastLoginDate ?? now,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
    );
  }

  group('UserSettingsDto', () {
    group('fromJson / toJson roundtrip', () {
      test('serializes and deserializes all fields', () {
        final dto = UserSettingsDto(
          userId: 'user123',
          email: 'test@example.com',
          firstName: 'John',
          lastName: 'Doe',
          preferredFlowUnit: 'cms',
          preferredTimeFormat: 'twentyFourHour',
          enableNotifications: false,
          notificationFrequency: 3,
          favoriteReachIds: ['123', '456'],
          favoriteSources: {'456': 'geoglows'},
          fcmTokens: ['token_abc'],
          customBackgroundImagePaths: ['/path/to/img.jpg'],
          lastLoginDate: now.toIso8601String(),
          createdAt: now.toIso8601String(),
          updatedAt: now.toIso8601String(),
        );

        final json = dto.toJson();
        final restored = UserSettingsDto.fromJson(json);

        expect(restored.userId, dto.userId);
        expect(restored.email, dto.email);
        expect(restored.firstName, dto.firstName);
        expect(restored.lastName, dto.lastName);
        expect(restored.preferredFlowUnit, 'cms');
        expect(restored.preferredTimeFormat, 'twentyFourHour');
        expect(restored.enableNotifications, false);
        expect(restored.notificationFrequency, 3);
        expect(restored.favoriteReachIds, ['123', '456']);
        expect(restored.favoriteSources, {'456': 'geoglows'});
        expect(restored.fcmTokens, ['token_abc']);
        expect(restored.customBackgroundImagePaths, ['/path/to/img.jpg']);
        expect(restored.lastLoginDate, now.toIso8601String());
        expect(restored.createdAt, now.toIso8601String());
        expect(restored.updatedAt, now.toIso8601String());
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
        };

        final dto = UserSettingsDto.fromJson(json);
        expect(dto.enableNotifications, false);
        expect(dto.notificationFrequency, 1);
        expect(dto.favoriteReachIds, isEmpty);
        expect(dto.favoriteSources, isEmpty);
        expect(dto.fcmTokens, isEmpty);
        expect(dto.customBackgroundImagePaths, isEmpty);
      });
    });

    group('fromEntity / toEntity', () {
      test('converts entity to DTO and back preserving all fields', () {
        final original = createSettings(
          preferredFlowUnit: FlowUnit.cms,
          preferredTimeFormat: TimeFormat.twentyFourHour,
          enableNotifications: false,
          notificationFrequency: 3,
          favoriteReachIds: ['123', '456'],
          favoriteSources: {'456': 'geoglows'},
          fcmTokens: ['token_abc'],
          customBackgroundImagePaths: ['/path/to/img.jpg'],
        );

        final dto = UserSettingsDto.fromEntity(original);
        expect(dto.userId, original.userId);
        expect(dto.preferredFlowUnit, 'cms');
        expect(dto.preferredTimeFormat, 'twentyFourHour');

        final restored = dto.toEntity();
        expect(restored.userId, original.userId);
        expect(restored.email, original.email);
        expect(restored.firstName, original.firstName);
        expect(restored.lastName, original.lastName);
        expect(restored.preferredFlowUnit, FlowUnit.cms);
        expect(restored.preferredTimeFormat, TimeFormat.twentyFourHour);
        expect(restored.enableNotifications, false);
        expect(restored.notificationFrequency, 3);
        expect(restored.favoriteReachIds, ['123', '456']);
        expect(restored.favoriteSources, {'456': 'geoglows'});
        expect(restored.fcmTokens, ['token_abc']);
        expect(restored.customBackgroundImagePaths, ['/path/to/img.jpg']);
        expect(restored.lastLoginDate, original.lastLoginDate);
        expect(restored.createdAt, original.createdAt);
        expect(restored.updatedAt, original.updatedAt);
      });

      test('maps CFS flow unit correctly', () {
        final entity = createSettings(preferredFlowUnit: FlowUnit.cfs);
        final dto = UserSettingsDto.fromEntity(entity);
        expect(dto.preferredFlowUnit, 'cfs');

        final restored = dto.toEntity();
        expect(restored.preferredFlowUnit, FlowUnit.cfs);
      });

      test('maps CMS flow unit correctly', () {
        final entity = createSettings(preferredFlowUnit: FlowUnit.cms);
        final dto = UserSettingsDto.fromEntity(entity);
        expect(dto.preferredFlowUnit, 'cms');

        final restored = dto.toEntity();
        expect(restored.preferredFlowUnit, FlowUnit.cms);
      });

      test('maps twelveHour time format correctly', () {
        final entity = createSettings(preferredTimeFormat: TimeFormat.twelveHour);
        final dto = UserSettingsDto.fromEntity(entity);
        expect(dto.preferredTimeFormat, 'twelveHour');

        final restored = dto.toEntity();
        expect(restored.preferredTimeFormat, TimeFormat.twelveHour);
      });

      test('maps twentyFourHour time format correctly', () {
        final entity = createSettings(
          preferredTimeFormat: TimeFormat.twentyFourHour,
        );
        final dto = UserSettingsDto.fromEntity(entity);
        expect(dto.preferredTimeFormat, 'twentyFourHour');

        final restored = dto.toEntity();
        expect(restored.preferredTimeFormat, TimeFormat.twentyFourHour);
      });

      test('handles empty fcmTokens', () {
        final entity = createSettings();
        final dto = UserSettingsDto.fromEntity(entity);
        expect(dto.fcmTokens, isEmpty);

        final restored = dto.toEntity();
        expect(restored.fcmTokens, isEmpty);
      });

      test('reads legacy fcmToken field for backward compatibility', () {
        final json = {
          'userId': 'u1',
          'email': 'a@b.com',
          'firstName': 'A',
          'lastName': 'B',
          'preferredFlowUnit': 'cfs',
          'preferredTimeFormat': 'twelveHour',
          'fcmToken': 'legacy_token',
          'lastLoginDate': DateTime(2025, 6, 15, 12, 0).toIso8601String(),
          'createdAt': DateTime(2025, 6, 15, 12, 0).toIso8601String(),
          'updatedAt': DateTime(2025, 6, 15, 12, 0).toIso8601String(),
        };

        final dto = UserSettingsDto.fromJson(json);
        expect(dto.fcmTokens, ['legacy_token']);
      });
    });
  });
}
