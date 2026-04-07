# RIVR Architecture Migration Roadmap
**Audit:** `04-06-2026-architecture-audit.md`
**Target pattern:** Oqupa Flutter Architecture Guide (Models → Services → UI)
**State management:** Keeping Provider/ChangeNotifier
**Start date:** April 6, 2026

---

## Phase 1 — Foundation: ServiceResult + Infrastructure

Establish the error handling pattern and shared infrastructure that every subsequent phase depends on.

- [x] Create `ServiceResult<T>` class with `success()`, `failure()`, `map()`, and `then()` methods *(2026-04-06 10:30)*
- [x] Create `ServiceException` class with `ServiceErrorType` enum (network, auth, validation, notFound, unknown, etc.) *(2026-04-06 10:30)*
- [x] Add `ServiceResult` unit tests (success, failure, map, chaining) *(2026-04-06 10:35)*
- [x] Migrate `Failure` types to work with or be replaced by `ServiceResult` *(2026-04-06 10:40)*
- [x] Create `models/1_domain/shared/entities/` directory and placeholder structure *(2026-04-06 10:45)*
- [x] Create `services/4_infrastructure/shared/` directory with `ServiceResult` and base classes *(2026-04-06 10:45)*
- [x] Decide on numbered folder convention (adopt or skip) and document the decision — **adopted numbered folders** *(2026-04-06 10:45)*

---

## Phase 2 — Proof of Concept: Settings Feature (Simplest)

Migrate the simplest feature end-to-end to validate the pattern before tackling complex features.

- [x] Extract `SettingsFirestoreDatasource` from `UserSettingsService` (raw Firestore calls only) *(2026-04-06 11:30)*
- [x] ~~Extract `SettingsLocalDatasource`~~ — N/A: no SharedPreferences usage; in-memory cache stays in `UserSettingsService` *(2026-04-06 11:30)*
- [x] Create `SettingsRepositoryImpl` as coordinator (error mapping to `ServiceResult`) implementing `ISettingsRepository` *(2026-04-06 11:35)*
- [x] Update settings use cases to return `ServiceResult<T>` instead of raw types *(2026-04-06 11:35)*
- [x] Update `ISettingsRepository` contract to return `ServiceResult<T>` *(2026-04-06 11:35)*
- [x] Remove old `SettingsRepository` thin wrapper (replaced by `SettingsRepositoryImpl`) *(2026-04-06 11:35)*
- [x] Update settings-related tests for new datasource + coordinator pattern (8 datasource + 14 repository tests) *(2026-04-06 11:40)*
- [x] Verify settings feature works end-to-end — `flutter analyze` clean, 66/66 unit tests pass *(2026-04-06 11:45)*

---

## Phase 3 — Auth Feature Migration

Auth is the second simplest — Firebase Auth + biometric auth, no caching complexity.

- [x] Extract `AuthFirebaseDatasource` from `AuthService` (Firebase Auth SDK calls only) *(2026-04-06 12:00)*
- [x] Extract `BiometricDatasource` from `AuthService` (local_auth + secure storage calls only) *(2026-04-06 12:00)*
- [x] Create `AuthRepositoryImpl` as coordinator implementing `IAuthRepository` *(2026-04-06 12:10)*
- [x] Update auth use cases to return `ServiceResult<T>` (7 use cases + GetAuthState unchanged) *(2026-04-06 12:10)*
- [x] Update `IAuthRepository` contract to return `ServiceResult<T>` *(2026-04-06 12:10)*
- [x] Remove old `AuthRepository` thin wrapper (replaced by `AuthRepositoryImpl`) *(2026-04-06 12:10)*
- [x] Update auth-related tests (20 new repository tests, 33 existing auth tests passing) *(2026-04-06 12:15)*
- [x] Verify auth flows — `flutter analyze` clean, 433/433 unit tests pass *(2026-04-06 12:20)*

---

## Phase 4 — Entity/DTO Separation

Untangle the core models from serialization concerns. This phase can be done independently of feature migrations.

- [x] Create pure `ReachData` entity (immutable, no `fromJson`/`fromNoaaApi`/`toJson`, no framework imports) *(2026-04-06)*
- [x] Create `ReachDataDto` with parsing logic (`fromNoaaApi`, `fromReturnPeriodApi`, `fromJson`, `toJson`, `toEntity()`) *(2026-04-06)*
- [x] Move unit conversion out of `ReachData` into a utility or domain service *(2026-04-06 — getReturnPeriodsInUnit, getFlowCategory, getNextThreshold accept IFlowUnitPreferenceService param; ForecastSeries.convertToUnit replaces withPreferredUnits)*
- [x] Create pure `FavoriteRiver` entity (remove `toJson`, `fromJson`, GetIt dependency) *(2026-04-06)*
- [x] Create `FavoriteRiverDto` with JSON serialization *(2026-04-06)*
- [x] Create pure `UserSettings` entity (remove `fromJson`, `toJson`) *(2026-04-06)*
- [x] Create `UserSettingsDto` with serialization *(2026-04-06)*
- [x] Update all consumers of these models to use entities (UI) or DTOs (datasources) *(2026-04-06)*
- [x] Update `fake_data.dart` test helpers for new entity/DTO split *(2026-04-06 — no changes needed, uses constructors directly)*
- [x] Update all model tests for the separated types *(2026-04-06 — 37 new DTO tests, all existing tests updated)*

---

## Phase 5 — Forecast Feature Migration

Forecast is the most complex service — phased loading, multi-source caching, unit conversion.

- [x] ~~Extract `ForecastApiDatasource`~~ — N/A: `INoaaApiService` already serves as the API datasource with a clean interface *(2026-04-06)*
- [x] ~~Extract `ForecastCacheDatasource`~~ — N/A: `IReachCacheService` already serves as the cache datasource with a clean interface *(2026-04-06)*
- [x] Create `ForecastRepositoryImpl` as coordinator (wraps `IForecastService` with `ServiceResult` error handling) *(2026-04-06)*
- [x] Update forecast use cases to return `ServiceResult<T>` (5 existing + 1 new `LoadSpecificForecastUseCase`) *(2026-04-06)*
- [x] Update `IForecastRepository` contract to return `ServiceResult<T>` + add `loadSpecificForecast` method *(2026-04-06)*
- [x] Remove old `ForecastRepository` thin wrapper (replaced by `ForecastRepositoryImpl`) *(2026-04-06)*
- [x] Update `ReachDataProvider` to use use cases instead of direct service calls (kept `IForecastService` for computed-value methods in mixin) *(2026-04-06)*
- [x] Update `GetReachDetailsForMapUseCase` to return `ServiceResult<T>` *(2026-04-06)*
- [x] Update forecast-related tests (14 new repository tests, integration test helpers updated for use case DI) *(2026-04-06)*
- [x] Verify forecast flows — `flutter analyze` clean, 484/484 unit tests pass *(2026-04-06)*

---

## Phase 6 — Favorites Feature Migration

Favorites depends on forecast data and has the most complex provider.

- [x] ~~Extract `FavoritesFirestoreDatasource`~~ — N/A: `IFavoritesService` already serves as the datasource with a clean interface *(2026-04-06)*
- [x] Create `FavoritesRepositoryImpl` as coordinator implementing `IFavoritesRepository` (aggregates 5 services, includes return-period merging logic) *(2026-04-06)*
- [x] Update favorites use cases to return `ServiceResult<T>` (7 use cases updated) *(2026-04-06)*
- [x] Update `IFavoritesRepository` contract to return `ServiceResult<T>` *(2026-04-06)*
- [x] Remove old `FavoritesRepository` thin wrapper (replaced by `FavoritesRepositoryImpl`) *(2026-04-06)*
- [x] Rewire `FavoritesProvider` to use 4 CRUD use cases (kept direct service refs for complex refresh orchestration) *(2026-04-06)*
- [x] Update favorites-related tests (19 new repository tests, integration test helpers updated for use case DI) *(2026-04-06)*
- [x] Verify favorites flows — `flutter analyze` clean, 503/503 unit tests pass *(2026-04-06)*

---

## Phase 7 — Map Feature Migration

Map has the least domain logic — primarily UI services. Light migration.

- [x] Evaluate map services — all are Mapbox SDK / UI infrastructure (VectorTiles, ReachSelection, Marker, Controls, Search); no datasource extraction needed *(2026-04-06)*
- [x] ~~Extract datasource logic~~ — N/A: map services are UI-scoped (Mapbox SDK wrappers), not domain datasources *(2026-04-06)*
- [x] Update `GetReachDetailsForMapUseCase` to return `ServiceResult<T>` *(completed in Phase 5)*
- [x] Rewire `ReachDetailsBottomSheet` to use `GetReachDetailsForMapUseCase` instead of direct `IForecastService` call *(2026-04-06)*
- [x] Verify map feature — `flutter analyze` clean, 503/503 unit tests pass *(2026-04-06)*

---

## Phase 8 — Folder Restructure

Move files into the `models/` + `services/` + `ui/` layout. Do this as a single atomic operation per layer.

- [x] Create target directory structure (`models/`, `services/`, `ui/`, `utils/`) *(2026-04-06)*
- [x] Move domain entities to `models/1_domain/shared/` and `models/1_domain/features/` *(2026-04-06)*
- [x] Move use cases to `models/2_usecases/features/` *(2026-04-06)*
- [x] Move config to `services/0_config/shared/` *(2026-04-06)*
- [x] Move repository interfaces to `services/1_contracts/features/` *(2026-04-06)*
- [x] Move coordinators to `services/2_coordinators/features/` *(2026-04-06)*
- [x] Move datasources to `services/3_datasources/features/` *(2026-04-06)*
- [x] Move infrastructure services to `services/4_infrastructure/` (grouped by technical domain) *(2026-04-06)*
- [x] Move DI to `services/5_injection/` *(2026-04-06)*
- [x] Move providers to `ui/1_state/` *(2026-04-06)*
- [x] Move pages and widgets to `ui/2_presentation/` *(2026-04-06)*
- [x] Move routing to `ui/2_presentation/routing/` *(2026-04-06)*
- [x] Move shared widgets to `ui/2_presentation/shared/` *(2026-04-06)*
- [x] Move utils to `utils/` *(2026-04-06)*
- [x] Fix all import paths (scripted: Python relative→absolute + sed bulk replacement + bare-filename resolution) *(2026-04-06)*
- [x] Update test file locations to mirror new structure (27 test files moved) *(2026-04-06)*
- [x] Run `flutter analyze` — zero issues *(2026-04-06)*
- [x] Run `flutter test` — 503/503 unit tests pass (25 pre-existing integration test failures unchanged) *(2026-04-06)*

---

## Phase 9 — DI Reorganization + Provider Rewiring

Split the single DI file into feature-based registration and ensure providers use use cases.

- [x] Create `services/5_injection/dependency_container.dart` (orchestrator) *(2026-04-06)*
- [x] Create per-feature DI files: `shared_dependencies.dart`, `auth_dependencies.dart`, `favorites_dependencies.dart`, `forecast_dependencies.dart`, `map_dependencies.dart`, `settings_dependencies.dart` *(2026-04-06)*
- [x] Add guard clauses to prevent double registration *(2026-04-06)*
- [x] Rewire `AuthProvider` to use `IAuthRepository` + 8 use cases (removed direct `IAuthService` + `IUserSettingsService` usage) *(2026-04-06)*
- [x] Rewire `FavoritesProvider` to use `GetFavoriteFlowUseCase` (removed direct `INoaaApiService` + `_loadReturnPeriods()` usage) *(2026-04-06)*
- [x] `ReachDataProvider` already uses use cases — no changes needed *(2026-04-06)*
- [x] Add `sendEmailVerification` + `checkEmailVerified` to `IAuthRepository` and `AuthRepositoryImpl` *(2026-04-06)*
- [x] Create `GetFavoriteFlowUseCase` (delegates to `IFavoritesRepository.getFlowData`) *(2026-04-06)*
- [x] Remove old `service_locator.dart` *(2026-04-06)*
- [x] Update `auth_provider_test.dart` to use mock `IAuthRepository` + use cases *(2026-04-06)*
- [x] Update integration test helpers (`test_app.dart`) for new DI and provider constructors *(2026-04-06)*
- [x] Add 6 tests for `sendEmailVerification` + `checkEmailVerified` on `AuthRepositoryImpl` *(2026-04-06)*
- [x] Run full test suite — 509/509 pass *(2026-04-06)*
- [x] Run `flutter analyze` — zero issues *(2026-04-06)*

---

## Phase 10 — Cleanup + Documentation

- [ ] Audit for any remaining cross-feature imports and fix them
- [ ] Remove unused service interfaces that were replaced by datasources
- [ ] Update `CLAUDE.md` to reflect new architecture and folder structure
- [ ] Update `docs/rubric.md` if applicable
- [ ] Run a fresh architecture audit against the rubric and record new score
- [ ] Update `MEMORY.md` with new architecture patterns and file paths

---

## Completion Criteria

When all phases are complete:
- Every service is decomposed into datasource(s) + coordinator
- Every use case returns `ServiceResult<T>`
- Every model has entity/DTO separation (at minimum for `ReachData`, `FavoriteRiver`, `UserSettings`)
- Files live in `models/` + `services/` + `ui/` + `utils/` structure
- No cross-feature imports
- All tests pass
- `flutter analyze` is clean
