// lib/core/models/user_settings.dart

enum FlowUnit {
  cfs,
  cms;

  String get value => name;
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
  final bool enableDarkMode;
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
    required this.enableDarkMode,
    required this.favoriteReachIds,
    this.fcmToken,
    this.customBackgroundImagePaths = const [], // Default to empty list
    required this.lastLoginDate,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserSettings.fromJson(Map<String, dynamic> json) {
    return UserSettings(
      userId: json['userId'] as String,
      email: json['email'] as String,
      firstName: json['firstName'] as String,
      lastName: json['lastName'] as String,
      preferredFlowUnit: json['preferredFlowUnit'] == 'cms'
          ? FlowUnit.cms
          : FlowUnit.cfs,
      preferredTimeFormat: json['preferredTimeFormat'] == 'twentyFourHour'
          ? TimeFormat.twentyFourHour
          : TimeFormat.twelveHour,
      enableNotifications: json['enableNotifications'] as bool? ?? true,
      enableDarkMode: json['enableDarkMode'] as bool? ?? false,
      favoriteReachIds: List<String>.from(
        json['favoriteReachIds'] as List? ?? [],
      ),
      fcmToken: json['fcmToken'] as String?,
      customBackgroundImagePaths: List<String>.from(
        json['customBackgroundImagePaths'] as List? ?? [],
      ),
      lastLoginDate: DateTime.parse(json['lastLoginDate'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'email': email,
      'firstName': firstName,
      'lastName': lastName,
      'preferredFlowUnit': preferredFlowUnit.value,
      'preferredTimeFormat': preferredTimeFormat.value,
      'enableNotifications': enableNotifications,
      'enableDarkMode': enableDarkMode,
      'favoriteReachIds': favoriteReachIds,
      'fcmToken': fcmToken,
      'customBackgroundImagePaths': customBackgroundImagePaths,
      'lastLoginDate': lastLoginDate.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  UserSettings copyWith({
    String? email,
    String? firstName,
    String? lastName,
    FlowUnit? preferredFlowUnit,
    TimeFormat? preferredTimeFormat,
    bool? enableNotifications,
    bool? enableDarkMode,
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
      enableDarkMode: enableDarkMode ?? this.enableDarkMode,
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
