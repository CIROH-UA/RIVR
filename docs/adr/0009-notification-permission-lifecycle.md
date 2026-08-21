# 0009 — Notification permission lifecycle

**Status:** Proposed — spec only
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

# Phase 1 — Reconcile inherited preferences

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

# Phase 2 — Prime at first favourite

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

# Phase 3 — Denied is a state, not a dead end

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

# Phase 4 — Stop the service lying

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

# Phase 5 — Prove it on real devices

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

## Open question for Jerson — provisional authorization

`requestPermission(provisional: false)` today, i.e. always the hard ask.

iOS also offers **provisional**: notifications are delivered **quietly to
Notification Center with no prompt at all**, and the user is offered "Keep" or
"Turn Off" after seeing a real one. The prompt is never spent.

It fits the Weekly Outlook unusually well — a calm Friday summary is exactly the
kind of thing that argues for itself once seen. A candidate split:

- **Weekly Outlook** → provisional, no prompt, arrives quietly
- **Flood alerts** → hard ask, because a flood warning must break through

The cost is that provisional notifications are quiet by default: they do not
appear on the lock screen or make a sound until promoted. **Decide before
Phase 2**, since it changes what the priming card offers.

## Sequencing

1 → 3 → 2 → 4 → 5. Phase 1 fixes the live bug for existing users. Phase 3
prevents new lies. Phase 2 is growth and should not ship before the states it
produces are handled. Phase 4 is hygiene, best done while the call sites are
open. Phase 5 gates the release.
