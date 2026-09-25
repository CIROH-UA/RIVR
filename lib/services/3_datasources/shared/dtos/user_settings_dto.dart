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
  /// Per-river reminder frequency; see UserSettings.alertFrequencies.
  final Map<String, String> alertFrequencies;
  final Map<String, String> favoriteLabels;
  final List<String> fcmTokens;
  final List<String> customBackgroundImagePaths;
  final String lastLoginDate;
  final String createdAt;
  final String updatedAt;
  // ADR 0014 guest fields. lastActiveAt is ISO-8601 like the other dates
  // here; the Cloud Function that reads it (guestGcDaily) parses the string.
  final bool isGuest;
  final String? lastActiveAt;
  final bool accountPromptShown;

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
    this.alertFrequencies = const {},
    this.favoriteLabels = const {},
    this.fcmTokens = const [],
    this.customBackgroundImagePaths = const [],
    required this.lastLoginDate,
    required this.createdAt,
    required this.updatedAt,
    this.isGuest = false,
    this.lastActiveAt,
    this.accountPromptShown = false,
  });

  /// [fallbackUserId] is the document id. A document whose `userId` is
  /// missing used to throw here, and a throw on this path is not a blank
  /// field — it is favourites that cannot be saved and a map that cannot be
  /// used (build 838). The id is always known by the caller, so use it.
  /// Stand-in for a date a stub document never wrote.
  static const String _epoch = '1970-01-01T00:00:00.000Z';

  factory UserSettingsDto.fromJson(
    Map<String, dynamic> json, {
    String? fallbackUserId,
  }) {
    return UserSettingsDto(
      userId: json['userId'] as String? ?? fallbackUserId ?? '',
      // Guests (ADR 0014) have no email or name; the document stores ''.
      email: json['email'] as String? ?? '',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
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
      alertFrequencies: (json['alertFrequencies'] as Map?)?.map(
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
      // Dates are tolerant for the same reason as userId: a document missing
      // one is a document we can still work with, while a throw here takes
      // the whole app down for that user. `toEntity` parses these, so the
      // fallback has to be a valid ISO-8601 string, not ''.
      lastLoginDate: json['lastLoginDate'] as String? ?? _epoch,
      createdAt: json['createdAt'] as String? ?? _epoch,
      updatedAt: json['updatedAt'] as String? ?? _epoch,
      isGuest: json['isGuest'] as bool? ?? false,
      lastActiveAt: json['lastActiveAt'] as String?,
      accountPromptShown: json['accountPromptShown'] as bool? ?? false,
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
      'alertFrequencies': alertFrequencies,
      'favoriteLabels': favoriteLabels,
      'fcmTokens': fcmTokens,
      'customBackgroundImagePaths': customBackgroundImagePaths,
      'lastLoginDate': lastLoginDate,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'isGuest': isGuest,
      if (lastActiveAt != null) 'lastActiveAt': lastActiveAt,
      'accountPromptShown': accountPromptShown,
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
      alertFrequencies: alertFrequencies,
      favoriteLabels: favoriteLabels,
      fcmTokens: fcmTokens,
      customBackgroundImagePaths: customBackgroundImagePaths,
      lastLoginDate: DateTime.parse(lastLoginDate),
      createdAt: DateTime.parse(createdAt),
      updatedAt: DateTime.parse(updatedAt),
      isGuest: isGuest,
      lastActiveAt:
          lastActiveAt == null ? null : DateTime.tryParse(lastActiveAt!),
      accountPromptShown: accountPromptShown,
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
      alertFrequencies: entity.alertFrequencies,
      favoriteLabels: entity.favoriteLabels,
      fcmTokens: entity.fcmTokens,
      customBackgroundImagePaths: entity.customBackgroundImagePaths,
      lastLoginDate: entity.lastLoginDate.toIso8601String(),
      createdAt: entity.createdAt.toIso8601String(),
      updatedAt: entity.updatedAt.toIso8601String(),
      isGuest: entity.isGuest,
      lastActiveAt: entity.lastActiveAt?.toIso8601String(),
      accountPromptShown: entity.accountPromptShown,
    );
  }
}
