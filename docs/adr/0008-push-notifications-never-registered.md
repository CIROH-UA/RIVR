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
| FCM outcome | `📲 Weekly digest sent to tOJIDsbkqgcNF03rXF1TVVchUI52` |

The first FCM token RIVR has ever issued to a real device, after roughly six
months in which `notification_logs` stayed empty and 17 of 18 users had none.

Tap routing is also measured, not assumed: the digest sends
`data: {type: "weekly_outlook"}`, `notificationRoute` maps that to
`AppRoutes.weeklyOutlook`, and 6 tests cover it including precedence over a
`reachId` in the same payload.

## Still unverified

**Physical delivery to the lock screen.** FCM accepting a message is FCM taking
custody, not APNs presenting it. Only the device shows this. Cheapest test: look
at the phone. If it does not arrive, check the function logs for a per-token
rejection (`UNREGISTERED`, `SenderId mismatch`) — neither appeared on this run,
which is consistent with success without proving it.

**Flood alerts end to end.** Needs a favourited reach above its 2-year
threshold. All three of Jerson's are Normal, so silence there is correct
behaviour rather than a failure.

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
