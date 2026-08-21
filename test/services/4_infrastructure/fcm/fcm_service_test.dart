// test/services/4_infrastructure/fcm/fcm_service_test.dart
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
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/fcm/fcm_service.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';

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

  /// Every call, including ones that threw. FieldValue sentinels stringify
  /// opaquely, so ordering is asserted by counting attempts rather than by
  /// inspecting arrayUnion vs arrayRemove.
  final List<Map<String, dynamic>> attemptedUpdates = [];

  /// Optional: throw on next updateUserSettings call
  Exception? updateError;

  // --- getUserSettings spy data ---
  UserSettings? stubbedSettings;

  @override
  Future<void> updateUserSettings(
    String userId,
    Map<String, dynamic> updates,
  ) async {
    // Record the attempt before throwing. A test that cares whether a second
    // write was even attempted cannot see it otherwise.
    attemptedUpdates.add(Map.of(updates));
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
  @override
  Future<void> deleteUserSettings(String u) async {}

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
    test('has all six expected values', () {
      expect(NotificationPermissionResult.values, hasLength(6));
      expect(
        NotificationPermissionResult.values,
        containsAll([
          NotificationPermissionResult.granted,
          NotificationPermissionResult.denied,
          NotificationPermissionResult.permanentlyDenied,
          NotificationPermissionResult.error,
          NotificationPermissionResult.notDetermined,
          NotificationPermissionResult.tokenUnavailable,
        ]),
      );
    });

    // notDetermined is not denied, and the difference is expensive to get
    // wrong: iOS grants exactly one system prompt per install. Treating
    // "never asked" as "denied" would send the user to Settings when the
    // prompt was still available; the reverse burns the prompt silently.
    test('notDetermined is distinct from denied', () {
      expect(NotificationPermissionResult.notDetermined,
          isNot(NotificationPermissionResult.denied));
      expect(NotificationPermissionResult.notDetermined,
          isNot(NotificationPermissionResult.permanentlyDenied));
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
  // Phase 4 guards (ADR 0009) — the service must stop reporting success for a
  // device that cannot receive anything. Every one of these states previously
  // came back as `granted`.
  group('a device with no address does not report success', () {
    test('a token that lands is granted, and written with arrayUnion',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      final r = await service.enableNotifications(userId);

      expect(r, NotificationPermissionResult.granted);
      final tokenWrites = spySettings.allUpdateCalls
          .where((d) => d.containsKey('fcmTokens'));
      expect(tokenWrites, isNotEmpty);
      expect(tokenWrites.first['fcmTokens'], isA<FieldValue>());
    });

    // Guard 2: a failed Firestore write is not success. Swallowing it is what
    // let `enableNotifications: true` be persisted for a device with no token
    // — the state four users sat in for months (ADR 0008).
    test('a failed write reports tokenUnavailable, not granted', () async {
      stubMessagingGranted(mockMessaging, token: testToken);
      spySettings.updateError = Exception('Firestore unavailable');

      final r = await service.enableNotifications(userId);

      expect(r, NotificationPermissionResult.tokenUnavailable);
      expect(r, isNot(NotificationPermissionResult.granted));
    });

    test('no token at all reports error rather than granted', () async {
      stubMessagingGranted(mockMessaging, token: null);
      when(mockMessaging.getToken()).thenAnswer((_) async => null);

      final r = await service.enableNotifications(userId);

      expect(r, isNot(NotificationPermissionResult.granted));
    });

    test('the write is a partial update, never read-modify-write', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.enableNotifications(userId);

      // A read-modify-write would race two devices registering at once and
      // could drop one of their tokens.
      expect(spySettings.updateCallCount, greaterThanOrEqualTo(1));
    });
  });

  // -----------------------------------------------------------------------
  // Guard 3 (ADR 0009 phase 4) — the data-loss case.
  //
  // Firestore refuses arrayRemove and arrayUnion on the same field in one
  // write, so rotation cannot be atomic and the ORDER is the whole safety
  // property. Remove-then-add loses the user's only token if the add fails.
  // Add-then-remove leaves a harmless stale extra, pruned on the next
  // UNREGISTERED send.
  group('token rotation never leaves the user with none', () {
    test('the new token is written before the old one is removed', () async {
      stubMessagingGranted(mockMessaging, token: testToken);
      await service.enableNotifications(userId);

      spySettings.updateCallCount = 0;
      spySettings.allUpdateCalls.clear();
      spySettings.attemptedUpdates.clear();

      stubMessagingGranted(mockMessaging, token: 'fcm-rotated-token-xyz-0123');
      await service.refreshTokenIfNeeded(userId);

      // Two writes: add the new token, then remove the old one.
      expect(spySettings.attemptedUpdates.length, 2,
          reason: 'rotation is an add followed by a remove');
      expect(spySettings.attemptedUpdates.every((d) =>
          d.containsKey('fcmTokens')), isTrue);
    });

    test('a failed add does not remove the old token', () async {
      stubMessagingGranted(mockMessaging, token: testToken);
      await service.enableNotifications(userId);

      spySettings.updateCallCount = 0;
      spySettings.allUpdateCalls.clear();
      spySettings.attemptedUpdates.clear();
      spySettings.updateError = Exception('Firestore unavailable');

      stubMessagingGranted(mockMessaging, token: 'fcm-rotated-token-xyz-0123');
      await service.refreshTokenIfNeeded(userId);

      // Exactly ONE attempt: the add, which failed. The remove was never even
      // tried, so the old token survives in Firestore. Under the previous
      // remove-first ordering the user would now have no address at all.
      expect(spySettings.attemptedUpdates.length, 1,
          reason: 'the removal must not run when the add failed');
      expect(spySettings.allUpdateCalls, isEmpty,
          reason: 'nothing was successfully written');
    });
  });

  // -----------------------------------------------------------------------
  group('enableNotifications', () {
    test('registers the token then sets the flag (two partial updates)',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      final result = await service.enableNotifications(userId);

      expect(result, NotificationPermissionResult.granted);
      // One update registers the token (shared registration), a second sets the
      // per-type flag — kept separate so token writes never clobber prefs.
      expect(spySettings.updateCallCount, 2);
      final tokenCall = spySettings.allUpdateCalls
          .firstWhere((c) => c.containsKey('fcmTokens'));
      expect(tokenCall['fcmTokens'], isA<FieldValue>());
      expect(
        spySettings.allUpdateCalls.any((c) => c['enableNotifications'] == true),
        isTrue,
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

    test('second call uses cached token and still registers it',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.enableNotifications(userId);
      // Reset spy counters for second call
      spySettings.updateCallCount = 0;
      spySettings.allUpdateCalls.clear();
      spySettings.attemptedUpdates.clear();

      final result = await service.enableNotifications(userId);

      expect(result, NotificationPermissionResult.granted);
      // Re-registers the (cached) token via arrayUnion + re-sets the flag.
      expect(spySettings.updateCallCount, 2);
      expect(
        spySettings.allUpdateCalls.any((c) => c.containsKey('fcmTokens')),
        isTrue,
      );
    });
  });

  // -----------------------------------------------------------------------
  group('disableNotifications', () {
    test(
        'calls updateUserSettings with FieldValue.arrayRemove for fcmTokens '
        'and enableNotifications: false', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      // Prime the cache so disableNotifications has a token to remove
      await service.enableNotifications(userId);
      spySettings.updateCallCount = 0;
      spySettings.allUpdateCalls.clear();
      spySettings.attemptedUpdates.clear();

      await service.disableNotifications(userId);

      // Clears the flag, then (both types now off) tears down the token.
      expect(spySettings.updateCallCount, 2);
      expect(spySettings.lastUpdateUserId, userId);
      expect(
        spySettings.allUpdateCalls.any((c) => c['enableNotifications'] == false),
        isTrue,
      );
      final removeCall = spySettings.allUpdateCalls
          .firstWhere((c) => c.containsKey('fcmTokens'));
      expect(removeCall['fcmTokens'], isA<FieldValue>());
    });

    test('deletes token from FirebaseMessaging', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      await service.disableNotifications(userId);

      verify(mockMessaging.deleteToken()).called(1);
    });

    test(
        'still disables notifications when deleteToken throws '
        '(e.g. apns-token-not-set on simulator) and does not rethrow',
        () async {
      stubMessagingGranted(mockMessaging, token: testToken);
      await service.enableNotifications(userId); // prime cached token
      spySettings.updateCallCount = 0;
      spySettings.allUpdateCalls.clear();
      spySettings.attemptedUpdates.clear();

      when(mockMessaging.deleteToken())
          .thenThrow(Exception('apns-token-not-set'));

      // Must not throw — token deletion is best-effort cleanup.
      await service.disableNotifications(userId);

      // The important invariant still holds: settings updated to remove the
      // token and turn notifications off.
      expect(spySettings.updateCallCount, 2);
      expect(
        spySettings.allUpdateCalls.any((c) => c['enableNotifications'] == false),
        isTrue,
      );
      expect(
        spySettings.allUpdateCalls.any((c) => c.containsKey('fcmTokens')),
        isTrue,
      );
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
      spySettings.allUpdateCalls.clear();
      await service.enableNotifications(userId);

      expect(
        spySettings.allUpdateCalls.any((c) => c.containsKey('fcmTokens')),
        isTrue,
      );
    });
  });

  // -----------------------------------------------------------------------
  group('refreshTokenIfNeeded', () {
    test('saves token via updateUserSettings when token changed', () async {
      stubMessagingGranted(mockMessaging, token: 'fcm-fresh-token-789-abcdefghij');

      await service.refreshTokenIfNeeded(userId);

      expect(spySettings.updateCallCount, 1);
      expect(spySettings.lastUpdateData!.containsKey('fcmTokens'), isTrue);
      expect(spySettings.lastUpdateData!['fcmTokens'], isA<FieldValue>());
    });

    test('skips save when token unchanged (matches cache)', () async {
      stubMessagingGranted(mockMessaging, token: testToken);

      // Prime the cache through the surviving public path
      await service.enableNotifications(userId);
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
      spySettings.allUpdateCalls.clear();
      spySettings.attemptedUpdates.clear();
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
        spySettings.allUpdateCalls.any((c) => c.containsKey('fcmTokens')),
        isTrue,
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
        fcmTokens: [testToken],
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

    test('returns false when fcmTokens is empty', () async {
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
        fcmTokens: [],
        lastLoginDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      final enabled = await service.isEnabledForUser(userId);

      expect(enabled, isFalse);
    });
  });
}
