# ADR 0003 — Weekly Outlook digest and independent notification types

- **Status:** Accepted — phases 1–4 delivered (settings + data model, Digest-List page, server cron, deep-link + engagement back-off) 2026-07-19/20
- **Date:** 2026-07-20
- **Deciders:** Jerson Garcia (lead)
- **Relates to:** ADR 0002 (`0002-canonical-derived-value-layer.md`), `project_push_notifications_audit` (memory)
- **Context source:** the push-notification audit (2026-07) plus a product decision to reduce notification-driven churn.

## Context and problem

RIVR's only notification was the **flood alert** — a push when a favorite river crosses a return-period threshold. Flooding is rare, so a typical user could go months with **zero** notifications and forget the app exists. That is a retention problem: the app only ever "speaks" during emergencies.

We wanted a second, calmer touchpoint — a **once-a-week digest** of how each favorite river is forecast to behave — without turning notifications into spam. The audit also established the delivery pipeline (Cloud Functions crons, per-user favorites in `users/{uid}`, FCM) that the digest should reuse rather than fork.

## Decision drivers

- A weekly digest lives or dies on two things: the notification must be **useful even unopened**, and it must be **toggleable independently** of flood alerts so it never feels bundled.
- The push and the in-app Weekly Outlook page must tell the **same story** — no "the banner said rising, the app says steady" (the exact class of bug ADR 0002 exists to prevent).
- Reuse the flood-alert fetch pipeline; do not re-implement forecast fetching or derivation.
- No new server secrets or heavy infrastructure for cosmetic wins.

## Decisions

**D1 — Notifications are independent *types*, each with its own toggle.** Flood Alerts (`enableNotifications`) and Weekly Outlook (`weeklyOutlookEnabled`) are separate booleans on `users/{uid}`, each with its own switch in the redesigned settings page (ALERTS / DIGEST groups). A user can keep the calm weekly digest while muting flood pings, or vice-versa. This separation is the core anti-spam guarantee — the digest can never arrive "bundled" with alerts.

**D2 — The device token lifecycle is decoupled from any single type.** A device token is needed if the user wants *any* notification type. `FCMService._ensureRegistered` writes the token when **either** type is enabled; `_maybeTeardownToken` removes it only when **both** are off. `enableWeeklyOutlook`/`disableWeeklyOutlook` mirror the flood-alert flow. Account deletion unconditionally unregisters the token (`unregisterDeviceToken`). This replaces the old model where the single `enableNotifications` flag owned the token.

**D3 — The weekly digest reuses the flood pipeline and mirrors client derivation.** A new scheduled function (`sendWeeklyOutlook`, Fri 7:00 AM MT) reuses `batchFetchReachData` (now exported from `notification-service.ts`) so each unique NWM/GEOGLOWS reach is fetched once. It computes trend/peak/flood-category/newsworthiness with the **same rules** as the client `WeeklyOutlookService`. In particular, `computeFlowTrend` is **peak-anchored** (rising when a crest >5% above the current reading lies ahead) and is **shared** between the outlook page and the forecast detail page's stat card — they previously disagreed ("Steady" vs "Rising"). This is ADR 0002's derive-once principle applied across the client/server boundary: the ladder and the trend rule are defined once per side and kept byte-for-byte equivalent.

**D4 — The push banner is server-composed; the app populates the *names* it can't derive.** The lock-screen/banner text is fixed by the server at send time — the app cannot rewrite it (no iOS Notification Service Extension; Android can only intercept foreground/data messages). So a GEOGLOWS reach, which the server only knows as "Stream {id}", would read poorly on the banner, and the server has no geocoder. **Chosen (Option B):** the app — which already reverse-geocodes for the Outlook page — writes a per-favorite display label to `users/{uid}.favoriteLabels` (reachId → "White River" / "Castilla, Peru"); the digest reads that label for the banner, falling back to the server's river name when absent. Rejected **Option A (server-side geocoding)**: it would require persisting reach coordinates and a Mapbox token in the functions environment (a new secret) for a purely cosmetic gain. Keeping geocoding entirely app-side means no new server secret and one source of truth for place names.

**D5 — Card layout leads with the human identifier, demotes the id.** On the Digest-List card, a **named** reach (NWM) shows its name as the title with the place as the subtitle; an **unnamed** reach (GEOGLOWS / unnamed NWM) leads with its geocoded place and puts `source · id` in the subtitle. The id therefore always lives in a full-width subtitle and never clips. `OutlookRow.title` encodes this once and is reused as the persisted `favoriteLabels` value (D4), so the card and the banner read identically.

**D6 — Delivery is fixed at Friday 7:00 AM Mountain Time for v1.** The digest inherits the flood alerts' MT-only scheduling. Time-of-day matters more for a "plan your week" digest than for threshold alerts, so this is the feature that most justifies **per-user timezones** — deferred, not designed out. The "Delivered Fridays, 7:00 AM" row in settings is display-only for now.

**D7 — Content is ranked by newsworthiness and honest on calm weeks.** Rows are ordered by flood-category severity, then rising-before-steady-before-falling, then peak. The push body leads with the single most newsworthy river (value even unopened) and states calm weeks plainly ("A calm week — all N rivers steady and normal") rather than manufacturing drama.

**D8 — The digest deep-links to the page, and cadence backs off with disengagement.** The push carries `data.type == 'weekly_outlook'`; the tap routing is a pure `notificationRoute(data)` function (unit-tested) that opens the Outlook page for that type and a reach's forecast otherwise. A `weeklyDigestsSinceOpen` counter on the user doc is incremented by the cron per send and **reset to 0 by the app whenever the Outlook page opens** (any open counts as engagement). The cron backs off deterministically via a global week index — weekly until 4 consecutive unopened digests, then biweekly, then monthly after 12 (`isDueThisWeek`) — so ignoring the digest quietly reduces its frequency instead of grinding toward an opt-out. Opening it snaps back to weekly.

## Alternatives considered

- **One master notification toggle with the digest as a sub-option.** Rejected — coupling means a user can't keep the calm digest while muting alerts, which defeats D1's anti-spam premise.
- **Server-side geocoding for banner names (Option A).** Rejected — see D4; adds a secret + coordinate persistence for a cosmetic result the app can already produce.
- **Recompute the trend server-side with its own rule.** Rejected — guarantees eventual drift from the app (ADR 0002's lesson); the rule is defined once per side and kept identical, and unit-tested on the client.
- **Per-user timezones now.** Deferred (D6) — larger scheduling change; keep parity with the existing flood-alert cadence for v1.

## Consequences

**Positive**
- Every user hears from RIVR weekly, not only during rare floods — the intended retention lever.
- Muting one notification type never affects the other; the digest can't feel like alert spam.
- The banner, the Outlook page, and the forecast detail page agree on names, trend, and category by construction.
- No new server secret; geocoding stays app-side with one source of truth.

**Negative / follow-ups**
- `favoriteLabels` is populated when the app surfaces a favorite (viewing the Outlook page); a favorite never surfaced falls back to the server river name until then. The same open also resets the back-off counter (D8), so a user who never opens the page still gets the digest — just at a backed-off cadence.
- Digest send time is MT for everyone until per-user timezones land (D6).
- The back-off uses a global week index, so its biweekly/monthly "off weeks" are shared across users rather than per-user anniversaries — simpler and stateless, at the cost of exact per-user spacing.
