# RIVR

River flow monitoring and flood risk assessment mobile app. Democratizes access to the NOAA National Water Model, providing real-time river flow data, flood risk analysis via return period thresholds, and multi-range forecasting (short, medium, long range).

## Tech Stack

- **Framework:** Flutter/Dart (SDK ^3.8.0), iOS (Cupertino-first) + Android
- **State management:** Provider with ChangeNotifier
- **Backend:** Firebase (Auth, Firestore, Cloud Messaging, Analytics, Cloud Functions in TypeScript)
- **Maps:** Mapbox Maps Flutter (2.7M NWM channels via vector tiles)
- **Charts:** Syncfusion Flutter Charts
- **Auth:** Firebase Auth + local biometric auth (local_auth, flutter_secure_storage)
- **Data sources:** NOAA National Water Prediction Service API, NWM Return Periods API (CIROH)

## Architecture

Layer-first architecture with numbered subfolders (Models → Services → UI):

```
lib/
  main.dart                              -- Entry point, MultiProvider setup, CupertinoApp routing
  firebase_options.dart                  -- Auto-generated Firebase config (gitignored)
  models/
    1_domain/
      shared/                            -- Core entities (ReachData, FavoriteRiver, UserSettings, etc.)
      features/{auth,forecast,map}/      -- Feature-specific entities
    2_usecases/
      shared/                            -- BaseUseCase
      features/{auth,favorites,forecast,map,settings}/  -- Use cases by feature
  services/
    0_config/shared/                     -- config.dart (gitignored), constants.dart
    1_contracts/
      shared/                            -- Service interfaces (i_*.dart)
      features/{auth,favorites,forecast,settings}/  -- Repository interfaces
    2_coordinators/features/             -- Repository implementations (error-mapping coordinators)
    3_datasources/
      shared/dtos/                       -- DTOs (ReachDataDto, FavoriteRiverDto, UserSettingsDto)
      features/{auth,settings}/          -- Datasource classes
    4_infrastructure/                    -- Service implementations by technical domain
      api/                               -- NoaaApiService
      auth/                              -- AuthService
      cache/                             -- CacheService, ReachCacheService
      favorites/                         -- FavoritesService, CoachMarkService
      fcm/                               -- FCMService
      forecast/                          -- ForecastService, DailyForecastProcessor
      geo/                               -- GeocodingService
      logging/                           -- AppLogger
      map/                               -- Map services (6 files)
      media/                             -- BackgroundImageService
      network/                           -- ConnectivityService
      onboarding/                        -- OnboardingService
      settings/                          -- UserSettingsService
      shared/                            -- ErrorService, ServiceResult, AnalyticsService
    5_injection/                         -- dependency_container.dart + per-feature DI files (GetIt)
  ui/
    1_state/
      shared/                            -- ConnectivityProvider
      features/{auth,favorites,forecast}/ -- Providers (ChangeNotifier)
    2_presentation/
      routing/                           -- AppRouter, AuthGuard, routes
      shared/{pages,widgets}/            -- Shared UI components
      features/{auth,favorites,forecast,map,onboarding,settings}/  -- Pages + widgets
  utils/                                 -- Utilities (river_image, email_validator, etc.)
functions/                               -- Firebase Cloud Functions (TypeScript, "default" codebase)
  src/index.ts                           -- Cloud Function entry points
  src/notification-service.ts            -- Push notification logic
  src/noaa-client.ts                     -- Server-side NOAA API client
functions_geoglows/                      -- Firebase Cloud Functions (Python, "geoglows" codebase)
  main.py                                -- GEOGLOWS forecast/coords proxies (conditions functions deleted;
                                            flood colours now come from a daily tileset)
  vpu_slices.json                        -- bundled VPU -> river-slice index (stream conditions)
```

### Flood colours — current design (superseded the Cloud Function pipeline)

**The four `geoglows_conditions_*` Cloud Functions are DELETED.** They ran a
Pub/Sub fan-out to precompute conditions as JSON, which the app then painted
onto the map at runtime. That path is gone for two reasons: it was still slow
(applying ~85k reaches via a Mapbox `match` expression cost 8-12s on device),
and the functions were removed to stop idle billing.

**Colours are now baked into a daily vector tileset**, so the app draws them
straight from the tile with no runtime painting.

| | |
|---|---|
| Daily tileset | `byu-hydroinformatics.rivr-flooded-YYYYMMDD` |
| Contents | only reaches at or above their own 2-year return period |
| Fields | `station_id`, `cat` (1-4 = Action/Moderate/Major/Extreme) |
| Zoom | 0-12; **only `cat >= 2` at z0-2** so the world tile stays well under
Mapbox's 500 KB ceiling (23% vs 98% before) |
| Retention | 3 days, older ones pruned |
| Cost | ~0.43 CU/day → ~13 of the 20 free CU/month |

**Build script:** `~/Developer/rivr-tiles/daily/build_flooded.py` (not in this
repo — it carries no secrets but needs the local GEOGLOWS venv and tippecanoe).
Classifies GEOGLOWS from the forecast zarr (~110 min, the dominant cost),
joins geometry from a sharded index in GCS, adds the US half from NOAA's
high-flow services (geometry included), tiles, gates, uploads, prunes.

**Supporting artefact:** `gs://ciroh-rivr-app-conditions/geometry/geoglows/vpu-NNN.fgb`
— 125 FlatGeobuf shards, `station_id` + geometry simplified to 10 m. GEOGLOWS
publishes ids without geometry, and its source is a 2 GB geodatabase, so this
index is how a flood id becomes a drawable line.

**Lake artefacts are tagged, not deleted.** Both routing networks draw straight
lines through lakes to connect the rivers above and below them; those reaches
carry the whole lake's throughflow and classify as top-category floods. 7,039 of
100,220 flood reaches (7%) are such artefacts. Each carries `overLake` 0/1 and
the app filters them out by default — tagged rather than dropped so the NWM and
GEOGLOWS teams can still see their models' behaviour. Reach ID lists live in
`gs://ciroh-rivr-app-conditions/lakes/`.

**It runs itself.** Cloud Scheduler `flood-builder-daily` (`0 11 * * *` UTC)
triggers Cloud Run job `flood-builder` in us-west1. Region is not optional — it
sits next to the GEOGLOWS S3 buckets in us-west-2 and the run reads ~400 GB.

**Never run a partial build against production.** `--only` / `--vpu` now force
`--dry-run` and an isolated work dir, because a `--vpu 101` test once replaced
the live tileset with 2 reaches in Tanzania and the plausibility gate that would
have caught it is the one restricted runs relax.

To check a published tileset quickly, fetch it at every zoom and count features
per tile — `z0 → 2 features, z1+ → 404` diagnosed that incident in seconds.

```bash
gcloud run jobs execute flood-builder --region=us-west1                      # run now
gcloud run jobs executions list --job=flood-builder --region=us-west1        # history
gcloud scheduler jobs describe flood-builder-daily --location=us-west1   --format="value(status.code)"                                             # empty = OK
gcloud logging read 'resource.type=cloud_run_job' --limit=30 --freshness=2h
```

Container source is `~/Developer/rivr-tiles/cloudrun/` (not in this repo).
Rebuild with `gcloud builds submit --tag us-west1-docker.pkg.dev/ciroh-rivr-app/rivr/flood-builder:latest`.

**The job publishes Firebase Remote Config** as its last step, after Mapbox
confirms processing:

| Parameter | Meaning |
|---|---|
| `flood_tileset_id` | which tileset the app should load |
| `flood_data_date` | the date shown above the legend |
| `flood_show_lake_reaches` | lake-artefact switch; set once, never overwritten |

Flipping `flood_show_lake_reaches` in the Firebase console changes every user's
map within seconds and survives subsequent builds — which matters because the
Apple account lockout makes app releases slow.

A full cloud run takes **~2.5 hours** (94 min classification, ~14 min geometry
join, the rest tiling and upload), so an 11:00 UTC start lands ~13:30 UTC.

**The app follows it.** `FloodTilesetService` reads Remote Config on launch
(3s timeout, never blocks startup) and falls back to deriving the id from
today's UTC date. The legend shows the data date; the reach detail sheet shows
that reach's real forecast window (15 days / 5 days / 48 hours).

**Phase 4 is complete and the pipeline runs itself** — the 2026-08-20 build
fired on schedule, published, and updated Remote Config with nobody watching.

The app draws both base networks from the `-v3` tilesets (z0-12 stream-order
ladder + `overLake`), so one Remote Config switch hides lake artefacts on the
base networks and the flood layer together.

Tapping a coloured river whose peak outranks its current flow shows a strip
explaining that the map colours by forecast peak. `shouldShowPeakStrip` in
`reach_details_bottom_sheet.dart` is the settled, tested part; **the strip's
visual design is rejected and provisional** — the sheet is due a redesign, so
treat `_buildPeakStrip` as throwaway.

**Closed, do not reopen:** residual base-network lines across smaller lakes
(Utah Lake and similar). The big lakes are clean and the tail is not worth
chasing lake by lake.

**Known limit:** on a much wetter day the flood tileset's zoom-0 tile could
still approach Mapbox's 500 KB ceiling and fail the build gate. The low-zoom
category ladder (`cat >= 2` at z0-2) took it from 98% to 23%, so there is real
headroom now; a stream-order ladder on the flood tileset is the next lever.

**Non-negotiable when working on any of this:** these pipelines fail *silently*
— five separate operations have exited 0 while producing wrong or partial data.
Always compare the output feature count to a known expected number. Exit status
and "done" messages have never caught any of them.

### Key Patterns

- **Layer-first structure:** `models/` (entities + use cases) → `services/` (contracts + coordinators + datasources + infrastructure + DI) → `ui/` (state + presentation)
- **ServiceResult pattern:** All use cases return `ServiceResult<T>` for structured error handling
- **Coordinator pattern:** Repository implementations map raw errors to `ServiceResult` failures
- **Entity/DTO separation:** Pure domain entities in `models/1_domain/`, DTOs with serialization in `services/3_datasources/`
- **Provider pattern:** Providers extend ChangeNotifier, registered in main.dart via MultiProvider
- **Phased data loading:** ForecastService uses loadOverviewData -> loadSupplementaryData -> loadCompleteReachData
- **Unit conversion:** All forecast data converted at the API layer (NoaaApiService) before reaching UI
- **DI:** GetIt via `services/5_injection/dependency_container.dart` (orchestrator) + per-feature files (`auth_dependencies.dart`, `favorites_dependencies.dart`, etc.)

## Git Workflow

### Branch Strategy
```
main              -- Production-ready releases only. Never commit directly.
  └── development -- Active development. All feature/bugfix branches merge here.
        ├── feature/...
        ├── bugfix/...
        └── chore/...
```

- **`main`** — Public release code. Only updated by merging `development` when ready for a new release.
- **`development`** — Integration branch for all active work. This is the default working branch.
- **Feature/bugfix branches** — Short-lived branches created from `development` for individual tasks.

### IMPORTANT: Always create a new branch before starting work
Never commit directly to `development` or `main`. Before writing any code:
1. `git checkout development && git pull origin development`
2. `git checkout -b <prefix>/<short-description>`
3. Do your work, commit, and push
4. Merge into `development` (no PR required during development stage)
5. Delete the feature branch after merging

### Branch Naming
- `feature/` — New functionality (e.g., `feature/notifications`)
- `bugfix/` — Bug fixes (e.g., `bugfix/forecast-parsing`)
- `hotfix/` — Urgent production fixes branched from `main` (e.g., `hotfix/crash-on-launch`)
- `chore/` — Maintenance, refactors, dependency updates (e.g., `chore/update-dependencies`)

### Merging to development
```bash
git checkout development
git pull origin development
git merge feature/my-feature
git push origin development
git branch -d feature/my-feature
git push origin --delete feature/my-feature
```

### Releasing to main
When `development` is stable and ready for release:
```bash
git checkout main
git pull origin main
git merge development
git push origin main
```

### Commits
- Imperative mood, concise (e.g., "Add notification frequency picker", "Fix forecast unit conversion")
- One logical change per commit

### Rules
- Never commit directly to `main` or `development`
- Never force push to `main` or `development`
- Never commit secrets (API keys, google-services.json, firebase_options.dart)
- Run `flutter analyze` before pushing
- Hotfixes are the only branches created from `main` (merge back to both `main` and `development`)

## Code Conventions

### UI
- Cupertino-first: CupertinoApp, CupertinoPageScaffold, CupertinoButton, CupertinoColors, CupertinoIcons
- Import Material only when Cupertino lacks an equivalent (e.g., ReorderableListView, Dismissible)
- Theme-aware via ThemeProvider for dark/light mode

### File Naming
- All Dart files: `snake_case.dart`
- Pages: `*_page.dart`
- Services: `*_service.dart`
- Providers: `*_provider.dart`
- Models: descriptive noun `snake_case.dart`
- Tests: `*_test.dart` suffix

### Imports
- Always use absolute imports: `package:rivr/...` (full package imports)
- No relative imports (all converted to absolute during Phase 8 restructure)

### Debug Logging
- Service-specific prefixes: `'NOAA_API:'`, `'AUTH_PROVIDER:'`, `'FORECAST_SERVICE:'`, `'CACHE_SERVICE:'`

## Testing

### Structure
Tests mirror the `lib/` directory structure:

```
test/
  models/1_domain/shared/           -- Entity unit tests (ReachData, FavoriteRiver, UserSettings)
  services/
    2_coordinators/features/         -- Repository impl tests (auth, favorites, forecast, settings)
    3_datasources/
      shared/dtos/                   -- DTO tests
      features/settings/             -- Settings datasource tests
    4_infrastructure/
      api/                           -- NoaaApiService tests
      cache/                         -- ReachCacheService tests
      favorites/                     -- CoachMark tests
      fcm/                           -- FCMService tests
      forecast/                      -- DailyForecastProcessor tests
      shared/                        -- ErrorService, ServiceResult, FlowUnitPref tests
  ui/
    1_state/features/auth/           -- AuthProvider tests
    2_presentation/features/         -- Widget tests
  utils/                             -- Utility tests
  helpers/
    test_helpers.dart                -- pumpApp() wrapper with mock providers
    fake_data.dart                   -- Factory methods for test data
  integration_test/                  -- End-to-end integration tests
```

### Test Priority
1. Pure models (ReachData, FavoriteRiver, UserSettings) -- no dependencies, highest logic density
2. Services with mocks (NoaaApiService, ForecastService, ErrorService) -- core business logic
3. Providers (FavoritesProvider, AuthProvider) -- state management correctness
4. Widget tests (LoginPage, FavoritesPage, ReachOverviewPage) -- critical user flows
5. Integration tests -- end-to-end confidence

### Running Tests
```bash
flutter test                                    # All unit and widget tests
flutter test test/models/                       # Just model tests
flutter test test/services/4_infrastructure/    # Infrastructure service tests
flutter test --coverage                         # With coverage report
flutter test integration_test/                  # Integration tests
```

## Key File Paths

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point, provider registration, CupertinoApp routing |
| `lib/services/0_config/shared/config.dart` | API keys and URLs (**gitignored** -- create from config.template.dart) |
| `lib/services/0_config/shared/constants.dart` | Non-sensitive constants, forecast definitions |
| `lib/models/1_domain/shared/reach_data.dart` | Core entity for river reaches (800+ lines) |
| `lib/services/3_datasources/shared/dtos/reach_data_dto.dart` | ReachData DTO with NOAA API parsing/serialization |
| `lib/services/4_infrastructure/forecast/forecast_service.dart` | Central forecast loading, caching, phased loading |
| `lib/services/4_infrastructure/api/noaa_api_service.dart` | All NOAA API calls with unit conversion |
| `lib/ui/1_state/features/favorites/favorites_provider.dart` | Primary state management for favorites |
| `lib/ui/1_state/features/auth/auth_provider.dart` | Authentication state |
| `lib/services/4_infrastructure/auth/auth_service.dart` | Firebase Auth + biometric auth wrapper |
| `lib/services/4_infrastructure/fcm/fcm_service.dart` | Firebase Cloud Messaging token management |
| `lib/services/5_injection/dependency_container.dart` | GetIt DI orchestrator (calls per-feature setup functions) |
| `lib/ui/2_presentation/features/map/pages/map_page.dart` | Mapbox map integration |
| `lib/firebase_options.dart` | Firebase config (**gitignored**) |
| `functions/src/index.ts` | Cloud Functions entry point |
| `.firebaserc` | Firebase project ID (ciroh-rivr-app) |
| `pubspec.yaml` | Dependencies, assets, SDK constraints |

## Security

The following files contain secrets and are **gitignored**:

| File | Contains |
|------|----------|
| `lib/services/0_config/shared/config.dart` | Mapbox token, NWM API URLs, vector tileset IDs |
| `lib/firebase_options.dart` | Firebase project keys (auto-generated) |
| `android/app/google-services.json` | Android Firebase config |
| `ios/Runner/GoogleService-Info.plist` | iOS Firebase config |
| `ios/Flutter/Secrets.xcconfig` | iOS secrets |
| `functions/.env` | Cloud Functions environment variables |
| `functions_geoglows/.env` | Python Cloud Functions env vars (`NWM_API_KEY` for the NWM stream-conditions proxy) |
| `android/key.properties` | Android upload keystore path and passwords |

### Android Upload Keystore

The release signing keystore is **not in the repo**. It is backed up at:

**Google Drive (admin@hydromap.com) → `RIVR Release Keys/`**

Contents: `rivr-upload-keystore.jks` + `rivr-keystore-credentials.txt`

To set up signing on a new machine:
1. Download `rivr-upload-keystore.jks` from the Google Drive folder above
2. Create `android/key.properties` with the credentials from `rivr-keystore-credentials.txt`

Use `lib/services/0_config/shared/config.template.dart` and `android/local.properties.template` as references when setting up a new environment.

## Build & Run

```bash
flutter pub get                       # Install dependencies
flutter run                           # Run on connected device/emulator
flutter analyze                       # Static analysis
flutter test                          # Run tests
flutter build apk --debug             # Debug Android build
flutter build ios --no-codesign       # Debug iOS build (no signing)
make version                          # Stamp <year>.<major>.<minor>+<commits> — run on main only
make release-android                  # Signed release AAB with obfuscation (requires android/key.properties)
make release-ios                      # Release IPA with obfuscation
make upload-symbols                   # iOS dSYMs -> Crashlytics (run right after release-ios)
cd functions && npm install           # Install Cloud Functions deps (TypeScript "default" codebase)
cd functions && npm run build         # Build Cloud Functions
firebase deploy --only functions:default              # Deploy TypeScript functions
firebase deploy --only functions:geoglows             # Deploy Python functions (functions_geoglows/)
firebase deploy --only functions:geoglows:<name>      # Deploy one Python function (e.g. nwm_stream_conditions)
# NOTE: the geoglows_conditions_* schedulers are gone and flood colours come
# from the daily rivr-flooded-YYYYMMDD tileset. Four *_conditions_* functions
# are still deployed but dormant — minInstances 0, and no invocations since
# 2026-08-18, so they cost nothing. NOT "none in the last 30 days": they
# logged 253 in the 30 days to 2026-08-20 (correction in ADR 0005). Docs
# previously claimed they were deleted (ADR 0005).
```

### iOS release — three things that have each cost a build

**Versioning is `<year>.<major>.<minor>+<commit count>`**, stamped by
`make version` on `main` after merging. Never edit `pubspec.yaml` by hand: both
stores reject a repeated build number outright, and a derived one cannot be
forgotten. `make version MAJOR=1` / `MINOR=2` for the human part.

**Inspect the IPA, never the archive.** `flutter build ipa` re-signs during
export, so the archive reports `aps-environment: development` even when the
shipped artifact is correct. Push notifications were dead for six months partly
because of this. After every release build:

```bash
unzip -q build/ios/ipa/RIVR.ipa -d /tmp/ipa && \
codesign -d --entitlements :- /tmp/ipa/Payload/Runner.app \
  | plutil -convert xml1 -o - - | grep -A1 aps-environment
```

Expect **`production`**. Anything else means Xcode picked a development
provisioning profile — usually because no Apple Distribution certificate exists
for HydroMap LLC (Xcode → Settings → Apple Accounts → Manage Certificates).

**Crashlytics wants dSYMs, not the Dart symbol map.** `build/debug-info/` is
Dart's obfuscation map for `flutter symbolize`; Crashlytics will not take it, and
`firebase crashlytics:symbols:upload` is for Android NDK and fails on iOS either
way. Use `make upload-symbols`, which runs the Crashlytics binary from the SPM
checkout — it only exists after a build, so run it before `flutter clean`.

**Python venv:** `firebase.json` declares no runtime, so the CLI infers it from
`functions_geoglows/venv`. Rebuild it with **Python 3.13** — a 3.12 venv
silently migrates the deployed functions to a different runtime. Also note the
`geoglows` package takes ~12s to import, over the CLI's 10s budget for reading
function signatures, so it is imported lazily inside the one function that uses
it. Moving it back to module scope will break deploys.

### ADR 0011 cloud store (Phase 4, live since 2026-08-25)

Seven functions keep a Firestore `river_data` collection fresh for every
favourited reach, so the app reads one shared value instead of every widget
fetching its own. All seven are deployed as of 2026-08-25 (verified by count,
6 -> 7, not by the deploy's exit status).

| Function | Cadence |
|---|---|
| `storeRefreshHourly` | :20 past — refreshes ONLY products whose upstream run advanced |
| `storeGeoglowsDaily` | 01:30 UTC |
| `storeStaticDaily` | 02:30 UTC — river names + flood thresholds, only when missing or within 7 days of expiring |
| `storeGcDaily` | 03:40 UTC — 7-day grace, refuses a bulk delete |
| `storeHeartbeat` | 2-hourly, logs at ERROR when the store goes quiet |
| `storeHealth` | HTTPS — `{"status":"healthy"}` or 503 |
| `storeWriteThroughOnFavourite` | Firestore trigger on `users/{userId}` |

**The near-static products are not on the hourly cycle.** `reachMetadata` and
`returnPeriods` carry no run identity for the probe to compare and hold a
30-day window, so `storeStaticDaily` owns them and refetches only what is
missing or nearly expired. They are in the store at all because Phase 5 guard 1
is "a favourite renders with ZERO upstream calls from the device", and every
surface that renders a favourite reads the river's NAME and its THRESHOLDS —
without them the flow numbers stay fresh while each favourite still makes two
device-side calls just to draw itself.

**Phase 5's kill switch is `store_read_enabled` (Remote Config).** It is NOT
published by the flood builder and does NOT exist yet — it must be created by
hand in the Firebase console before the switch can be exercised at all. Absent,
`getBool` returns false, which is the safe default: every device takes the live
path. Set it to `true` to let devices read the store; flip to `false` and every open
app detaches its listeners and evicts every cached entry for a favourite, so
the live path takes over within seconds rather than after the stored window
expires (up to 30 days for river names and flood thresholds).

That eviction is deliberately broader than "what the store wrote" — cache
entries carry no provenance marker, and the switch means "the store may have
poisoned this", so paying a refetch is the right price. It fires only on the
ON -> OFF **transition** (persisted across launches), never while the switch is
merely off: doing it on the off *state* wiped the pinned favourites on every
`notifyListeners`, which made the app fetch more than it did before Phase 5.

**A change to the stored PAYLOAD SHAPE does not propagate until the upstream
run advances.** Supersession is keyed on `runId` alone: if the stored document
already carries the current run, `shouldWrite` refuses the rewrite even though
the new code would store a different shape. Observed 2026-08-25 — after the
ensemble-truncation fix, a forced refresh reported `written: 2,
skippedSameRun: 110` and every `mediumRange` document kept its old mean-only
payload until the next 6-hourly run. Plan for it: either wait for the cycle
(hourly products ≤1 h, medium/long ≤6 h, static products 30 days), or delete
the affected documents so they are re-fetched. Bumping
`RiverDataEntry.schemaVersion` also works but is a cross-language contract
change that makes every client discard every document.

**The store's fetchers never retry** — including these two, which is why they
do NOT go through `noaa-client`'s `fetchWithRetry` or `getReturnPeriods`. The
latter also falls back to a `return_period_cache` entry of any age, and writing
that into the store would stamp an arbitrarily old value with a fresh 30-day
window.

**Document IDs ARE the client's cache key** (`nwm__<reachId>__<product>`,
matching `RiverDataKey.storageKey`), and the envelope is exactly
`RiverDataEntry.toJson()`. Both are cross-language contracts pinned by tests
that read the Dart source off disk — a rename on either side fails the build
rather than silently storing documents the app never reads.

**Requires the composite index `river_data(product ASC, runId ASC)`.** Without
it every hourly run aborts on FAILED_PRECONDITION. Declared in
`firestore.indexes.json` and created in production.

**"No new run means zero fetches" is the whole point.** If upstream has not
published, the run does nothing — verified through a real five-hour NOAA stall.

**Never add retries to the store's fetchers.** A transient failure is recorded
per reach and retried next cycle. Retrying inside a run hides the failure rate
the Phase 0 probe exists to measure, and hammers whatever is already failing.

**Release tracking:** When bumping the version or build number in `pubspec.yaml`, add an entry to `app_releases.md` at the project root.
**Cloud Functions tracking:** When deploying Cloud Functions, add an entry to `notifications_history.md` at the project root.
