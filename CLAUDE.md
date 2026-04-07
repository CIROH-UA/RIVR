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
functions/                               -- Firebase Cloud Functions (TypeScript)
  src/index.ts                           -- Cloud Function entry points
  src/notification-service.ts            -- Push notification logic
  src/noaa-client.ts                     -- Server-side NOAA API client
```

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
make release-android                  # Signed release AAB with obfuscation (requires android/key.properties)
make release-ios                      # Release IPA with obfuscation
cd functions && npm install           # Install Cloud Functions deps
cd functions && npm run build         # Build Cloud Functions
firebase deploy --only functions      # Deploy Cloud Functions
```

**Release tracking:** When bumping the version or build number in `pubspec.yaml`, add an entry to `app_releases.md` at the project root.
**Cloud Functions tracking:** When deploying Cloud Functions, add an entry to `notifications_history.md` at the project root.
