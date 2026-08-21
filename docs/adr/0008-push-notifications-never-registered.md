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

## Unverified

**Whether a token is now actually issued on device.** The known blocker is gone,
but nothing has demonstrated a successful registration. Cheapest test: install
529, open notification settings, and read the DEVICE STATUS row — it is a direct
readout of `UserSettings.fcmTokens` (`hasToken && !isPending` → green "Device
registered"), so green means a token reached Firestore. Confirm with a query
against `users/{uid}.fcmTokens`.

**Whether a notification is then delivered.** Separate from registration, and
needs a favourited reach above its 2-year threshold, or a manual invoke of
`triggerAlertCheck` / the weekly digest topic.

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
