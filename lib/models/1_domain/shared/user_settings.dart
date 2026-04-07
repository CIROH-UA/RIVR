// lib/models/1_domain/shared/user_settings.dart

enum FlowUnit {
  cfs,
  cms;

  String get value => name;
  String get displayLabel => this == cfs ? 'ft³/s' : 'm³/s';
}

enum TimeFormat {
  twelveHour,
  twentyFourHour;

  String get value => name;
}

class UserSettings {
  final String userId;
  final String email;
  final String firstName;
  final String lastName;
  final FlowUnit preferredFlowUnit;
  final TimeFormat preferredTimeFormat;
  final bool enableNotifications;
  final int notificationFrequency; // 1, 2, 3, or 4 times per day
  final List<String> favoriteReachIds;
  final String? fcmToken;
  final List<String>
  customBackgroundImagePaths; // List of custom uploaded image paths
  final DateTime lastLoginDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  UserSettings({
    required this.userId,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.preferredFlowUnit,
    required this.preferredTimeFormat,
    required this.enableNotifications,
    this.notificationFrequency = 1, // Default to once daily
    required this.favoriteReachIds,
    this.fcmToken,
    this.customBackgroundImagePaths = const [], // Default to empty list
    required this.lastLoginDate,
    required this.createdAt,
    required this.updatedAt,
  });

  UserSettings copyWith({
    String? email,
    String? firstName,
    String? lastName,
    FlowUnit? preferredFlowUnit,
    TimeFormat? preferredTimeFormat,
    bool? enableNotifications,
    int? notificationFrequency,
    List<String>? favoriteReachIds,
    String? fcmToken,
    List<String>? customBackgroundImagePaths,
    DateTime? lastLoginDate,
  }) {
    return UserSettings(
      userId: userId,
      email: email ?? this.email,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      preferredFlowUnit: preferredFlowUnit ?? this.preferredFlowUnit,
      preferredTimeFormat: preferredTimeFormat ?? this.preferredTimeFormat,
      enableNotifications: enableNotifications ?? this.enableNotifications,
      notificationFrequency:
          notificationFrequency ?? this.notificationFrequency,
      favoriteReachIds: favoriteReachIds ?? this.favoriteReachIds,
      fcmToken: fcmToken ?? this.fcmToken,
      customBackgroundImagePaths:
          customBackgroundImagePaths ?? this.customBackgroundImagePaths,
      lastLoginDate: lastLoginDate ?? this.lastLoginDate,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  // Simple favorite management
  UserSettings addFavorite(String reachId) {
    if (favoriteReachIds.contains(reachId)) return this;
    return copyWith(favoriteReachIds: [...favoriteReachIds, reachId]);
  }

  UserSettings removeFavorite(String reachId) {
    return copyWith(
      favoriteReachIds: favoriteReachIds.where((id) => id != reachId).toList(),
    );
  }

  bool isFavorite(String reachId) => favoriteReachIds.contains(reachId);

  String get fullName => '$firstName $lastName'.trim();

  // Helper method to check if user has valid FCM token
  bool get hasValidFCMToken => fcmToken != null && fcmToken!.isNotEmpty;

  // Custom background management
  bool get hasCustomBackgrounds => customBackgroundImagePaths.isNotEmpty;

  UserSettings addCustomBackground(String imagePath) {
    if (customBackgroundImagePaths.contains(imagePath)) return this;
    return copyWith(
      customBackgroundImagePaths: [...customBackgroundImagePaths, imagePath],
    );
  }

  UserSettings removeCustomBackground(String imagePath) {
    return copyWith(
      customBackgroundImagePaths: customBackgroundImagePaths
          .where((path) => path != imagePath)
          .toList(),
    );
  }

  UserSettings clearAllCustomBackgrounds() {
    return copyWith(customBackgroundImagePaths: []);
  }

  bool hasCustomBackground(String imagePath) =>
      customBackgroundImagePaths.contains(imagePath);
}
