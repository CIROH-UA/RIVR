# App Releases

Release history for RIVR. Update this file whenever you bump the version or build number in `pubspec.yaml`.

## Releases

| Version | Date | Commit | Summary |
|---------|------|--------|---------|
| 1.1.0+7 | 2026-05-16 | e438854 | In-app account deletion (App Store Guideline 5.1.1(v)): Account page reachable from the three-dots menu with Delete Account at the bottom — reauth + Firestore `users/{uid}` cleanup + FCM token invalidation + biometric clear. Branded Android launch screen (parity with iOS, legacy + Android 12+ SplashScreen API). Dependabot: 1 critical + 6 high + 6 medium transitive vulns closed in Cloud Functions. iOS purpose strings, store-listing URLs, privacy-policy draft, Google Play feature graphic (from prior weeks, bundled in this build). |
| 1.1.0+6 | 2026-04-16 | — | Clean architecture rewrite (ServiceResult pattern, entity/DTO separation, layer-first folder structure, per-feature DI), disk cache with stale-while-revalidate, parallel non-blocking data loading, progressive loading with shimmer skeletons, GitHub Actions CI, Firebase Crashlytics and Analytics, offline connectivity banner, NOAA API retry logic, notification frequency settings, new app icons, UI refinements across all features, 50+ bug fixes |
| 1.0.0+5 | 2026-02-22 | — | Add favorites coach marks tutorial, smooth finger-tracking slide actions, pass current flow when adding favorites from map, change flow unit labels to ft³/s and m³/s, right-align settings menu icons, fix GlobalKey crash after coach marks navigation, fix video backgrounds randomly stopping |
| 1.0.0+4 | 2026-02-21 | — | Keep Standard basemap always light, fix stream colors |
| 1.0.0+3 | 2026-02-21 | 117eb48 | Add missing NSLocationAlwaysAndWhenInUseUsageDescription |
| 1.0.0+2 | 2026-02-21 | eb567ed | TestFlight internal testing build |
| 1.0.0+0 | 2026-02-20 | 0e2b450 | Initial release build for internal testing |
