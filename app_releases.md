# App Releases

Release history for RIVR. Update this file whenever you bump the version or build number in `pubspec.yaml`.

## Versioning

`<year>.<major>.<minor>+<commit count>` — e.g. `2026.0.0+521`.

Stamp it with `make version` on `main` after merging, never by hand. The build
number is the repository's commit count, so it is derived rather than
remembered: there is no counter to forget, and it can only rise. Both stores
require a strictly increasing build number and reject a repeat, which is the
mistake this removes.

`YEAR`/`MAJOR`/`MINOR` are deliberate — MAJOR for a release users would notice,
MINOR for fixes, YEAR when the calendar does: `make version MAJOR=1`.

Adopted 2026-08-20, replacing semver `1.2.0+8`. Note this is one-way: both
stores enforce increasing versions, so there is no going back to `1.x`.

## Releases

| Version | Date | Commit | Summary |
|---------|------|--------|---------|
| 2026.0.1+529 | 2026-08-21 | — | **Fixes push notifications, which had never worked.** Build 524 shipped with `aps-environment=development`; Apple's production APNs refuses registration from such a build, so `getAPNSToken()` returned null forever, the APNs poll expired, and no FCM token was ever written — the app showed "Device not registered" and Firestore held tokens for 1 of 18 users, with `notification_logs` empty since launch. Root cause was a missing **Apple Distribution certificate for HydroMap LLC** (only Oqupa LLC's existed), so export had no distribution identity and fell back to the development team profile. Release now also carries its own `RunnerRelease.entitlements` declaring production, making the intent explicit; Debug and Profile keep development. Verified in the exported IPA: production entitlement, iOS Team Store Provisioning Profile, signed by Apple Distribution: HydroMap LLC. Also restores `NSLocationAlwaysAndWhenInUseUsageDescription` (ITMS-90683 on 524, a regression since 1.0.0+3), and adds `make upload-symbols` after the documented Crashlytics command turned out to be wrong for iOS. |
| 2026.0.0+524 | 2026-08-20 | — | First release since the Apple Developer account was recovered, and the first on the new `<year>.<major>.<minor>+<commits>` scheme. **Map:** rebuilt both stream networks as `-v3` tilesets — z0-12 with a stream-order ladder, fixing the broken low-zoom rendering, and tagging reaches whose geometry crosses lakes so a single Remote Config switch hides them on the base networks and the flood layer together. Flood colours now come from a daily pre-coloured tileset built by an autonomous Cloud Run job (classify → geometry join → NOAA merge → lake tagging → tiling → plausibility gates → Mapbox → Remote Config), which as of this release runs unattended at 11:00 UTC. The map opens on the user's location, or Provo when location is unavailable, instead of restoring an arbitrary last camera. Legend reduced to one line, "As of August 20th". **Detail sheet:** current flow and the forecast peak now sit side by side as equal tiles over the flood ladder, replacing a full-width flow card and a three-line text banner; reach metadata collapses behind a Details disclosure. **Flood colour:** one palette in AppConstants, indexed to the category ladder — fixes medium-range hourly bars that painted grey for every category above Normal because five widgets still switched on a retired vocabulary. Ink on filled swatches is now chosen by measured contrast (Action 1.6:1 → 8.3:1). **Offline:** connectivity is detected by reachability rather than by network interface, so a captive portal no longer reads as online; the banner is legible (2.2:1 → 9.6:1), announced to VoiceOver, and no longer covers the first favourite. The map shows its own notice explaining why new areas will not load. **Platform:** Flutter 3.47.1 (matching CI), iOS migrated to Swift Package Manager, seven Dependabot alerts closed in Cloud Functions. **Notifications:** Weekly Outlook digest deployed — Fridays 07:00 America/Denver. |
| 1.2.0+8 | 2026-07-11 | — | GEOGLOWS v2 integration: render GEOGLOWS streams on the map with a stream-source selector (NWM / GEOGLOWS outside-US / GEOGLOWS US-area, US-area OFF by default) and US-boundary mask; tap-to-source routing; GEOGLOWS forecast via a Cloud Function proxy with a minimal forecast page. River data layer SSOT refactor (ADR 0001): single `RiverDataRepository` with a shared `(source, reachId, product)` cache, publish-aligned TTL + stale-while-revalidate + in-flight dedup — fixes the tap→"See forecast" double-fetch; map bottom sheet (NWM + GEOGLOWS) and favorites read current flow through it. Integration test suite fully green (36/36). Cloud Functions transitive-dep security patch (protobufjs critical RCE, grpc-js highs). First main release to catch up with the 1.1.0+7 development line (account deletion, R8 hardening). |
| 1.1.0+7 | 2026-05-16 | e438854 | In-app account deletion (App Store Guideline 5.1.1(v)): Account page reachable from the three-dots menu with Delete Account at the bottom — reauth + Firestore `users/{uid}` cleanup + FCM token invalidation + biometric clear. Branded Android launch screen (parity with iOS, legacy + Android 12+ SplashScreen API). Dependabot: 1 critical + 6 high + 6 medium transitive vulns closed in Cloud Functions. iOS purpose strings, store-listing URLs, privacy-policy draft, Google Play feature graphic (from prior weeks, bundled in this build). |
| 1.1.0+6 | 2026-04-16 | — | Clean architecture rewrite (ServiceResult pattern, entity/DTO separation, layer-first folder structure, per-feature DI), disk cache with stale-while-revalidate, parallel non-blocking data loading, progressive loading with shimmer skeletons, GitHub Actions CI, Firebase Crashlytics and Analytics, offline connectivity banner, NOAA API retry logic, notification frequency settings, new app icons, UI refinements across all features, 50+ bug fixes |
| 1.0.0+5 | 2026-02-22 | — | Add favorites coach marks tutorial, smooth finger-tracking slide actions, pass current flow when adding favorites from map, change flow unit labels to ft³/s and m³/s, right-align settings menu icons, fix GlobalKey crash after coach marks navigation, fix video backgrounds randomly stopping |
| 1.0.0+4 | 2026-02-21 | — | Keep Standard basemap always light, fix stream colors |
| 1.0.0+3 | 2026-02-21 | 117eb48 | Add missing NSLocationAlwaysAndWhenInUseUsageDescription |
| 1.0.0+2 | 2026-02-21 | eb567ed | TestFlight internal testing build |
| 1.0.0+0 | 2026-02-20 | 0e2b450 | Initial release build for internal testing |
