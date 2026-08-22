# 0009 — Notification permission lifecycle

**Status:** Phases 1–4 shipped 2026-08-21; phase 5 outstanding and gating
**Related:** ADR 0008 (why push never worked)

## The shape of the problem

Two different things have been treated as one:

| | scope | lives in |
|---|---|---|
| **Preference** — "alert me about my rivers" | account | Firestore `enableNotifications`, `weeklyOutlookEnabled` |
| **Permission** — "this handset may post" | **device** | the OS |
| **Address** — where to deliver | **device** | Firestore `fcmTokens[]` |

Tokens are already per-device and correct. The preference is account-wide, which
is right — a person wants alerts about *their rivers*, not about a handset. The
gap is that **nothing reconciles an account-level preference with a device-level
permission.**

Measured consequences (2026-08-21):

- Signing in on Android rendered both toggles ON, inherited from the account.
- Permission is only requested inside the *toggle switch handler*, so an
  inherited ON is never flipped and never asks.
- `POST_NOTIFICATIONS granted=false`, two green toggles, "2 devices registered",
  a valid FCM token — and every message silently dropped. FCM tokens do not
  require the notification permission, so the token proved nothing.

## Constraints that shape every decision

1. **iOS grants exactly one system prompt per install.** Denied is close to
   permanent — recovery means the user finding the app in Settings. A wasted
   prompt is unrecoverable, so the app must never spend it cheaply.
2. **Android 13+ requires `POST_NOTIFICATIONS` at runtime**, per device, and
   re-prompting is limited after refusals.
3. **A token is not permission.** Both platforms issue FCM tokens to apps that
   cannot post anything.
4. **Preferences sync; permissions do not.** Every additional device starts from
   an inherited preference and a blank permission.
5. **The app cannot detect "user swiped the prompt away"** distinctly from a
   deliberate No. Treat both as denied and stop asking.

## Principles

- **Never ask cold.** A prompt at first launch, before value is shown, is the
  most common way apps lose the permission permanently.
- **Prime before asking.** Show our own explanation with our own Enable / Not
  now. "Not now" costs nothing; only "Enable" spends the real prompt.
- **Ask at expressed interest.** In RIVR that is unmistakable: adding a
  favourite. The user has just said "I care about this river."
- **Never render a state the OS contradicts.** Already fixed for the blocked
  case; the rest follows the same rule.
- **Say what will happen, specifically.** "Get alerted when White River floods"
  beats "Enable notifications".

---

# Phase 1 — Reconcile inherited preferences ✅ SHIPPED

**Problem.** A device inheriting `enableNotifications: true` is never asked.

**Build.** When the notification settings page opens, and when the app resumes
with a preference on, compare preference against `osPermissionStatus()`:

| preference | OS | action |
|---|---|---|
| ON | `notDetermined` | request permission once this session |
| ON | `granted` | ensure a token exists; register if missing |
| ON | `permanentlyDenied` | show blocked + route to Settings *(built)* |
| OFF | anything | nothing |

Deliberately **not** at cold launch — on the settings page the user is already
thinking about notifications, which is the context that makes a prompt make
sense.

**Guards — all must pass:**

1. A device with preference ON and `notDetermined` is prompted exactly **once
   per app session**, never in a loop. Test: pump the page twice, assert one
   request.
2. A device with `permanentlyDenied` is **never** prompted. Test: assert zero
   requests.
3. A device with preference OFF is never prompted regardless of OS state.
4. After a grant, a token appears in `fcmTokens` within the same flow.
5. On device: revoke `POST_NOTIFICATIONS`, open settings, confirm a prompt; grant
   it, confirm the row turns green and a token is written.

---

# Phase 2 — Prime at first favourite ✅ SHIPPED

**Problem.** New users are never asked at all unless they visit settings.

**Build.** On adding a **first** favourite, show an in-app card — our UI, not the
system prompt:

> **Get alerts for White River?**
> We'll tell you when it's forecast to flood, and send a calm weekly summary
> each Friday.
> **[ Enable ]  [ Not now ]**

- **Enable** → request the OS permission → on grant set **both** preferences ON
- **Not now** → nothing changes, nothing is spent; do not ask again for 30 days
  or until the user visits notification settings

Naming the river matters: it converts an abstract permission into a concrete
promise.

**Guards:**

1. Shown only when the user has **exactly one** favourite and OS is
   `notDetermined`. Never on the second favourite, never when already granted or
   denied.
2. "Not now" issues **zero** OS requests — verified by asserting the service was
   not called. This is the guard that protects the one-prompt budget.
3. "Enable" on grant sets both preferences true **and** registers a token.
4. Dismissal is persisted; the card does not reappear on the next launch.
5. Copy names the actual river, not a placeholder.

---

# Phase 3 — Denied is a state, not a dead end ✅ SHIPPED

**Problem.** Denied users see toggles they can flip that do nothing.

**Build.**

- When `permanentlyDenied`: both toggles render **off and disabled**, with the
  blocked row and a Settings route *(row already built)*.
- Flipping a disabled toggle does not write a preference — today it would
  persist ON for a device that cannot deliver.
- On resume from Settings, re-read the permission; if it flipped to granted,
  restore the preference and register.

**Guards:**

1. With `permanentlyDenied`, tapping a toggle writes **nothing** to Firestore.
2. Returning from Settings with permission granted registers a token without any
   further tap.
3. The blocked row's tap opens system settings on both platforms.
4. A user denied on one device but granted on another keeps working on the
   second — the account preference is not destroyed by one device's refusal.
   **This is the guard that proves preference and permission stay separate.**

---

# Phase 4 — Stop the service lying ✅ SHIPPED

Four defects from ADR 0008, all of which let a broken state look healthy.

**Build.**

1. `_ensureRegistered` returns `granted` when the token is `'pending'`. It must
   return a distinct result so the caller does not persist a preference for a
   device that got no token.
2. `_saveTokenToUserSettings` swallows write failures — a failed Firestore write
   is indistinguishable from success. Must surface.
3. Token rotation is `arrayRemove(old)` then `arrayUnion(new)` as separate
   writes; if the second fails the user loses their only token. Make it one
   atomic update.
4. `getAndSaveToken` has no callers. Delete.

**Guards:**

1. A `'pending'` token never results in a persisted preference.
2. A simulated Firestore failure surfaces to the caller and the UI does not
   claim success. Test with a throwing fake.
3. Rotation under a failing second write leaves the **old** token intact rather
   than none. Test explicitly — this is the data-loss case.
4. `grep -r getAndSaveToken lib/` returns nothing.

---

# Phase 5 — Prove it on real devices ⬜ OUTSTANDING

Config review is not evidence. ADR 0008 exists because four layers each reported
success while nothing was delivered.

**Matrix — every cell demonstrated, not reasoned about:**

| scenario | iOS | Android |
|---|---|---|
| Fresh install, never asked | | |
| Prime → Enable → granted | | |
| Prime → Not now | | |
| Denied at OS level | | |
| Granted on device A, fresh sign-in on device B | | |
| Preference ON inherited, OS notDetermined | | |
| Revoked in Settings while app is backgrounded | | |

**Guards:**

1. A notification is **seen on a screen** in the granted rows — not "FCM
   accepted", which ADR 0008 showed proves nothing.
2. Android needs a real device or a `google_apis_playstore` AVD with a Google
   account. The current `google_apis` emulator cannot complete FCM's connection
   and is not admissible evidence.
3. Tapping each notification type lands on the right screen.
4. Every row recorded with a date and the build number it was tested on.

---

## DECIDED — hard ask, per device, all or nothing

`provisional` was considered and **rejected**. Jerson: *"A hard ask on individual
devices even if using the same account that enables all notifications is simpler
and best. They either accept to get all the notifications or not."*

So `requestPermission(provisional: false)` stays, and one grant covers both
notification types. Consequences to hold to:

- **No per-type permission.** The priming card offers everything or nothing, and
  its copy must say so — promising only flood alerts and then also sending a
  weekly digest would be a bait-and-switch.
- **The single iOS prompt matters more, not less.** With no provisional fallback
  there is no second route in, which makes the Phase 2 guard — "Not now" issues
  zero OS requests — the most important guard in this document.
- **Denied is genuinely terminal** until the user visits Settings, so Phase 3
  carries the whole recovery story.

## Sequencing

1 → 3 → 2 → 4 → 5. Phase 1 fixes the live bug for existing users. Phase 3
prevents new lies. Phase 2 is growth and should not ship before the states it
produces are handled. Phase 4 is hygiene, best done while the call sites are
open. Phase 5 gates the release.


---

# What shipped (2026-08-21)

**44 guard tests across phases 1–4; 839 green overall.** Everything below is in
`development`, unreleased at time of writing.

## Phase 1

`reconcileDevice()` on the settings page — not at cold launch, which is the
reliable way to lose the permission permanently. Asks at most once per session
and never when denied, so calling it on every page open is safe.

**Guard 5 not met.** The device proof for `notDetermined` could not be taken:
Android would not return to never-asked. `pm reset-permissions` leaves the
user-set denial in place, so the OS reported `permanentlyDenied` and the code
correctly declined to prompt — which is Guard 2 passing on hardware, not Guard 1.
Reaching a genuine never-asked state needs `pm clear` or a reinstall, which signs
the user out. **Folded into phase 5**, whose matrix requires a fresh install
anyway.

## Phase 2

The existing banner was shown whenever notifications were off, routed to the
settings page, used generic copy, and dismissed permanently. It is now the soft
ask: names the river just saved, asks inline, Enable / Not now.

**Dismissal now expires after 30 days.** One distracted tap should not cost
someone notifications forever with no route back except finding the settings
page. Legacy permanent dismissals are migrated to a timestamp so those users are
asked again too.

## Phase 3

Verified on device in both directions. Denied: toggles off and inert, "Delivered
Fridays" hidden, blocked row with a Settings route. Granted externally then
resumed: toggles green, schedule back, "2 devices registered" — with no tap
inside the app.

Only the denied → granted *transition* registers, so ordinary app switching does
not rewrite the token array.

## Phase 4

The rotation fix is **ordering, not atomicity**. Firestore refuses `arrayRemove`
and `arrayUnion` on the same field in one write, so rotation cannot be atomic and
the order is the whole safety property. The previous code's comment claimed
"atomically" while doing remove-then-add — precisely backwards.

**A guard that nearly wasn't real.** The first version asserted `arrayUnion` vs
`arrayRemove` by stringifying the sentinel; both render as
`FieldValue(Instance of MethodChannelFieldValue)`, so the test would have passed
against the broken code. It now counts write *attempts*, with the spy recording
even those that throw — which is what makes "the removal was never attempted"
observable from outside at all.

## Phase 5 — iOS delivery and tap routing now proven (2026-08-21)

Three matrix cells are closed on **2026.1.3+561**, all on a real iPhone:

| scenario | iOS | evidence |
|---|---|---|
| Notification seen on screen | ✅ | lock-screen screenshot, "Your rivers this week" |
| Tap lands on the right screen | ✅ | Weekly Outlook opened from a cold start |
| Deep-linked page loads real data | ✅ | `weeklyDigestsSinceOpen` reset 1 → 0 server-side, which only happens after the outlook builds rows from a non-empty favourites list |

The last row is worth keeping as a technique: it verifies the client from the
server, with no screenshot and no trust in what a person reports seeing.

Getting here needed two fixes beyond the permission work — `firebase_messaging`
16.0.3 had no UIScene support (ADR 0008), and the outlook rendered its empty
state during the launch race. Both shipped in 555 and 561.

**Still open on iOS:** fresh-install / never-asked, prime → Enable, prime → Not
now, denied-at-OS, and the two multi-device rows. **Android remains entirely
unproven** and still needs a real device or a `google_apis_playstore` AVD.

**New, and it gates nothing here but is user-visible:** the deep-linked page
took 3-5 minutes to render. See ADR 0010.

## Phase 5 — what is still needed

Neither of these can be supplied from this machine:

- **A fresh iOS install**, to reach a genuine `notDetermined` and exercise the
  prime → Enable → granted path end to end.
- **A real Android device**, or a `google_apis_playstore` AVD signed into a
  Google account. The `google_apis` emulator used here obtains tokens and
  accepts sends but never completes FCM's connection (`FcmRetry`,
  `GCM_HB_ALARM`), so it cannot demonstrate delivery and is **not admissible
  evidence**.
