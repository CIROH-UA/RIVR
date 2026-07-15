# Cloud Functions Deploy History

Deployment history for RIVR Cloud Functions. Update this file whenever you deploy Cloud Functions to Firebase.

## Deployments

| Date | Commit | Files Changed | Summary |
|------|--------|---------------|---------|
| 2026-03-06 | 77b0cec | noaa-client.ts, notification-service.ts | Fix NOAA API response handling, improve error handling and return period cache fallback, fix unit conversion (CFS→CMS) in threshold comparison |
| 2026-03-27 | 031b3fa | .env | Rotate NWM API key after accidental exposure; new key provided by Ben Lee (CIROH) |
| 2026-07-11 | 26fd923 | package-lock.json | Security patch: `npm audit fix` on transitive deps (protobufjs 7.5.8→7.6.5 critical RCE/DoS, @grpc/grpc-js 1.14.3→1.14.4 two highs, form-data 2.5.5→2.5.6, qs, js-yaml). No source/behavior change; redeployed all 7 functions to run the patched deps. |
| 2026-07-15 | 56b01c0 | notification-service.ts, geoglows-client.ts (new) | Add GEOGLOWS flood alerts. Notification service now reads `users/{uid}.favoriteSources`, keys pre-fetched data by source+reachId (comid/linkno can collide), and branches NWM vs GEOGLOWS per favorite. New geoglows-client fetches the GEOGLOWS proxy once for forecast + gumbel return periods, converting median CMS→CFS so the shared evaluator works unchanged; `source` added to the FCM data payload so taps open the right forecast API. Redeployed all 7 default-codebase functions under jersondevs@gmail.com. Requires the `users` composite index (deployed via `firebase deploy --only firestore:indexes`). |
