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

Feature-based modular architecture with a shared core layer:

```
lib/
  main.dart                     -- Entry point, MultiProvider setup, CupertinoApp routing
  firebase_options.dart         -- Auto-generated Firebase config (gitignored)
  core/                         -- Shared infrastructure
    config.dart                 -- API keys and URLs (gitignored, use config.template.dart)
    constants.dart              -- Forecast definitions, color/icon helpers
    models/                     -- ReachData, FavoriteRiver, UserSettings
    providers/                  -- FavoritesProvider, ReachDataProvider, ThemeProvider
    services/                   -- AuthService, ForecastService, NoaaApiService, FCMService, etc.
    routing/                    -- Auth guard for route protection
    widgets/                    -- Shared widgets (NavigationButton)
    utils/                      -- Shared utilities
  features/
    auth/                       -- Authentication (presentation/pages, presentation/widgets, providers, services, models)
    favorites/                  -- Favorites management (app home screen, pages, widgets, services)
    forecast/                   -- Flow forecasting (domain/entities, pages, services, utils, complex widget hierarchy)
    map/                        -- Interactive Mapbox map (models, services, widgets/components)
    settings/                   -- User preferences (pages, widgets)
functions/                      -- Firebase Cloud Functions (TypeScript)
  src/index.ts                  -- Cloud Function entry points
  src/notification-service.ts   -- Push notification logic
  src/noaa-client.ts            -- Server-side NOAA API client
```

### Key Patterns

- **Singleton services:** Factory constructor + private `_internal()` (e.g., AuthService, NoaaApiService)
- **Provider pattern:** Providers extend ChangeNotifier, registered in main.dart via MultiProvider
- **Service layer:** Providers manage state; services handle I/O and business logic
- **Phased data loading:** ForecastService uses loadOverviewData -> loadSupplementaryData -> loadCompleteReachData
- **Unit conversion:** All forecast data converted at the API layer (NoaaApiService) before reaching UI

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
- Cross-feature: `package:rivr/...` (full package imports)
- Within same feature: relative imports (`../services/auth_service.dart`)

### Debug Logging
- Service-specific prefixes: `'NOAA_API:'`, `'AUTH_PROVIDER:'`, `'FORECAST_SERVICE:'`, `'CACHE_SERVICE:'`

## Testing

### Structure
Tests mirror the `lib/` directory structure:

```
test/
  core/
    models/         -- Unit tests for data models
    providers/      -- Unit tests for providers
    services/       -- Unit tests for services
    routing/        -- Tests for auth guard
    widgets/        -- Widget tests for shared widgets
  features/
    auth/           -- Mirrors lib/features/auth/ structure
    favorites/      -- Mirrors lib/features/favorites/ structure
    forecast/       -- Mirrors lib/features/forecast/ structure
    map/            -- Mirrors lib/features/map/ structure
    settings/       -- Mirrors lib/features/settings/ structure
  helpers/
    test_helpers.dart   -- pumpApp() wrapper with mock providers
    fake_data.dart      -- Factory methods for test data
integration_test/       -- End-to-end integration tests
```

### Test Priority
1. Pure models (ReachData, FavoriteRiver, UserSettings) -- no dependencies, highest logic density
2. Services with mocks (NoaaApiService, ForecastService, ErrorService) -- core business logic
3. Providers (FavoritesProvider, AuthProvider) -- state management correctness
4. Widget tests (LoginPage, FavoritesPage, ReachOverviewPage) -- critical user flows
5. Integration tests -- end-to-end confidence

### Running Tests
```bash
flutter test                          # All unit and widget tests
flutter test test/core/models/        # Just model tests
flutter test --coverage               # With coverage report
flutter test integration_test/        # Integration tests
```

## Key File Paths

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point, provider registration, route definitions |
| `lib/core/config.dart` | API keys and URLs (**gitignored** -- create from config.template.dart) |
| `lib/core/constants.dart` | Non-sensitive constants, forecast definitions |
| `lib/core/models/reach_data.dart` | Core data model for river reaches (800+ lines, parsing/conversion) |
| `lib/core/services/forecast_service.dart` | Central forecast loading, caching, phased loading |
| `lib/core/services/noaa_api_service.dart` | All NOAA API calls with unit conversion |
| `lib/core/providers/favorites_provider.dart` | Primary state management for favorites |
| `lib/features/auth/providers/auth_provider.dart` | Authentication state |
| `lib/core/services/auth_service.dart` | Firebase Auth + biometric auth wrapper |
| `lib/core/services/fcm_service.dart` | Firebase Cloud Messaging token management |
| `lib/features/map/map_page.dart` | Mapbox map integration |
| `lib/firebase_options.dart` | Firebase config (**gitignored**) |
| `functions/src/index.ts` | Cloud Functions entry point |
| `.firebaserc` | Firebase project ID (ciroh-rivr-app) |
| `pubspec.yaml` | Dependencies, assets, SDK constraints |

## Security

The following files contain secrets and are **gitignored**:

| File | Contains |
|------|----------|
| `lib/core/config.dart` | Mapbox token, NWM API URLs, vector tileset IDs |
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

Use `lib/core/config.template.dart` and `android/local.properties.template` as references when setting up a new environment.

## Build & Run

```bash
flutter pub get                       # Install dependencies
flutter run                           # Run on connected device/emulator
flutter analyze                       # Static analysis
flutter test                          # Run tests
flutter build apk --debug             # Debug Android build
flutter build appbundle --release     # Signed release AAB (requires android/key.properties)
flutter build ios --no-codesign       # Debug iOS build (no signing)
cd functions && npm install           # Install Cloud Functions deps
cd functions && npm run build         # Build Cloud Functions
firebase deploy --only functions      # Deploy Cloud Functions
```
