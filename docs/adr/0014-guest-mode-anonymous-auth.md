# ADR 0014 — Guest mode: let people use RIVR before they have an account

**Status:** Proposed (2026-09-21)
**Trigger:** App Store rejection of 2026.2.2 (805), Guideline 5.1.1(v),
2026-09-21: *"The app requires users to register before accessing map. Apps
may not require users to enter personal information to function, except when
directly relevant to the core functionality of the app or required by law."*
Review device: iPad Air 11-inch (M3), even though the build is iPhone-only —
iPhone apps are reviewed in iPad compatibility mode; nothing to do about it.

## The decision in one paragraph

On first launch the app signs the person in **anonymously** with Firebase Auth
and takes them straight to the app. Everything they can see today after
registering — the map, forecasts, favourites, flood alerts, the Weekly
Outlook — works against that anonymous identity, because every surface in the
app keys on a Firebase `uid` and the Firestore rules already admit any signed-in
uid. Creating an account later **links** an email and password to the same
uid, so nothing migrates. The one honest reason to create an account is the one
we tell them: *keep your rivers if you change phones.*

This is a small change to the app and a set of non-obvious obligations
elsewhere. This ADR exists to list the obligations, because none of them is
visible to a user after download and every one of them bites later.

## Out of scope — do not reopen here

- Sign in with Apple / Google. Not required while the app offers only
  email/password (App Store guideline 4.8 applies when a third-party login is
  offered — **Unverified**, read 4.8 before adding any social login).
- Removing the email-verification requirement for full accounts. It stays; the
  question here is only *when* it gates (see UX-4).
- The store kill switch, Remote Config, the flood tileset. Untouched.
- Keeping favourites on-device without any Firebase identity. Rejected below
  (Disproven section) — it would mean re-plumbing every service that reads a
  uid and forfeits alerts for guests.

---

## Findings

### Measured (read from source or the live project, 2026-09-21)

| # | Finding | Method |
|---|---|---|
| M1 | **Anonymous sign-in is not enabled** on the Firebase project. The Identity Toolkit config has no `signIn.anonymous` block; only `signIn.email` is enabled. | `GET identitytoolkit.googleapis.com/admin/v2/projects/ciroh-rivr-app/config` with the jersondevs token |
| M2 | All 22 Auth users are email/password; **zero anonymous users exist**, so there is no existing behaviour to preserve. | `accounts:batchGet`, counted `providerUserInfo` |
| M3 | Firestore rules admit any signed-in uid to its own document: `users/{userId}: allow read, write: if request.auth != null && request.auth.uid == userId`. No rule checks `email_verified` or the provider. **An anonymous uid passes unchanged.** | `firestore.rules` lines 8–35 |
| M4 | The app's **email-verification gate would lock a guest out**: `auth_provider.dart:135` sets `_isAwaitingEmailVerification` whenever `!firebaseUser.emailVerified`, and an anonymous user's `emailVerified` is always false. | `auth_provider.dart` 128–140, `auth_wrapper.dart` 42–52 |
| M5 | The `users/{uid}` document is created **only on the register path** (`auth_service.dart` ~line 100, `_createUserSettings`). Nothing creates it for a user who arrives by any other route. | `auth_service.dart` |
| M6 | Favourites are **fields on the user document** (`favoriteReachIds`, `favoriteSources`, custom names), not a subcollection. The Cloud Function `storeWriteThroughOnFavourite` fires on every write to `users/{userId}` and diffs `favoriteReachIds`. A guest favouriting a river therefore puts that reach into the shared store's refresh cycle exactly like an account does. | `favorites_service.dart` header, `functions/src/index.ts` 357–370 |
| M7 | Alerts enumerate `users` where `enableNotifications == true` and the Weekly Outlook where `weeklyOutlookEnabled == true`; neither filters on email or provider, so **guests receive alerts** with no further work. Notification copy falls back to `firstName || "User"`. | `notification-service.ts` 347–397, `weekly-digest.ts` 148 |
| M8 | Push tokens are stored on the user document as an `fcmTokens` array, keyed by uid only. | `fcm_service.dart` 317 |
| M9 | **Account deletion requires the password**: `deleteAccount({required String password})` re-authenticates with `EmailAuthProvider` before deleting. An anonymous user has no password, so the existing flow cannot delete a guest. | `auth_repository_impl.dart` 182–231 |
| M10 | **Sign Out for a guest is data loss.** `signOut()` signs out and clears biometric credentials; an anonymous uid that is signed out can never be signed back into — Firebase has no credential for it. The Account page offers Sign Out to every user today. | `auth_service.dart` 185–205, `account_page.dart` 164–197 |
| M11 | The only place the user agrees to the Terms and Privacy Policy is the **login page** footer ("By continuing, you agree to…"). A guest never sees the login page. | `login_page.dart:243` |
| M12 | Onboarding runs **before** auth (`main.dart:246` chooses `OnboardingPage` vs `AuthWrapper` on `hasSeenOnboarding`), so the onboarding screens are the natural place for the consent line and for the first notification/location explanation. | `main.dart` 133–248 |
| M13 | Only **four** files under `lib/services` and `lib/ui/1_state` read the current uid. The blast radius of "which uid" is small. | `grep -rl _currentUserIdOrNull\|currentUser?.uid\|currentUserId` |
| M15 | **The anonymous provider is now ENABLED** on ciroh-rivr-app (B1 done, 2026-09-21), via `PATCH …/config?updateMask=signIn.anonymous.enabled`. Read back as `{'enabled': True}`. | Identity Toolkit admin v2 |
| M16 | **The verification gate lived in TWO places, not one.** `AuthWrapper` showed the page, but `AuthProvider.isAuthenticated` was `_currentUser != null && !_isAwaitingEmailVerification` — so removing the wrapper branch alone left every unverified user un-authenticated and back at the login page. Found by an integration test hanging, not by review. | implementation, 2026-09-21 |
| M17 | **`firebase_auth_mocks`' `MockUser` defaults `isEmailVerified` to TRUE.** A guest fixture built without overriding it has `emailVerified == true`, which makes any test of the verification gate pass no matter what the gate does. Two guards were vacuous until the fixture was corrected; the mutation that should have failed them passed cleanly first time. | mutation check, 2026-09-21 |
| M18 | **The integration suite is GREEN at baseline** — 0 failures on `test/integration_test/` before this work. This DISPROVES the standing note (MEMORY.md, and `~27 long-standing pre-existing failures` in CLAUDE.md's test section) that the suite carries ~27 known failures. All 27 failures seen during this change were caused by it, and all 27 are now fixed. | `git stash` + `flutter test test/integration_test/`, 2026-09-22 |
| M14 | Firebase's **auto-delete of anonymous users is off** (`autoDeleteAnonymousUsers` absent from config). | same config read as M1 |

### Estimated

| # | Claim | Basis |
|---|---|---|
| E1 | The app-side change is **small**: sign in anonymously in `AuthProvider.initialize`, bypass the verification gate for `isAnonymous`, create the user doc on first anonymous sign-in, turn `register` into `linkWithCredential`, add a sign-in-from-guest merge, and guard Sign Out / Delete on the Account page. | M3, M4, M5, M9, M10, M13 — six touch points, all located |
| E2 | Orphaned guest documents will **accumulate cost in the store**, because every favourite on any user doc keeps its reach in `storeRefreshHourly` forever (M6). Magnitude is unknown until we know how many guests favourite and abandon; the driver is *reaches*, not users. | ADR 0011 refresh model; no install data yet |

### Unverified — nothing may be built on these

| # | Claim | Cheapest check |
|---|---|---|
| U1 | The anonymous uid **survives an iOS reinstall** (Firebase Auth stores state in the Keychain). If true, a reinstalled guest keeps their rivers; if false, they get a fresh uid and the old doc is orphaned. | Install a debug build on the simulator, favourite a river as guest, delete the app, reinstall, check the uid in the log |
| U2 | On Android the same uid may be **restored to a new device by Google backup**. *Measured:* the manifest sets neither `allowBackup` nor `dataExtractionRules` (0 matches), so the platform default applies. *Unverified:* what that default does to Firebase Auth's stored session on a restore; it could put one guest identity on two devices. | Test with `bmgr backupnow` / restore on the emulator, or set `allowBackup="false"` and remove the question |
| U3 | `linkWithCredential` on an anonymous user **keeps the uid and every Firestore document** with zero client work. This is Firebase's documented contract; we have not exercised it. | Unit test with `firebase_auth_mocks`, then one real run on the simulator, checking `uid` before and after |
| U4 | Apple's reviewer will accept favourites-and-alerts as "account-based features" that may still prompt for an account *if* the prompt is dismissable. The rejection text says the app "may still require registration for other features that are account based". | Only App Review can settle it; the design below makes the prompt dismissable so nothing is gated |
| U5 | App Store guideline 4.8 (Sign in with Apple) does not apply to email/password-only apps. | Read the current 4.8 text |

### Disproven

| # | Claim | Why |
|---|---|---|
| D1 | *"The app has no email-verification gate"* (asserted by the assistant 2026-09-07). It does: `auth_provider.dart:135`. Recorded in ADR form here because guest mode depends on it. | M4 |
| D4 | *"The integration_test suite has ~27 long-standing pre-existing failures"* (MEMORY.md; CLAUDE.md test section). Measured 2026-09-22 on a clean tree: **0 failures.** The note is stale and was masking real regressions — the 27 failures this change produced looked exactly like the number the note predicted, which is the worst possible coincidence for a stale claim to have. | M18 |
| D3 | *"The favourites empty state says nothing about the map"* (asserted in the first draft of this ADR, 2026-09-21). It says exactly the right thing; no copy change is needed. | `favorites_page.dart:456` |
| D2 | *"Keep guest favourites on-device only and skip Firebase entirely."* Rejected: every data surface, the store write-through, alerts and the Weekly Outlook key on a uid in Firestore (M6–M8). A device-only guest would get no alerts — the app's most important feature for a flood — and would need a migration step at sign-up. Anonymous auth gives the same result with the platform doing the work. | M6, M7, M8 |

---

## The spec — what has to exist that a user never sees

### Backend

**B1. Enable the Anonymous provider.** Firebase console → Authentication →
Sign-in method → Anonymous → Enable. Or `PATCH …/config` with
`{"signIn":{"anonymous":{"enabled":true}}}` and `updateMask=signIn.anonymous`.
Without this every `signInAnonymously` call fails with
`operation-not-allowed`, and the app must **fall back to the login page**, not
a blank screen (see UX-9).

**B2. Do not turn on Firebase's anonymous auto-delete.** It deletes the Auth
user after 30 idle days but leaves the Firestore document. The app would then
mint a fresh uid on next launch, the person would see an empty favourites
list, and the old document — still with `enableNotifications: true` and live
push tokens — would keep sending alerts nobody can turn off. Own the lifecycle
instead (B3).

**B3. Guest garbage collection — a new scheduled function, `guestGcDaily`.**
Deletes anonymous users (Auth *and* document) that have shown no sign of life
for N days. "Sign of life" must be something the app writes on every launch;
today nothing does, so add a `lastActiveAt` server timestamp written on app
start (client) or on token refresh. Proposed N = 90 days. Constraints:
- Must refuse a bulk delete, like `storeGcDaily` does (ADR 0011).
- Must remove the user's favourited reaches from the store's work list the
  same way an unfavourite does, or the reach lives on (M6, E2).
- Must skip any user with a `password` provider — never touch real accounts.
- Log the count at INFO every run so a runaway is visible.

**B4. Create the user document on first anonymous sign-in.** Today only
`register` does it (M5). Without a document, the first favourite write fails
the rules? No — the rules allow it — but `UserSettings` defaults, notification
flags and `createdAt` are never written, and every function that reads
`enableNotifications` sees `undefined`. Create it with `isGuest: true`,
`createdAt`, `lastActiveAt`, and the same defaults `register` uses.

**B5. Linking, not creating.** `register` becomes: build
`EmailAuthProvider.credential(email, password)` → `currentUser.linkWithCredential`
→ `updateDisplayName` → update the same document (`firstName`, `lastName`,
`email`, `isGuest: false`) → `sendEmailVerification`. The uid does not change
(U3 — verify). Error mapping that matters:
- `email-already-in-use` / `credential-already-in-use`: the person already
  has an account (typical: new phone). Offer **"Sign in instead"** and run the
  merge in B6.
- `requires-recent-login`: cannot happen for a link on a fresh anonymous
  session; log if seen.

**B6. Sign-in-from-guest merge.** When a guest signs into an existing
account, `signInWithEmailAndPassword` switches `currentUser` and the anonymous
uid is orphaned. Before switching: read the guest doc; after switching: union
its `favoriteReachIds`/`favoriteSources`/custom names into the account doc
(account's own values win on conflict), then delete the anonymous Auth user
and its document. Deleting an anonymous user needs no reauth. If the merge
fails midway, the guest doc must survive so it can be retried — write the
account first, delete the guest last.

**B7. Delete Account for guests.** Two flows on one button (M9):
- Anonymous: confirm → delete document, remove push tokens → `user.delete()`
  (no reauth) → sign in anonymously again so the app is not left signed out.
- Linked: unchanged (password reauth).

**B8. Cloud Functions expectations.** No query change is needed (M7). Two
copy points: notifications say "User" for guests (M7) — acceptable, or use
"Hi there". Alert copy that says "your account" must not.

**B9. Firestore rules — one addition.** Nothing needs loosening (M3). Add a
rule so a **linked** user cannot set `isGuest` back to true, and consider
denying `enableNotifications: true` writes when `fcmTokens` is empty — a
defensive rule, not a requirement.

**B10. Store write-through cost.** Each guest favourite enters the hourly
refresh cycle (M6). Keep the cap-per-user that exists for favourites; B3 is
the only thing that removes abandoned reaches. Watch `river_data` document
count weekly for the first month after release.

### UI/UX

**UX-1. Launch goes to the app.** `AuthWrapper`: if not signed in → sign in
anonymously → Favourites. Login/Register become destinations, not the gate.
The favourites empty state already teaches the right thing — "Tap the +
button below to explore the map and add your first river." (`favorites_page.dart:456`)
— so it stays. *(A draft of this ADR claimed it said nothing about the map;
that was wrong and is recorded in Disproven.)*

**UX-2. The Account page for a guest** shows: "You're using RIVR as a guest",
**Create an account** (primary), **Sign in** (secondary), **Delete my data**.
It must **not** show **Sign Out** — for a guest that is silent data loss
(M10). The unit label and the version label stay.

**UX-3. One dismissable prompt, at the first favourite.** After the first
successful favourite as a guest: a sheet — "Saved. Create an account to keep
your rivers if you change phones." with *Create account* / *Not now*. Shown
once per guest (flag on the doc, not on the device, so a reinstall that keeps
the uid (U1) does not repeat it). Never a blocking dialog. Alerts are **not**
gated on an account (M7 makes them work; U4 is why we do not gate).

**UX-4. Verification after linking must not lock people out.** Today the gate
throws any unverified user to `EmailVerificationPage` with no way past
(M4). A guest who just linked was using the app a second ago; sending them to
a wall is the 5.1.1(v) rejection again with extra steps. Proposal: for a
*linked* account, an unverified email shows a **banner on the Account page**
("Verify your email to enable password reset") with Resend, and gates
nothing. The full-page gate remains only for accounts created by the old
register path — i.e. it becomes dead code after one release and can be
removed then. **Decision for Jerson**, see below.

**UX-5. Consent moves to onboarding.** The "By continuing, you agree to our
Terms of Service and Privacy Policy" line (M11) goes on the last onboarding
screen's button, since that is now the only screen every user passes (M12).
Keep it on the login/register pages too.

**UX-6. Register page copy** stops saying "Create your account" as if it were
the first thing in the app and says what it does: "Keep your rivers on every
device". Fields unchanged (first name, last name, email, password).

**UX-7. Sign-in from guest** must explain the merge in one line before it
happens if the guest has favourites: "Your 3 saved rivers will be added to
your account." — and say nothing if they have none.

**UX-8. Biometric login** is only offered after an email sign-in today
(credentials stored on success). Guests never see it. After linking, offer it
the same way the login page does. Check that `BiometricDatasource` is not
consulted on an anonymous session (it would find nothing and should be a
no-op, not an error — **verify**).

**UX-9. Failure modes on first launch.** If anonymous sign-in fails (B1 not
enabled, offline, Firebase down): show the login page with a one-line notice,
never a spinner forever and never the map without a uid. Offline first launch
is the realistic case — the app cannot create a uid without the network, so
the onboarding's last screen should not promise "no account needed" in a way
that breaks offline; say "Continue" and handle the failure.

**UX-10. Existing users** with an email account see no change at all. Users
who registered but never verified are the only population that still hits
`EmailVerificationPage`; UX-4 decides whether they keep hitting it.

### Data lifecycle — the part nobody sees

| Event | What happens to the uid and the document |
|---|---|
| First launch | new anonymous uid; doc created (B4) with `isGuest: true`, `lastActiveAt` |
| Every launch | `lastActiveAt` refreshed (B3 depends on this) |
| Favourite | doc updated; store write-through fires (M6) |
| Create account | same uid, `isGuest: false`, name/email added (B5) |
| Sign in to existing account | account doc merged, guest doc + Auth user deleted (B6) |
| Delete my data (guest) | doc + Auth user deleted, fresh anonymous uid (B7) |
| Reinstall (iOS) | uid survives — **U1** — or a new guest is minted and the old doc waits for B3 |
| 90 days idle as guest | `guestGcDaily` deletes Auth user + doc, reaches leave the store (B3) |

### Verification plan — guards, each must fail before the fix

1. `AuthProvider` unit: an `isAnonymous` user is **not** awaiting verification
   (fails today, M4).
2. `AuthProvider` unit: first anonymous sign-in creates the user document with
   `isGuest: true` (fails today, M5).
3. `register` unit with `firebase_auth_mocks`: uid before == uid after linking
   (U3).
4. Merge unit: guest {A,B} + account {B,C} → account {A,B,C}, guest doc gone,
   account custom names win.
5. Account page widget: anonymous → no Sign Out button; linked → Sign Out
   present (fails today, M10).
6. Functions test: `guestGcDaily` refuses when more than X% of users qualify;
   never selects a user with a `password` provider.
7. Rules test (`@firebase/rules-unit-testing`): anonymous uid reads/writes
   its own doc, cannot read another; linked user cannot set `isGuest: true`.
8. **Device (simulator is enough for these):** fresh install → map opens
   without any prompt → favourite → prompt appears once → Create account →
   favourites still there → Delete app → reinstall → note whether the rivers
   survive (settles U1).
9. **Device, second run:** guest with 2 favourites → Sign in to
   `appreview@hydromap.com` → merge line shown → account now has both.
10. Play Console and App Store privacy answers re-read: nothing changes (guests
    collect no name/email; the types are still collected when someone creates
    an account).

### Rollout

- Version **2026.2.3**, both stores. Google gets it as an update to whatever
  805 becomes; Apple gets it as the resubmission with a reply that quotes
  5.1.1(v) back and states: map, forecasts, favourites and alerts work with no
  registration; an account is optional and only for multi-device sync.
- Reviewer notes gain one line: "No sign-in is required. The reviewer account
  is provided for the account-linking flow only."
- `app_releases.md` entry; `notifications_history.md` entry when
  `guestGcDaily` deploys.

---

## Decisions needed from Jerson

1. **UX-4 — verification gate for linked accounts:** banner-only (recommended)
   or keep the full-page gate.
2. **B3 — guest retention:** 90 days idle (recommended), or a different N.
3. **UX-3 — the one prompt:** at first favourite (recommended), or never — the
   Account page alone.

Everything else above is either measured or has a check attached, and is
proposed as written.

---

## Verification status (2026-09-22)

**Measured**

| What | How |
|---|---|
| The whole suite is green with the change in: **1,426 Dart tests** (baseline 1,404 — 22 added) and **468 Cloud Functions tests** (baseline 454 — 14 added). `flutter analyze` clean apart from one pre-existing deprecation. | `flutter test`, `npm --prefix functions test` |
| Every critical path is **mutation-checked** — reverting the behaviour fails a test: register-links-instead-of-creates; sign-in-merges-the-guest; the failed-sign-in restore; the verification gate on BOTH code paths; the Account page's guest branch; launch-opens-a-guest. | see the table in the guards section |
| **An existing signed-in account is unaffected.** A debug build of this branch launched on the iPhone 17 Pro simulator with a previously signed-in account and rendered its 7 favourites in 1,771 ms, with live flow values and the usual out-of-sync banner. | `flutter run`, 2026-09-22 |
| The anonymous provider is enabled on the project (M15). | admin v2 config read-back |

**Unverified — the guest path has NOT been exercised in a running app**

Nobody has yet watched the app open as a guest, save a river, see the prompt,
create an account and keep the river. The tests assert each step, and the
mutations prove the tests bite, but that is not the same thing and must not be
written up as if it were.

The blocker is this machine, not the code: **Xcode's `Simulator.app` and
`SimulatorKit.framework` are both absent** from
`/Applications/Xcode.app/Contents/Developer/`, so there is no simulator window
to drive and `idb ui tap` fails with *"SimulatorKit is required for HID
interactions"*. This contradicts `reference_sim_driving_setup` memory, which
records idb as working since 2026-07-24. Bypassing the onboarding gate by
writing `flutter.has_seen_onboarding` into the app's preferences — by
PlistBuddy and by `simctl spawn defaults write`, both confirmed written and
read back — did not take either, so `shared_preferences` is reading from
somewhere else on this Flutter version.

**The cheapest test that would settle it** is the one Apple will run anyway:
a TestFlight build on a real iPhone, fresh install, following ADR 0014's
guard 8. Either repair Xcode (`xcode-select --install`, or reinstall Xcode so
the Simulator ships with it) or verify on device.

---

## Device findings — build 832, 2026-09-22 (Jerson, iPhone)

The first real run of the guest path found three defects. All are **Measured**
— each was read out of Firebase Auth and Firestore, not inferred from the
report.

| # | Defect | Evidence | Fix |
|---|---|---|---|
| F1 | **A guest's saved rivers were destroyed by a failed sign-in.** The merge cleared `favoriteReachIds`, sources, labels and tokens BEFORE attempting the sign-in, and restored them only in a `catch`. The restore did not run. | `users/VpzNqmjM6IepuCtVanWpVLy3XtZ2` left with `mergePending: true`, `favoriteReachIds: []`, `updatedAt 16:02:14` — the exact neutralise fingerprint, never undone. Two real favourites lost and unrecoverable. | Nothing is written until the sign-in has succeeded: read, sign in, merge, delete. `_neutraliseGuestDoc`, `_restoreGuestDoc` and the `mergePending` flag are gone. |
| F2 | **Linking left the account marked as a guest.** After registration the document still had `isGuest: true`, `email: ''`, `firstName: ''`. | `users/PbgDw68JsdZCTNNgDRo38xjiE1k2` (created 16:07:03 as a guest, linked ~16:10) with the identity fields empty. | `UserSettingsService.getUserSettings` caches on the uid, and **linking keeps the uid** — so `syncAfterLogin` read the stale guest settings and wrote them back over the identity `_updateUserDoc` had just written. `syncAfterLogin` now calls `invalidateCache()` first. |
| F3 | **"I've verified it" did nothing.** | Firebase reported `emailVerified: true` the whole time; the Account page banner reads `needsEmailVerification`, which reads the CACHED `AuthUser`, which `checkEmailVerified` never refreshed. | `checkEmailVerified` refreshes `_currentUser` from the repository. |

**F2 is the dangerous one long-term**: an account left with `isGuest: true`
is, by `guestGcDaily`'s own rules, a candidate for deletion once it is idle
90 days. The GC checks Auth providers first and would have spared it — but
only by that one guard. That is far too close.

**What this says about the design.** F1 was not a coding slip; it was a
design that destroyed data first and repaired it afterwards, over the
network, at exactly the moment the network is least reliable. It was written
that way to stop an orphaned guest document driving alerts, which is a cost
problem, and it traded a cost problem for a data-loss problem. The orphan is
now handled by deleting it after success and by `guestGcDaily` as backstop.

**What the tests missed and why.** `guest_mode_test.dart` had a test named
*"a failed sign-in gives the guest their rivers back"* which PASSED, because
the fake datasource threw synchronously and the restore path ran cleanly. The
real failure needed the restore itself to fail or not be reached. The
replacement guards assert the stronger, simpler property — **a failed or
abandoned sign-in leaves the guest document byte-identical** — which cannot
pass while any pre-write exists. Both are mutation-checked against a
reinstated destroy-first implementation.

### Also found, not a defect in the app

**The Firestore rules change in B9 was never deployed.** The live ruleset is
still `allow read, write: if request.auth != null && request.auth.uid ==
userId`. It did not contribute to any of the above (it is permissive), but
`firestore.rules` and production have been out of step since the guest-mode
commit. Deploy with `firebase deploy --only firestore:rules`.

**Verification email delivery works.** The address was verified through the
emailed link, which is the first confirmation since the sender was repaired
on 2026-09-07.
