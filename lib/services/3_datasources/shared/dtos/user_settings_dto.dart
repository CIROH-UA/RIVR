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
  final bool weeklyOutlookEnabled;
  final int weeklyDigestsSinceOpen;
  final List<String> favoriteReachIds;
  final Map<String, String> favoriteSources;
  final Map<String, String> favoriteLabels;
  final List<String> fcmTokens;
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
    this.weeklyOutlookEnabled = false,
    this.weeklyDigestsSinceOpen = 0,
    required this.favoriteReachIds,
    this.favoriteSources = const {},
    this.favoriteLabels = const {},
    this.fcmTokens = const [],
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
      weeklyOutlookEnabled: json['weeklyOutlookEnabled'] as bool? ?? false,
      weeklyDigestsSinceOpen: json['weeklyDigestsSinceOpen'] as int? ?? 0,
      favoriteReachIds: List<String>.from(
        json['favoriteReachIds'] as List? ?? [],
      ),
      favoriteSources: (json['favoriteSources'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      favoriteLabels: (json['favoriteLabels'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      fcmTokens: _parseFcmTokens(json),
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
      'weeklyOutlookEnabled': weeklyOutlookEnabled,
      'weeklyDigestsSinceOpen': weeklyDigestsSinceOpen,
      'favoriteReachIds': favoriteReachIds,
      'favoriteSources': favoriteSources,
      'favoriteLabels': favoriteLabels,
      'fcmTokens': fcmTokens,
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
      weeklyOutlookEnabled: weeklyOutlookEnabled,
      weeklyDigestsSinceOpen: weeklyDigestsSinceOpen,
      favoriteReachIds: favoriteReachIds,
      favoriteSources: favoriteSources,
      favoriteLabels: favoriteLabels,
      fcmTokens: fcmTokens,
      customBackgroundImagePaths: customBackgroundImagePaths,
      lastLoginDate: DateTime.parse(lastLoginDate),
      createdAt: DateTime.parse(createdAt),
      updatedAt: DateTime.parse(updatedAt),
    );
  }

  /// Parse FCM tokens with backward compatibility.
  /// Reads `fcmTokens` array first; falls back to wrapping legacy `fcmToken` string.
  static List<String> _parseFcmTokens(Map<String, dynamic> json) {
    final tokens = json['fcmTokens'] as List?;
    if (tokens != null && tokens.isNotEmpty) {
      return List<String>.from(tokens);
    }
    // Legacy: single fcmToken field
    final legacy = json['fcmToken'] as String?;
    if (legacy != null && legacy.isNotEmpty) {
      return [legacy];
    }
    return [];
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
      weeklyOutlookEnabled: entity.weeklyOutlookEnabled,
      weeklyDigestsSinceOpen: entity.weeklyDigestsSinceOpen,
      favoriteReachIds: entity.favoriteReachIds,
      favoriteSources: entity.favoriteSources,
      favoriteLabels: entity.favoriteLabels,
      fcmTokens: entity.fcmTokens,
      customBackgroundImagePaths: entity.customBackgroundImagePaths,
      lastLoginDate: entity.lastLoginDate.toIso8601String(),
      createdAt: entity.createdAt.toIso8601String(),
      updatedAt: entity.updatedAt.toIso8601String(),
    );
  }
}
