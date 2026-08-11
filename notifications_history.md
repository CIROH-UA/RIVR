# Cloud Functions Deploy History

Deployment history for RIVR Cloud Functions. Update this file whenever you deploy Cloud Functions to Firebase.

## Deployments

| Date | Commit | Files Changed | Summary |
|------|--------|---------------|---------|
| 2026-03-06 | 77b0cec | noaa-client.ts, notification-service.ts | Fix NOAA API response handling, improve error handling and return period cache fallback, fix unit conversion (CFS→CMS) in threshold comparison |
| 2026-03-27 | 031b3fa | .env | Rotate NWM API key after accidental exposure; new key provided by Ben Lee (CIROH) |
| 2026-07-11 | 26fd923 | package-lock.json | Security patch: `npm audit fix` on transitive deps (protobufjs 7.5.8→7.6.5 critical RCE/DoS, @grpc/grpc-js 1.14.3→1.14.4 two highs, form-data 2.5.5→2.5.6, qs, js-yaml). No source/behavior change; redeployed all 7 functions to run the patched deps. |
| 2026-07-15 | 56b01c0 | notification-service.ts, geoglows-client.ts (new) | Add GEOGLOWS flood alerts. Notification service now reads `users/{uid}.favoriteSources`, keys pre-fetched data by source+reachId (comid/linkno can collide), and branches NWM vs GEOGLOWS per favorite. New geoglows-client fetches the GEOGLOWS proxy once for forecast + gumbel return periods, converting median CMS→CFS so the shared evaluator works unchanged; `source` added to the FCM data payload so taps open the right forecast API. Redeployed all 7 default-codebase functions under jersondevs@gmail.com. Requires the `users` composite index (deployed via `firebase deploy --only firestore:indexes`). |
| 2026-08-11 | 3443a48 | functions_geoglows/main.py, requirements.txt | Daily flood-conditions precompute for GEOGLOWS. Four new functions in the `geoglows` codebase (all us-west1): `geoglows_conditions_refresh` (scheduled 11:00 UTC, fans out one Pub/Sub message per VPU), `geoglows_conditions_worker` (Pub/Sub, one region per instance — `concurrency=1` and `max_instances=20` after workers were killed at 4 GiB sharing instances), `geoglows_conditions_publish_global` (11:30 UTC, merges regions into one world file grouped by VPU), and `geoglows_conditions_latest` (HTTPS, `min_instances=1` to remove a ~7.5s cold start — costs roughly $3/month and needs `--force` to deploy). New private bucket `gs://ciroh-rivr-app-conditions`; the bucket cannot be public because an org policy forbids it, hence serving through a function. Also made the `geoglows` import lazy — at ~12s it exceeded the CLI's 10s budget for reading function signatures and blocked all deploys. Replaces on-demand computation that cost 15-300s per region and could not complete at all for the largest 14 VPUs (~33% of the world's rivers). Deployed under jersondevs@gmail.com.

