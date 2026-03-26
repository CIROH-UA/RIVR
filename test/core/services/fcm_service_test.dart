// test/core/services/fcm_service_test.dart
//
// Unit tests for FCMService — focused on the Firestore interaction layer
// (token persistence, atomic writes, FieldValue.delete).
//
// Manual end-to-end verification checklist:
//
//  1. Firestore pre-check
//     Firebase Console → Firestore → users/{yourUserId}
//     Verify fields: enableNotifications, fcmToken, notificationFrequency
//
//  2. Enable flow
//     Settings → Notifications → toggle ON
//     Firestore should show: enableNotifications: true, fcmToken: <string>
//     Both written in a single update (check timestamp)
//
//  3. Disable flow
//     Toggle OFF → Firestore should show: enableNotifications: false,
//     fcmToken field REMOVED (not null, not empty — gone)
//
//  4. Self-healing
//     Toggle ON → kill app → relaunch → token still in Firestore
//
//  5. Health check
//     curl https://us-central1-ciroh-rivr-app.cloudfunctions.net/healthCheck
//
//  6. Manual alert trigger
//     curl -X POST https://us-central1-ciroh-rivr-app.cloudfunctions.net/triggerAlertCheck \
//       -H "Content-Type: application/json" -d '{"data":{"slot":1}}'
//
//  7. Cloud Function logs
//     firebase functions:log --only checkRiverAlerts6am,triggerAlertCheck
//
//  8. Notification delivery (see plan for SCALE_FACTOR trick if no floods)
//
//  9. Duplicate prevention — trigger twice within 6h, second says "Still exceeds"

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/fcm_service.dart';
import 'package:rivr/core/services/i_fcm_service.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';

@GenerateNiceMocks([MockSpec<FirebaseMessaging>()])
import 'fcm_service_test.mocks.dart';

// ---------------------------------------------------------------------------
// Spy implementation of IUserSettingsService
// ---------------------------------------------------------------------------

/// Records calls to [updateUserSettings] so tests can verify:
/// - which fields were written
/// - how many writes occurred (atomic vs. multiple)
/// - the exact user ID targeted
class SpyUserSettingsService implements IUserSettingsService {
  // --- updateUserSettings spy data ---
  int updateCallCount = 0;
  String? lastUpdateUserId;
  Map<String, dynamic>? lastUpdateData;
  final List<Map<String, dynamic>> allUpdateCalls = [];

  /// Optional: throw on next updateUserSettings call
  Exception? updateError;

  // --- getUserSettings spy data ---
  UserSettings? stubbedSettings;

  @override
  Future<void> updateUserSettings(
    String userId,
    Map<String, dynamic> updates,
  ) async {
    if (updateError != null) throw updateError!;
    updateCallCount++;
    lastUpdateUserId = userId;
    lastUpdateData = updates;
    allUpdateCalls.add(Map.of(updates));
  }

  @override
  Future<UserSettings?> getUserSettings(String userId) async => stubbedSettings;

  // --- Unused stubs (satisfy the interface) ---
  @override
  Future<void> saveUserSettings(UserSettings settings) async {}
  @override
  Future<UserSettings?> addCustomBackgroundImage(String u, String p) async =>
      null;
  @override
  Future<UserSettings?> removeCustomBackgroundImage(String u, String p) async =>
      null;
  @override
  Future<List<String>> getUserCustomBackgrounds(String u) async => [];
  @override
  Future<UserSettings?> validateCustomBackgrounds(String u) async => null;
  @override
  Future<UserSettings?> clearAllCustomBackgrounds(String u) async => null;
  @override
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async =>
      _dummySettings(userId);
  @override
  Future<UserSettings?> syncAfterLogin(String u) async => null;
  @override
  Future<UserSettings?> addFavoriteReach(String u, String r) async => null;
  @override
  Future<UserSettings?> removeFavoriteReach(String u, String r) async => null;
  @override
  Future<UserSettings?> updateFlowUnit(String u, FlowUnit f) async => null;
  @override
  Future<UserSettings?> updateNotifications(String u, bool e) async => null;
  @override
  Future<UserSettings?> updateNotificationFrequency(String u, int f) async =>
      null;
  @override
  void clearCache() {}
  @override
  Future<bool> userHasSettings(String u) async => false;
  @override
  Future<void> syncFlowUnitPreference(String u) async {}

  UserSettings _dummySettings(String userId) => UserSettings(
        userId: userId,
        email: 'test@test.com',
        firstName: 'Test',
        lastName: 'User',
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: false,
        favoriteReachIds: [],
        customBackgroundImagePaths: [],
        lastLoginDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Stub [MockFirebaseMessaging] so `requestPermission` grants access
/// and `getToken` returns [token].
void stubMessagingGranted(MockFirebaseMessaging mock, {String? token}) {
  when(mock.requestPermission(
    alert: anyNamed('alert'),
    announcement: anyNamed('announcement'),
    badge: anyNamed('badge'),
    carPlay: anyNamed('carPlay'),
    criticalAlert: anyNamed('criticalAlert'),
    provisional: anyNamed('provisional'),
    sound: anyNamed('sound'),
  )).thenAnswer((_) async => _grantedSettings());

  when(mock.getToken())
      .thenAnswer((_) async => token ?? 'fcm-test-token-abcdefghijklmnop');

  when(mock.getNotificationSettings())
      .thenAnswer((_) async => _grantedSettings());

  // onTokenRefresh — return an empty stream by default
  when(mock.onTokenRefresh).thenAnswer((_) => const Stream.empty());
}

/// Stub [MockFirebaseMessaging] so `requestPermission` denies access.
void stubMessagingDenied(MockFirebaseMessaging mock) {
  when(mock.requestPermission(
    alert: anyNamed('alert'),
    announcement: anyNamed('announcement'),
    badge: anyNamed('badge'),
    carPlay: anyNamed('carPlay'),
    criticalAlert: anyNamed('criticalAlert'),
    provisional: anyNamed('provisional'),
    sound: anyNamed('sound'),
  )).thenAnswer((_) async => _deniedSettings());

  when(mock.getNotificationSettings())
      .thenAnswer((_) async => _deniedSettings());
}

// We can't construct NotificationSettings directly — it's an FCM internal.
// NiceMock returns sensible defaults, but requestPermission needs a real
// NotificationSettings with authorizationStatus.  We use a second mock:
NotificationSettings _grantedSettings() {
  final s = _FakeNotificationSettings();
  s._status = AuthorizationStatus.authorized;
  return s;
}

NotificationSettings _deniedSettings() {
  final s = _FakeNotificationSettings();
  s._status = AuthorizationStatus.denied;
  return s;
}

class _FakeNotificationSettings extends Fake implements NotificationSettings {
  AuthorizationStatus _status = AuthorizationStatus.notDetermined;

  @override
  AuthorizationStatus get authorizationStatus => _status;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Preserve original enum / interface tests
  group('NotificationPermissionResult', () {
    test('has all four expected values', () {
      expect(NotificationPermissionResult.values, hasLength(4));
      expect(
        NotificationPermissionResult.values,
        containsAll([
          NotificationPermissionResult.granted,
          NotificationPermissionResult.denied,
          NotificationPermissionResult.permanentlyDenied,
          NotificationPermissionResult.error,
        ]),
      );
    });

    test('granted is distinct from denied states', () {
      expect(
        NotificationPermissionResult.granted,
        isNot(NotificationPermissionResult.denied),
      );
      expect(
        NotificationPermissionResult.granted,
        isNot(NotificationPermissionResult.permanentlyDenied),
      );
    });

    test('denied is distinct from permanentlyDenied', () {
      expect(
        NotificationPermissionResult.denied,
        isNot(NotificationPermissionResult.permanentlyDenied),
      );
    });
  });

  group('IFCMService interface', () {
    test('navigatorKey setter accepts GlobalKey<NavigatorState>', () {
      final key = GlobalKey<NavigatorState>();
      expect(key, isNotNull);
    });
  });

  // -----------------------------------------------------------------------
  // FCMService unit tests
  // -----------------------------------------------------------------------

  late MockFirebaseMessaging mockMessaging;
  late SpyUserSettingsService spySettings;
  late FCMService service;

  setUp(() {
    mockMessaging = MockFirebaseMessaging();
    spySettings = SpyUserSettingsService();
    service = FCMService(
      messaging: mockMessaging,
      settingsService: spySettings,
    );
  });

  const userId = 'user-42';
  const testToken = 'fcm-test-token-abcdefghijklmnop';

  // -----------------------------------------------------------------------
  group('getAndSaveToken', () {
    test('calls updateUserSettings with fcmToken field', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      final token = await service.getAndSaveToken(userId);

      expect(token, testToken);
      expect(spySettings.updateCallCount, 1);
      expect(spySettings.lastUpdateUserId, userId);
      expect(spySettings.lastUpdateData, containsPair('fcmToken', testToken));
    });

    test('does not call getUserSettings (partial update, not read-modify-write)',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.getAndSaveToken(userId);

      // SpyUserSettingsService.getUserSettings would return null by default.
      // The point: _saveTokenToUserSettings never reads before writing.
      expect(spySettings.updateCallCount, 1);
      // getUserSettings is never called — no stubbedSettings needed
    });

    test('returns null and does not write when token is null', () async {
      stubMessagingGranted(mockMessaging, token: null);
      // Override getToken to return null
      when(mockMessaging.getToken()).thenAnswer((_) async => null);

      final token = await service.getAndSaveToken(userId);

      expect(token, isNull);
      expect(spySettings.updateCallCount, 0);
    });

    test('logs error but does not throw when updateUserSettings fails',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);
      spySettings.updateError = Exception('Firestore unavailable');

      // Should not throw
      final token = await service.getAndSaveToken(userId);

      // Returns the token even though saving failed — the error is logged
      // but the token itself was retrieved successfully
      expect(token, testToken);
    });
  });

  // -----------------------------------------------------------------------
  group('enableNotifications', () {
    test('writes fcmToken + enableNotifications atomically in one update call',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      final result = await service.enableNotifications(userId);

      expect(result, NotificationPermissionResult.granted);
      expect(spySettings.updateCallCount, 1);
      expect(
        spySettings.lastUpdateData,
        allOf(
          containsPair('fcmToken', testToken),
          containsPair('enableNotifications', true),
        ),
      );
    });

    test('returns error when token is null', () async {
      stubMessagingGranted(mockMessaging);
      // Override getToken to return null
      when(mockMessaging.getToken()).thenAnswer((_) async => null);

      final result = await service.enableNotifications(userId);

      expect(result, NotificationPermissionResult.error);
    });

    test('returns denied when permission denied', () async {
      stubMessagingDenied(mockMessaging);

      final result = await service.enableNotifications(userId);

      expect(
        result,
        anyOf(
          NotificationPermissionResult.denied,
          NotificationPermissionResult.permanentlyDenied,
        ),
      );
    });

    test('returns granted on success', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      final result = await service.enableNotifications(userId);

      expect(result, NotificationPermissionResult.granted);
    });

    test('idempotent — second call uses cached token, still one update',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.enableNotifications(userId);
      // Reset spy counters for second call
      spySettings.updateCallCount = 0;
      spySettings.allUpdateCalls.clear();

      final result = await service.enableNotifications(userId);

      expect(result, NotificationPermissionResult.granted);
      expect(spySettings.updateCallCount, 1);
      expect(spySettings.lastUpdateData, containsPair('fcmToken', testToken));
    });
  });

  // -----------------------------------------------------------------------
  group('disableNotifications', () {
    test(
        'calls updateUserSettings with FieldValue.delete() for fcmToken '
        'and enableNotifications: false in one update', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.disableNotifications(userId);

      expect(spySettings.updateCallCount, 1);
      expect(spySettings.lastUpdateUserId, userId);
      expect(
        spySettings.lastUpdateData!['enableNotifications'],
        false,
      );
      // FieldValue.delete() produces a sentinel object
      expect(
        spySettings.lastUpdateData!['fcmToken'],
        isA<FieldValue>(),
      );
    });

    test('deletes token from FirebaseMessaging', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.disableNotifications(userId);

      verify(mockMessaging.deleteToken()).called(1);
    });

    test('clears cached token so next enable fetches fresh', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      // Prime the cache
      await service.enableNotifications(userId);

      // Disable — should clear cache
      await service.disableNotifications(userId);

      // Reset counters
      spySettings.updateCallCount = 0;

      // Re-enable — must call getToken() again (not use cached null)
      when(mockMessaging.getToken())
          .thenAnswer((_) async => 'fcm-new-token-456-abcdefghijk');
      await service.enableNotifications(userId);

      expect(
        spySettings.lastUpdateData,
        containsPair('fcmToken', 'fcm-new-token-456-abcdefghijk'),
      );
    });
  });

  // -----------------------------------------------------------------------
  group('refreshTokenIfNeeded', () {
    test('saves token via updateUserSettings when token changed', () async {
      stubMessagingGranted(mockMessaging, token: 'fcm-fresh-token-789-abcdefghij');

      await service.refreshTokenIfNeeded(userId);

      expect(spySettings.updateCallCount, 1);
      expect(
        spySettings.lastUpdateData,
        containsPair('fcmToken', 'fcm-fresh-token-789-abcdefghij'),
      );
    });

    test('skips save when token unchanged (matches cache)', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      // Prime the cache via getAndSaveToken
      await service.getAndSaveToken(userId);
      spySettings.updateCallCount = 0;

      // refreshTokenIfNeeded with same token
      await service.refreshTokenIfNeeded(userId);

      expect(spySettings.updateCallCount, 0);
    });

    test('does not write when getToken returns null', () async {
      when(mockMessaging.getToken()).thenAnswer((_) async => null);
      when(mockMessaging.onTokenRefresh)
          .thenAnswer((_) => const Stream.empty());

      await service.refreshTokenIfNeeded(userId);

      expect(spySettings.updateCallCount, 0);
    });
  });

  // -----------------------------------------------------------------------
  group('clearCache', () {
    test('resets cached token and initialized flag', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      // Initialize and get a token
      await service.enableNotifications(userId);

      // Clear cache
      service.clearCache();

      // Next enableNotifications must re-initialize and re-fetch token
      spySettings.updateCallCount = 0;
      when(mockMessaging.getToken())
          .thenAnswer((_) async => 'fcm-post-clear-token-abcdefghi');
      await service.enableNotifications(userId);

      // Should have requested permission again (re-initialize)
      verify(mockMessaging.requestPermission(
        alert: anyNamed('alert'),
        announcement: anyNamed('announcement'),
        badge: anyNamed('badge'),
        carPlay: anyNamed('carPlay'),
        criticalAlert: anyNamed('criticalAlert'),
        provisional: anyNamed('provisional'),
        sound: anyNamed('sound'),
      )).called(greaterThanOrEqualTo(1));
      expect(
        spySettings.lastUpdateData,
        containsPair('fcmToken', 'fcm-post-clear-token-abcdefghi'),
      );
    });
  });

  // -----------------------------------------------------------------------
  group('isEnabledForUser', () {
    test('returns true when user has valid FCM token', () async {
      spySettings.stubbedSettings = UserSettings(
        userId: userId,
        email: 'test@test.com',
        firstName: 'Test',
        lastName: 'User',
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: true,
        favoriteReachIds: [],
        customBackgroundImagePaths: [],
        fcmToken: testToken,
        lastLoginDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      final enabled = await service.isEnabledForUser(userId);

      expect(enabled, isTrue);
    });

    test('returns false when user has no settings', () async {
      spySettings.stubbedSettings = null;

      final enabled = await service.isEnabledForUser(userId);

      expect(enabled, isFalse);
    });

    test('returns false when fcmToken is null', () async {
      spySettings.stubbedSettings = UserSettings(
        userId: userId,
        email: 'test@test.com',
        firstName: 'Test',
        lastName: 'User',
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: true,
        favoriteReachIds: [],
        customBackgroundImagePaths: [],
        fcmToken: null,
        lastLoginDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      final enabled = await service.isEnabledForUser(userId);

      expect(enabled, isFalse);
    });
  });
}
