// lib/services/3_datasources/shared/dtos/user_settings_dto.dart

import 'package:rivr/models/1_domain/shared/user_settings.dart';

/// Data Transfer Object for UserSettings.
///
/// Handles JSON serialization/deserialization for Firestore persistence.
/// The pure [UserSettings] entity contains only domain logic.
class UserSettingsDto {
  final String userId;
  final String email;
  final String firstName;
  final String lastName;
  final String preferredFlowUnit;
  final String preferredTimeFormat;
  final bool enableNotifications;
  final int notificationFrequency;
  final List<String> favoriteReachIds;
  final String? fcmToken;
  final List<String> customBackgroundImagePaths;
  final String lastLoginDate;
  final String createdAt;
  final String updatedAt;

  const UserSettingsDto({
    required this.userId,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.preferredFlowUnit,
    required this.preferredTimeFormat,
    required this.enableNotifications,
    this.notificationFrequency = 1,
    required this.favoriteReachIds,
    this.fcmToken,
    this.customBackgroundImagePaths = const [],
    required this.lastLoginDate,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserSettingsDto.fromJson(Map<String, dynamic> json) {
    return UserSettingsDto(
      userId: json['userId'] as String,
      email: json['email'] as String,
      firstName: json['firstName'] as String,
      lastName: json['lastName'] as String,
      preferredFlowUnit: json['preferredFlowUnit'] as String? ?? 'cfs',
      preferredTimeFormat:
          json['preferredTimeFormat'] as String? ?? 'twelveHour',
      enableNotifications: json['enableNotifications'] as bool? ?? false,
      notificationFrequency: json['notificationFrequency'] as int? ?? 1,
      favoriteReachIds: List<String>.from(
        json['favoriteReachIds'] as List? ?? [],
      ),
      fcmToken: json['fcmToken'] as String?,
      customBackgroundImagePaths: List<String>.from(
        json['customBackgroundImagePaths'] as List? ?? [],
      ),
      lastLoginDate: json['lastLoginDate'] as String,
      createdAt: json['createdAt'] as String,
      updatedAt: json['updatedAt'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'email': email,
      'firstName': firstName,
      'lastName': lastName,
      'preferredFlowUnit': preferredFlowUnit,
      'preferredTimeFormat': preferredTimeFormat,
      'enableNotifications': enableNotifications,
      'notificationFrequency': notificationFrequency,
      'favoriteReachIds': favoriteReachIds,
      'fcmToken': fcmToken,
      'customBackgroundImagePaths': customBackgroundImagePaths,
      'lastLoginDate': lastLoginDate,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  UserSettings toEntity() {
    return UserSettings(
      userId: userId,
      email: email,
      firstName: firstName,
      lastName: lastName,
      preferredFlowUnit:
          preferredFlowUnit == 'cms' ? FlowUnit.cms : FlowUnit.cfs,
      preferredTimeFormat: preferredTimeFormat == 'twentyFourHour'
          ? TimeFormat.twentyFourHour
          : TimeFormat.twelveHour,
      enableNotifications: enableNotifications,
      notificationFrequency: notificationFrequency,
      favoriteReachIds: favoriteReachIds,
      fcmToken: fcmToken,
      customBackgroundImagePaths: customBackgroundImagePaths,
      lastLoginDate: DateTime.parse(lastLoginDate),
      createdAt: DateTime.parse(createdAt),
      updatedAt: DateTime.parse(updatedAt),
    );
  }

  static UserSettingsDto fromEntity(UserSettings entity) {
    return UserSettingsDto(
      userId: entity.userId,
      email: entity.email,
      firstName: entity.firstName,
      lastName: entity.lastName,
      preferredFlowUnit: entity.preferredFlowUnit.value,
      preferredTimeFormat: entity.preferredTimeFormat.value,
      enableNotifications: entity.enableNotifications,
      notificationFrequency: entity.notificationFrequency,
      favoriteReachIds: entity.favoriteReachIds,
      fcmToken: entity.fcmToken,
      customBackgroundImagePaths: entity.customBackgroundImagePaths,
      lastLoginDate: entity.lastLoginDate.toIso8601String(),
      createdAt: entity.createdAt.toIso8601String(),
      updatedAt: entity.updatedAt.toIso8601String(),
    );
  }
}
