# Integration-test triage

Status as of 2026-07-10 (`chore/integration-test-triage`): **36 pass / 0 fail** — the full
integration suite is green on device.

| Suite | Result |
|-------|--------|
| `app_test.dart` | 1/1 |
| `auth_flow_test.dart` | 12/12 |
| `favorites_flow_test.dart` | 11/11 |
| `forecast_flow_test.dart` | 9/9 |
| `settings_flow_test.dart` | 3/3 |

## How to run

These are device integration tests — they need a running simulator/device and must be
launched per file (not via plain `flutter test`, which skips `integration_test/`):

```bash
flutter test test/integration_test/<file>.dart -d <device-udid>
```

The whole suite is fast (each file is seconds); run per-file when iterating.

## What got fixed on 2026-07-10 (cleared the residual 9)

All remaining failures were **test-harness debt** — none masked a product bug.

1. **Harness didn't provide `ConnectivityProvider` + didn't mock `connectivity_plus`** —
   caused `ProviderNotFoundException` / `MissingPluginException` across favorites. Added the
   provider and a `_FakeConnectivityPlatform` (MockPlatformInterfaceMixin) in
   `helpers/test_app.dart`. (commit on this branch)
2. **Coach-mark tour was active in tests** — `CoachMarkService.hasSeenFavoritesTour()` returned
   false because SharedPreferences wasn't seeded, so `favorites_page.dart` attached anchor
   GlobalKeys AND the coach-mark overlay reused the same keys → duplicate-GlobalKey crash. Fixed
   by seeding `has_seen_favorites_tour`/`has_seen_search_tip` = true in `buildTestApp`.
3. **Test app only wired `onGenerateRoute`, not `AppRouter.namedRoutes`** — so `pushNamed('/account')`
   fell through to the page-not-found default and the Account page never rendered. Added
   `routes: AppRouter.namedRoutes` + `onUnknownRoute` to the test `CupertinoApp`. Fixed
   "Account row navigates to the Account page".
4. **Forecast loading assertion was stale** — the initial loading state was reworked from a
   spinner + "Loading river overview..." text to a `Shimmer` skeleton. Updated the assertion to
   `find.byType(Shimmer)`.
5. **`MockFCMService.enableNotifications` didn't persist the settings flag** — the real FCMService
   writes `enableNotifications` to Firestore, so the page's post-toggle `getUserSettings()` re-read
   reflects it. The mock returned `granted` but wrote nothing, so the MONITORING section never
   appeared after toggling. Wired the FCM mock to the user-settings mock so enable/disable persist
   the flag (`TestServices` constructor sets `fcm.userSettings = userSettings`).

## History

- 2026-05-19: 23 pass / 9 fail (was 9 / 27). Root-caused the auth-flow blocker
  (`FirebaseCrashlytics.setUserIdentifier` crashing without Firebase init → `_setCrashlyticsUserSafe()`),
  and rewrote the stale dropdown-shape settings-menu tests.
- 2026-07-10: cleared the residual 9 (above). Suite fully green.
