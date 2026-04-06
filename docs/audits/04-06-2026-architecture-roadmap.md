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

- [ ] Create pure `ReachData` entity (immutable, no `fromJson`/`fromNoaaApi`/`toJson`, no framework imports)
- [ ] Create `ReachDataDto` with parsing logic (`fromNoaaApi`, `fromReturnPeriodApi`, `fromJson`, `toJson`, `toEntity()`)
- [ ] Move unit conversion out of `ReachData` into a utility or domain service
- [ ] Create pure `FavoriteRiver` entity (remove `toFirestoreMap`, `fromFirestore`)
- [ ] Create `FavoriteRiverDto` with Firestore serialization
- [ ] Create pure `UserSettings` entity (remove `fromJson`, `toJson`)
- [ ] Create `UserSettingsDto` with serialization
- [ ] Update all consumers of these models to use entities (UI) or DTOs (datasources)
- [ ] Update `fake_data.dart` test helpers for new entity/DTO split
- [ ] Update all model tests for the separated types

---

## Phase 5 — Forecast Feature Migration

Forecast is the most complex service — phased loading, multi-source caching, unit conversion.

- [ ] Extract `ForecastApiDatasource` from `ForecastService` + `NoaaApiService` (raw NOAA/NWM HTTP calls)
- [ ] Extract `ForecastCacheDatasource` from `ForecastService` + `ReachCacheService` (file-based cache reads/writes)
- [ ] Create `ForecastRepositoryImpl` as coordinator (phased loading strategy, cache-then-network, TTL management)
- [ ] Update forecast use cases to return `ServiceResult<T>`
- [ ] Update `IForecastRepository` contract to return `ServiceResult<T>`
- [ ] Remove old `ForecastRepository` thin wrapper
- [ ] Update `ReachDataProvider` to use use cases instead of direct service calls
- [ ] Update forecast-related tests (service mocks → datasource mocks)
- [ ] Verify forecast flows end-to-end (overview load, supplementary load, complete load, refresh)

---

## Phase 6 — Favorites Feature Migration

Favorites depends on forecast data and has the most complex provider.

- [ ] Extract `FavoritesFirestoreDatasource` from `FavoritesService` (Firestore CRUD for favorites)
- [ ] Create `FavoritesRepositoryImpl` as coordinator implementing `IFavoritesRepository`
- [ ] Update favorites use cases to return `ServiceResult<T>`
- [ ] Update `IFavoritesRepository` contract to return `ServiceResult<T>`
- [ ] Remove old `FavoritesRepository` thin wrapper
- [ ] Rewire `FavoritesProvider` to call use cases instead of services directly
- [ ] Update favorites-related tests
- [ ] Verify favorites flows end-to-end (load, add, remove, reorder, refresh)

---

## Phase 7 — Map Feature Migration

Map has the least domain logic — primarily UI services. Light migration.

- [ ] Evaluate which map services are datasources vs. infrastructure vs. UI-only
- [ ] Extract any datasource logic if applicable (geocoding, vector tile config)
- [ ] Update `GetReachDetailsForMapUseCase` to return `ServiceResult<T>`
- [ ] Update map-related tests
- [ ] Verify map feature works end-to-end

---

## Phase 8 — Folder Restructure

Move files into the `models/` + `services/` + `ui/` layout. Do this as a single atomic operation per layer.

- [ ] Create target directory structure (`models/`, `services/`, `ui/`, `utils/`)
- [ ] Move domain entities to `models/1_domain/shared/entities/` and `models/1_domain/features/`
- [ ] Move use cases to `models/2_usecases/features/`
- [ ] Move config to `services/0_config/shared/`
- [ ] Move repository interfaces to `services/1_contracts/features/`
- [ ] Move coordinators to `services/2_coordinators/features/`
- [ ] Move datasources to `services/3_datasources/features/`
- [ ] Move infrastructure services to `services/4_infrastructure/` (grouped by technical domain)
- [ ] Move DI to `services/5_injection/`
- [ ] Move providers to `ui/1_state/`
- [ ] Move pages and widgets to `ui/2_presentation/`
- [ ] Move routing to `ui/2_presentation/routing/`
- [ ] Move shared widgets to `ui/2_presentation/shared/`
- [ ] Move utils to `utils/`
- [ ] Fix all import paths (use IDE refactoring)
- [ ] Update test file locations to mirror new structure
- [ ] Run `flutter analyze` — zero issues
- [ ] Run `flutter test` — all tests pass

---

## Phase 9 — DI Reorganization + Provider Rewiring

Split the single DI file into feature-based registration and ensure providers use use cases.

- [ ] Create `services/5_injection/dependency_container.dart` (orchestrator)
- [ ] Create per-feature DI files: `auth_dependencies.dart`, `favorites_dependencies.dart`, `forecast_dependencies.dart`, `map_dependencies.dart`, `settings_dependencies.dart`
- [ ] Add guard clauses to prevent double registration
- [ ] Verify `AuthProvider` calls use cases (not services directly)
- [ ] Verify `FavoritesProvider` calls use cases (not services directly)
- [ ] Verify `ReachDataProvider` calls use cases (not services directly)
- [ ] Remove old `service_locator.dart`
- [ ] Run full test suite — all pass
- [ ] Run `flutter analyze` — zero issues

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
