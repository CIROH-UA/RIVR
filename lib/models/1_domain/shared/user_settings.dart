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
  final bool enableNotifications; // Flood Alerts (threshold pushes)
  final int notificationFrequency; // 1, 2, 3, or 4 times per day
  // Weekly Outlook digest — an independent notification type from flood alerts.
  final bool weeklyOutlookEnabled;
  // Consecutive weekly digests sent without the user opening the outlook. The
  // cron increments it and backs off cadence (biweekly, then monthly) as it
  // grows; the app resets it to 0 when the Outlook page is opened.
  final int weeklyDigestsSinceOpen;
  final List<String> favoriteReachIds;
  // Per-favorite data source, keyed by reachId (value = ForecastSource.id, e.g.
  // 'geoglows'). Only non-NWM favorites are stored; a missing key means NWM.
  // The notification Cloud Function reads this to pick the right forecast API.
  final Map<String, String> favoriteSources;
  // Per-river reminder frequency, keyed by reachId (value = an
  // AlertFrequency.wireValue, e.g. '6h'). Only rivers the user has changed are
  // stored; a missing key means the default. ADR 0011 decision 19 — read by
  // functions/src/alert-triggers.ts, so the VALUES are a cross-language
  // contract.
  final Map<String, String> alertFrequencies;
  // App-populated display label per favorite (reachId -> "White River" or
  // "Castilla, Peru"). The weekly-digest Cloud Function reads these for the push
  // banner because it can't geocode; the app writes them once it has the name or
  // reverse-geocoded place. Missing keys fall back to the server's river name.
  final Map<String, String> favoriteLabels;
  final List<String> fcmTokens;
  final List<String>
  customBackgroundImagePaths; // List of custom uploaded image paths
  final DateTime lastLoginDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  // ADR 0014 — guest mode. A guest is an anonymous Firebase user; the flag
  // is on the DOCUMENT (not derived from Auth) so Cloud Functions can tell
  // guests apart without an Auth lookup, and so `guestGcDaily` can reap the
  // abandoned ones. Flipped to false the moment an email is linked.
  final bool isGuest;
  // Written on every launch. It is the only "sign of life" the GC has — an
  // abandoned guest looks identical to a loyal one who never favourites.
  final DateTime? lastActiveAt;
  // The one dismissable "create an account" prompt (ADR 0014 UX-3) is shown
  // once per identity, tracked here rather than on the device so a reinstall
  // that keeps the uid does not repeat it.
  final bool accountPromptShown;

  UserSettings({
    required this.userId,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.preferredFlowUnit,
    required this.preferredTimeFormat,
    required this.enableNotifications,
    this.notificationFrequency = 1, // Default to once daily
    this.weeklyOutlookEnabled = false,
    this.weeklyDigestsSinceOpen = 0,
    required this.favoriteReachIds,
    this.favoriteSources = const {},
    this.alertFrequencies = const {},
    this.favoriteLabels = const {},
    this.fcmTokens = const [],
    this.customBackgroundImagePaths = const [], // Default to empty list
    required this.lastLoginDate,
    required this.createdAt,
    required this.updatedAt,
    this.isGuest = false,
    this.lastActiveAt,
    this.accountPromptShown = false,
  });

  UserSettings copyWith({
    String? email,
    String? firstName,
    String? lastName,
    FlowUnit? preferredFlowUnit,
    TimeFormat? preferredTimeFormat,
    bool? enableNotifications,
    int? notificationFrequency,
    bool? weeklyOutlookEnabled,
    int? weeklyDigestsSinceOpen,
    List<String>? favoriteReachIds,
    Map<String, String>? favoriteSources,
    Map<String, String>? alertFrequencies,
    Map<String, String>? favoriteLabels,
    List<String>? fcmTokens,
    List<String>? customBackgroundImagePaths,
    DateTime? lastLoginDate,
    bool? isGuest,
    DateTime? lastActiveAt,
    bool? accountPromptShown,
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
      weeklyOutlookEnabled:
          weeklyOutlookEnabled ?? this.weeklyOutlookEnabled,
      weeklyDigestsSinceOpen:
          weeklyDigestsSinceOpen ?? this.weeklyDigestsSinceOpen,
      favoriteReachIds: favoriteReachIds ?? this.favoriteReachIds,
      favoriteSources: favoriteSources ?? this.favoriteSources,
      alertFrequencies: alertFrequencies ?? this.alertFrequencies,
      favoriteLabels: favoriteLabels ?? this.favoriteLabels,
      fcmTokens: fcmTokens ?? this.fcmTokens,
      customBackgroundImagePaths:
          customBackgroundImagePaths ?? this.customBackgroundImagePaths,
      lastLoginDate: lastLoginDate ?? this.lastLoginDate,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isGuest: isGuest ?? this.isGuest,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      accountPromptShown: accountPromptShown ?? this.accountPromptShown,
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
  bool get hasValidFCMToken => fcmTokens.isNotEmpty;

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
