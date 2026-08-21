# 0008 — Push notifications never registered a device

**Status:** Cause fixed in 2026.0.1+529; end-to-end delivery still unverified
**Found:** 2026-08-21, on the first real device RIVR has ever run on

## Symptom

Both notification toggles on, and the app's own DEVICE STATUS row reading
**"Device not registered"** in red.

## Measured

| | |
|---|---|
| users in Firestore | 18 |
| with a `fcmTokens` array | **0** |
| with the legacy `fcmToken` string | 1 (dates from the Feb 1.0.0 builds) |
| users with `enableNotifications: true` but no token | **4** |
| entries ever written to `notification_logs` | **0** |
| `aps-environment` in the shipped build 524 | **`development`** |
| Apple Distribution certs for HydroMap LLC | **none** — only Oqupa LLC's |

## Cause

No Apple Distribution certificate existed for HydroMap LLC, so `flutter build
ipa` had no distribution identity to re-sign with at export and fell back to the
development team provisioning profile. That profile carries
`aps-environment: development`.

Apple's **production** APNs refuses a registration from a build declaring the
development environment. `getAPNSToken()` therefore returns null forever;
`_ensureApnsReady()` polls 3 × 2s and gives up; `_getToken()` returns
`'pending'`; `_ensureRegistered()` writes no token **but still returns
`granted`**, so `enableNotifications: true` is persisted with nothing behind it.

That is the exact state of those four users, and it means **push notifications
have never worked in any shipped build of RIVR.**

## Disproven

The 2026-08-20 audit attributed the missing tokens to iOS simulators being
unable to obtain APNs tokens. That is true of simulators, and it was the wrong
explanation here — the same failure occurs on a real device with a development
entitlement. The error was reasoning from the code path instead of checking what
the binary was actually signed with.

## Fix

An Apple Distribution certificate for HydroMap LLC, created 2026-08-21. Release
also gets its own `RunnerRelease.entitlements` declaring `production`, so the
intent is explicit rather than inherited; Debug and Profile keep `development`.

**The entitlements split is not what flipped the value.** Export produced
`production` because a store profile became available once the certificate
existed. The file makes the Release intent legible; it did not fix anything on
its own.

## Inspect the IPA, never the archive

`flutter build ipa` re-signs during export, so the archive reports
`development` even when the shipped artifact is correct. This cost an hour:

```bash
unzip -q build/ios/ipa/RIVR.ipa -d /tmp/ipa && \
codesign -d --entitlements :- /tmp/ipa/Payload/Runner.app \
  | plutil -convert xml1 -o - - | grep -A1 aps-environment
```

Verified in build 529: `production`, iOS Team Store Provisioning Profile, signed
by Apple Distribution: HydroMap LLC.

## The second cause — nothing ever registered for remote notifications

529 shipped the production entitlement and **still failed**. The entitlement was
necessary and not sufficient.

`Info.plist` sets `FirebaseAppDelegateProxyEnabled=false`, so Firebase does not
swizzle the app delegate and will not register on the app's behalf. `AppDelegate`
implements `didRegisterForRemoteNotificationsWithDeviceToken` and assigns
`Messaging.apnsToken` correctly — but that callback only fires if registration
was **requested**, and nothing in the iOS project ever called
`registerForRemoteNotifications()`. The Dart `requestPermission()` asks the user;
it does not start APNs registration.

So permission was granted, registration never began, `apnsToken` stayed nil,
`getAPNSToken()` returned nil forever, the 6-second poll expired, and no token
was written. **Under no signing configuration could this app have obtained a
token.** Fixed in 2026.0.2+533 by calling it at launch — safe before permission
exists, since it only requests a device token and iOS shows nothing until
`requestPermission()` runs.

## Measured — registration and send both work (2026-08-21)

| | |
|---|---|
| DEVICE STATUS row | green, "Device registered" |
| `users/{uid}.fcmTokens` | **1 token**, written 17:39 UTC |
| weekly digest triggered manually | function ok in 21.7s |
| forecasts resolved | all 3 favourites — White, Provo, Dead River |
| FCM outcome | `📲 Weekly digest sent to <uid>` |

The first FCM token RIVR has ever issued to a real device, after roughly six
months in which `notification_logs` stayed empty and 17 of 18 users had none.

Tap routing was claimed here as "measured, not assumed". **That was wrong**, and
Jerson caught it: the digest arrived on build 547 and tapping it returned him to
whatever screen he last had open.

The payload, the mapping and the tests were all verified and all correct. The
integration was not. `AppDelegate.userNotificationCenter(didReceive:)` overrode
the tap handler, logged the payload and called `completionHandler()` itself,
never calling `super` — so with `FirebaseAppDelegateProxyEnabled=false` and
nothing to swizzle, FlutterFire never saw the tap, `onMessageOpenedApp` never
fired, and `notificationRoute` was never invoked.

Verifying every component and calling that an integration test is the same
mistake this ADR documents at every other layer. Fixed by forwarding to `super`.

**Unverified:** the sibling `willPresent` handler also does not forward, which is
defensible — it deliberately overrides presentation options so notifications show
while the app is open — but it means FlutterFire may not emit `onMessage` in the
foreground. Cheapest test: trigger a digest with the app open and see whether the
banner appears once, twice, or not at all.

## Still unverified

**Physical delivery to the lock screen.** FCM accepting a message is FCM taking
custody, not APNs presenting it. Only the device shows this. Cheapest test: look
at the phone. If it does not arrive, check the function logs for a per-token
rejection (`UNREGISTERED`, `SenderId mismatch`) — neither appeared on this run,
which is consistent with success without proving it.

**Flood alerts end to end.** Needs a favourited reach above its 2-year
threshold. All three of Jerson's are Normal, so silence there is correct
behaviour rather than a failure.

## All five follow-ups are now done (2026-08-21)

Items 1-4 shipped as phase 4 of ADR 0009; item 5 became the `aps-environment`
verification step in the release flow. The original list is kept below for the
record.

## Build 551 send — what is and is not established (2026-08-21)

**Measured.** The digest re-fired at 22:34 reached FCM for both registered
tokens: `📲 Weekly digest sent`, no send-failure logged, and
`weeklyDigestsSinceOpen` moved 0 → 1, which only happens after `sendDigest`
returns true. Both tokens then validated live under `validate_only` dry-runs,
stable across three passes.

*Anomaly, unexplained:* the very first dry-run pass returned
`NOT_FOUND / NotRegistered` for one of the two registered tokens, which then
validated on all four subsequent attempts. The first loop also produced one
result where two were expected, so it may simply have been a broken shell loop
rather than an FCM signal. Recorded rather than dismissed.

**Measured — the routing map is intact end to end, statically.** The server
sends `data: {type: "weekly_outlook"}` (`weekly-digest.ts`); `notificationRoute()`
in `fcm_service.dart:26` maps exactly that to `AppRoutes.weeklyOutlook`; and
`_handleNotificationTap` is subscribed to both `onMessageOpenedApp` and
`getInitialMessage` (`fcm_service.dart:95-100`). Every link was read at both
ends.

**Unverified — the one hop that matters.** Whether the notification appears on
screen, and whether the tap now reaches FlutterFire at all, cannot be settled
from this machine. That hop is `AppDelegate.userNotificationCenter(didReceive:)`
forwarding to `super` — the exact line build 551 changed, and the reason the
static chain above proved nothing the first time. **Cheapest test: tap the
notification.** This is the same error class the ADR opens with: four layers
reporting success while nothing was delivered.

**Both tokens are live**, so two devices will each receive the digest.

## Build 551 tap test — still lands on the home page (2026-08-21)

**Measured, from device screenshots.** The notification rendered correctly on
the lock screen — "Your rivers this week / White River peaks 48,007 CFS Sun.
3 of 3 rising this week." Tapping it from a cold start opened RIVR on the
**Favorites page**, not the Weekly Outlook page.

So delivery and presentation are now proven end to end, and the `super` fix in
551 is **not sufficient**. Two candidates remain, and the static chain cannot
separate them:

1. The tap still never reaches Flutter, so `getInitialMessage()` returns null.
2. The tap routes correctly, but the pushed route is discarded during startup.
   `_RivrAppState._initializeServices` calls
   `setState(() => _hasSeenOnboarding = seen)` after an async load, which swaps
   `CupertinoApp.home`, and `AuthCoordinator` swaps its child again once auth
   resolves. `setupNotificationListeners()` is only reached *after* settings
   load, so the push lands in the middle of that sequence.

**Discriminating test (no device logs needed, phone was not connected):** tap a
digest with the app already **backgrounded**. That path uses
`onMessageOpenedApp` and skips the launch rebuild entirely. Working warm but not
cold isolates candidate 2; failing both isolates candidate 1.

**Result: the warm tap failed too.** So candidate 2 (the startup rebuild
discarding a pushed route) is largely ruled out, and the tap is not reaching
Dart at all.

### What the source says, and why it is not enough

Every link was checked and every link looks correct:

- `FlutterAppDelegate` conforms to `FlutterAppLifeCycleProvider`, which inherits
  `UNUserNotificationCenterDelegate` (`FlutterPlugin.h:521`) — this is what lets
  our `override` + `super` compile at all.
- Both `-[FlutterAppDelegate userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:]`
  and the `FlutterPluginAppLifeCycleDelegate` counterpart exist in the engine
  binary (confirmed with `nm` against `Flutter.framework`), so `super` does have
  somewhere to forward to.
- `FLTFirebaseMessagingPlugin` calls `[_registrar addApplicationDelegate:self]`
  and implements the selector at line 364.
- With our delegate set, the plugin takes the `shouldReplaceDelegate = NO`
  branch, because our AppDelegate conforms to `FlutterAppLifeCycleProvider`, and
  relies entirely on that forwarding chain.

So reading cannot separate the remaining candidates, and this ADR's whole
history is of chains that look right and do not run.

**Leading hypothesis, NOT yet measured.** `AppDelegate` sets
`UNUserNotificationCenter.current().delegate = self` in
`didFinishLaunchingWithOptions`, but plugins register later against
`engineBridge.pluginRegistry` in `didInitializeImplicitFlutterEngine` (the
`FlutterImplicitEngineDelegate` path). If that registry's
`FlutterPluginAppLifeCycleDelegate` is not the same instance the AppDelegate
forwards to, `super` forwards into a lifecycle delegate with no plugins attached
and the tap is dropped. The plugin's own comment on that branch — *"only
executes if Firebase swizzling is enabled"* — suggests we are taking a path its
authors did not expect with `FirebaseAppDelegateProxyEnabled=false`.

**Candidate fix (unverified):** delete the delegate assignment. The plugin then
finds `notificationCenter.delegate == nil`, sets itself as the delegate, and iOS
calls it directly — no chain involved. Our two `UNUserNotificationCenter`
overrides become dead code. Foreground presentation is unaffected because the
Dart side already calls
`setForegroundNotificationPresentationOptions(alert:badge:sound:)`.

**Do not ship this on reasoning.** Next step is device logs over a cable, with
`flutter logs` capturing three prints that isolate each hop: `Notification
tapped:` (iOS → AppDelegate), `FcmService: Notification tapped` (plugin → Dart),
`Routing notification to` (route pushed).

## ROOT CAUSE — the plugin predates UIScene support (2026-08-21)

**Measured, and it is a version gap, not a wiring bug.**

| fact | value | source |
|---|---|---|
| `Info.plist` adopts UIScene | `UISceneDelegateClassName = FlutterSceneDelegate` | `PlistBuddy` on `ios/Runner/Info.plist` |
| `FirebaseAppDelegateProxyEnabled` | `false` | same |
| `firebase_messaging` in use | **16.0.3** | `pubspec.lock` |
| scene-delegate support added in | **16.1.0** | package CHANGELOG, [#17888](https://github.com/firebase/flutterfire/issues/17888) + [#17905](https://github.com/firebase/flutterfire/issues/17905) |
| latest available | 16.5.0 | pub.dev API |

`FLTFirebaseMessagingPlugin.m` in 16.5.0 implements `scene:willConnectToSession:`
and comments at line 373 that it exists to *"give
`scene:willConnectToSession:options:` a chance to provide the tapped
notification"*. **16.0.3 contains no `scene:` method at all.** Under the UIScene
lifecycle the tap arrives through the scene delegate, and the installed plugin
had nothing listening there — so the notification displayed correctly while the
Dart layer never heard about it.

This matches the symptom set exactly: APNs registration fine, banners fine,
`willPresent` firing, and `onMessageOpenedApp` / `getInitialMessage` silent.

**Confirmed independently upstream.** [flutter/flutter#185048](https://github.com/flutter/flutter/issues/185048)
reports the identical configuration — `FlutterImplicitEngineDelegate`,
`FirebaseAppDelegateProxyEnabled=false`, UIScene adopted — and the reporter
closed it with: *"I figured out the issue, I was using a version of firebase
messaging without scene delegate support."*

**Superseded:** the earlier "engine registry vs AppDelegate registry" hypothesis
and the proposed fix of deleting the `UNUserNotificationCenter` delegate
assignment. Both were plausible and both were wrong; the delegate assignment is
fine. Also **disproven**: that a dependency was hijacking the delegate —
`flutter_local_notifications` 18.0.1 never touches
`UNUserNotificationCenter.delegate`, it uses `addApplicationDelegate:` (checked
in its source).

**Fix applied:** `firebase_messaging` 16.0.3 → **16.5.0** (`firebase_core`
4.2.0 → 4.13.0). `AppDelegate.swift` deliberately left untouched, so the next
device test measures one variable.

Two collateral bumps were required, neither optional:
- generated mocks regenerated — `MockFirebaseMessaging.getToken` no longer
  matched the new signature and `flutter analyze` failed;
- `fake_cloud_firestore` 4.1.1 → 4.2.0 — `cloud_firestore` moved to 6.8.0, whose
  `WriteBatch.update<T>` is generic, and the old fake failed to compile.

866 tests green, `flutter analyze` clean apart from a pre-existing `onReorder`
deprecation.

**Still unverified: that this actually fixes the tap.** The version gap explains
every observed symptom and is confirmed upstream, but nothing has been run on a
device. Test: install the next build, tap a digest, expect the Weekly Outlook
page — cold and backgrounded.

### Verifying the new plugin actually shipped in the IPA

Worth recording because the first attempt was a false positive. Grepping the app
binary for `scene:willConnectToSession:options:` returns a hit — but it returns
the same hit in **build 551**, which carried the old plugin. That string comes
from the Flutter engine's own `FlutterSceneDelegate`, so it proves nothing about
firebase_messaging.

The discriminating test is a differential on selectors that exist **only** in
16.5.0's `FLTFirebaseMessagingPlugin.m` (obtained by diffing the method lists of
the two versions in `~/.pub-cache`):

| selector | 551 | 555 |
|---|---|---|
| `configureNotificationCenterDelegate` | 0 | 1 |
| `markInitialNotificationGatheredAfterDelay` | 0 | 1 |
| `setupNotificationHandlingWithRemoteNotification:` | 0 | 2 |
| `configureWithFlutterMethodChannel:` | 0 | 1 |

`nm` is useless here — release builds are stripped and obfuscated, so symbol
tables are empty and `strings` is the only route in.

Same lesson as "inspect the IPA, never the archive": a check that passes on both
the fixed and the broken artifact is not a check.

## Latent: a weekly-only user never gets tap routing at all

**Measured.** `AuthProvider._loadUserSettings` (`auth_provider.dart:155`) gates
`setupNotificationListeners()` behind `enableNotifications == true` — the
**Flood Alerts** flag. `weeklyOutlookEnabled` is not consulted.

A user who turns on only the Weekly Outlook therefore receives the digest (the
server checks `weeklyOutlookEnabled`) but never installs `onMessageOpenedApp` or
`getInitialMessage`, so no tap can ever route. Not the cause of the failure
above — this account has both flags true, verified in Firestore — but it is the
same class of defect and will bite the first weekly-only user.

The gate should be `enableNotifications || weeklyOutlookEnabled`.

## The back-off counter and the tap bug compound each other

**Measured.** A digest fired at 22:27 sent nothing: `📬 0/1 due this week`. The
account's `weeklyDigestsSinceOpen` had reached exactly 4, which
`isDueThisWeek()` treats as the biweekly threshold.

The counter is incremented on every send and reset **only when the app opens the
Weekly Outlook page**. Since the tap never arrived at that page, every test send
today ratcheted it upward with no route back. A user who taps digests but never
lands on the page is therefore indistinguishable from one ignoring them, and
gets backed off to biweekly and then monthly for engaging normally. The tap fix
is what closes the loop, because reaching the page is the reset.

Counter manually reset to 0 to unblock testing.

## New defect found while verifying — stale-token pruning is a no-op

**Measured.** `FieldValue.arrayRemove` is varargs —
`static arrayRemove(...elements: any[])` — but both call sites pass a single
array:

- `functions/src/weekly-digest.ts:348`
- `functions/src/notification-service.ts:566`

So they ask Firestore to remove one element that *is* the array, which never
matches. Dead tokens are never pruned; the array grows and every send retries
them forever. Fix is `arrayRemove(...staleTokens)`.

Worse, this is silent in the same way as everything else in this ADR: the prune
is wrapped in a try/catch that only logs on throw, and a no-op does not throw.
The "if every token is dead, disable the digest" branch is also unreachable in
effect, since the tokens it counts are never actually removed.

Not yet fixed — it is a server-side change and does not block build 551.

## Worth fixing regardless of the above

1. `_ensureRegistered` returns `granted` when the token is `'pending'`, so the
   caller writes `enableNotifications: true` for a device that cannot receive
   anything. The UI then has to explain a state the service reported as success.
2. `_saveTokenToUserSettings` swallows write failures, making a failed write
   indistinguishable from the pending case.
3. Token rotation does `arrayRemove(old)` then `arrayUnion(new)` as separate
   writes; if the second fails the user loses their only token.
4. `getAndSaveToken` has no callers.
5. Add an `aps-environment` gate to `make release-ios` so a development
   entitlement can never ship again.
