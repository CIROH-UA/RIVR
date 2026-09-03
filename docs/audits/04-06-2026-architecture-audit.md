# RIVR Architecture Audit — Oqupa Pattern Comparison
**Date:** April 6, 2026
**Reference:** `Oqupa-Platform/oqupa/docs/flutter-architecture-guide.md`
**Prior audit:** `04-03-2026.md` (459/1000, Clean Architecture scored 14/90)

---

## Purpose

Compare RIVR's current architecture against the Oqupa Flutter Architecture Guide (Models → Services → UI) and assess what a migration would involve. This audit does not score on a rubric — it maps the gap between where RIVR is and where the Oqupa pattern would take it, and identifies risks and dependencies.

---

## Current State Summary

RIVR has evolved significantly since the April 3 audit (14/90 → substantial clean architecture work completed):

| Completed Since Last Audit | Status |
|---|---|
| Domain layer (`Failure` types, `UseCase<Out, Params>` base) | Done |
| Repository interfaces for all 5 features | Done |
| Repository implementations (thin wrappers around services) | Done |
| 26 use cases across auth, favorites, forecast, map, settings | Done |
| GetIt service locator with interface-based DI | Done |
| 15+ services with `I*` abstract interfaces | Done |
| Generation-based request cancellation | Done |
| File-based caching (replaced SharedPreferences for reach data) | Done |

**Current folder structure:**
```
lib/
├── main.dart
├── core/
│   ├── di/service_locator.dart          ← Single DI file (~200 lines)
│   ├── domain/
│   │   ├── failures/failure.dart        ← Failure base + 3 subtypes
│   │   └── usecases/base_usecase.dart   ← UseCase<Out, Params> interface
│   ├── models/                          ← 7 models (mixed entity + DTO concerns)
│   ├── providers/                       ← 4 ChangeNotifier providers
│   ├── services/                        ← 15+ interface + implementation pairs
│   ├── routing/
│   ├── widgets/
│   └── utils/
├── features/
│   ├── auth/
│   │   ├── domain/repositories/ + usecases/
│   │   ├── data/repositories/
│   │   ├── models/
│   │   ├── providers/
│   │   └── presentation/pages/ + widgets/
│   ├── favorites/
│   │   ├── domain/repositories/ + usecases/
│   │   ├── data/repositories/
│   │   ├── pages/ + widgets/ + services/
│   ├── forecast/
│   │   ├── domain/entities/ + repositories/ + usecases/
│   │   ├── data/repositories/
│   │   ├── pages/ + widgets/ + services/ + utils/
│   ├── map/
│   │   ├── domain/usecases/
│   │   ├── models/ + services/ + widgets/
│   └── settings/
│       ├── domain/repositories/ + usecases/
│       ├── data/repositories/
│       └── pages/ + widgets/
```

---

## Gap Analysis: RIVR vs. Oqupa Pattern

### 1. Top-Level Organization

| Oqupa | RIVR | Gap |
|---|---|---|
| `models/` (domain + usecases) | `core/domain/` + `core/models/` + `features/*/domain/` | Domain scattered across core and features |
| `services/` (config → contracts → coordinators → datasources → infrastructure → injection) | `core/services/` (flat, monolithic) + `features/*/data/` | No layered service decomposition |
| `ui/` (state + presentation) | `core/providers/` + `features/*/pages/` + `features/*/widgets/` | No unified UI layer |
| `utils/` | `core/utils/` + `features/*/utils/` | Minor — just a relocation |

**Assessment:** The top-level restructure from `core/` + `features/` to `models/` + `services/` + `ui/` is the most visible change. Every import path changes. This is mechanical but touches every file.

### 2. Models Layer

| Oqupa | RIVR | Gap |
|---|---|---|
| `1_domain/shared/entities/` — pure Dart, no framework imports | `core/models/` — mixed with serialization (`fromJson`, `fromNoaaApi`, `toJson`) | Models are DTOs and entities combined |
| `1_domain/shared/value_objects/` — typed wrappers with validation | None | No value objects |
| `1_domain/features/` — feature-specific entities | `features/forecast/domain/entities/` only | Only forecast has feature-level entities |
| `2_usecases/features/` — one class, one `execute()` method | `features/*/domain/usecases/` — one class, one `call()` method | Equivalent (minor naming difference) |

**Key gap: ReachData (800+ lines)** is both entity and DTO. In the Oqupa model:
- Pure `ReachData` entity in `models/1_domain/shared/entities/` (immutable, no parsing)
- `ReachDataDto` or parsing logic in a datasource (`fromNoaaApi`, `fromJson`)
- Unit conversion as a utility or domain service

**Other mixed models:**
- `FavoriteRiver` — has `toFirestoreMap()` and `FavoriteRiver.fromFirestore()`
- `UserSettings` — has `fromJson()` / `toJson()` for Firestore serialization
- `HourlyFlowData`, `ForecastChartData` — presentation-adjacent, may belong in UI layer

### 3. Services Layer

| Oqupa Layer | Purpose | RIVR Equivalent | Gap |
|---|---|---|---|
| `0_config/` | Environment settings, API keys | `core/config.dart` (gitignored) | Exists but not structured as a layer |
| `1_contracts/` | Repository interfaces | `features/*/domain/repositories/i_*.dart` | Exists but lives in domain, not services |
| `2_coordinators/` | Cache strategy, offline behavior, error mapping | None — logic is in monolithic services | **Major gap** |
| `3_datasources/` | Raw API/Firestore/local calls | None — services do everything | **Major gap** |
| `4_infrastructure/` | Platform SDKs, shared technical services | `core/services/` (mixed with business logic) | Exists but not separated |
| `5_injection/` | Feature-based DI registration | `core/di/service_locator.dart` (single file) | Exists but not feature-based |

**This is the largest gap.** RIVR's services are monolithic. For example:

`ForecastService` currently handles:
- API call orchestration (datasource concern)
- In-memory caching with TTL (coordinator concern)
- Phased loading strategy (coordinator concern)
- Unit conversion at intake (utility concern)

In the Oqupa model, this becomes:
- `ForecastApiDatasource` — raw NOAA API calls
- `ForecastRepositoryImpl` (coordinator) — cache-then-network strategy, phased loading
- Shared infrastructure — HTTP client, cache storage

Similarly, `FavoritesService` mixes Firestore calls with favorites business logic, and `AuthService` mixes Firebase Auth with biometric auth.

### 4. UI Layer

| Oqupa | RIVR | Gap |
|---|---|---|
| `1_state/` — BLoC/Cubit per feature | `core/providers/` + `features/auth/providers/` — Provider/ChangeNotifier | Different state management (keeping Provider is fine) |
| `2_presentation/shared/widgets/` | `core/widgets/` | Equivalent |
| `2_presentation/shared/theme/` | `ThemeProvider` in `core/providers/` | Exists differently |
| `2_presentation/features/` | `features/*/pages/` + `features/*/widgets/` | Scattered but functional |
| `2_presentation/routing/` | `core/routing/app_router.dart` | Equivalent |

**Assessment:** Since we're keeping Provider, this layer's migration is mostly folder reorganization, not rewriting state management. Providers move from `core/providers/` and `features/*/providers/` into `ui/1_state/`.

### 5. Error Handling

| Oqupa | RIVR | Gap |
|---|---|---|
| `ServiceResult<T>` wrapper everywhere | Raw `Future<T>`, throw exceptions, `Failure` types exist but unused by services | **Significant gap** |
| Errors flow: datasource → coordinator → use case → state → UI | Errors: service throws → provider catches → UI reads `errorMessage` | Ad-hoc, no consistent pattern |

**Assessment:** RIVR has `Failure` types (`NetworkFailure`, `CacheFailure`, `AuthFailure`) but they're not used as return types. Services throw exceptions. Providers catch and set `errorMessage` strings. Adopting `ServiceResult<T>` would make error handling explicit at every layer boundary.

### 6. Dependency Injection

| Oqupa | RIVR | Gap |
|---|---|---|
| Feature-based registration files under `5_injection/features/` | Single `service_locator.dart` (~200 lines) | Works but doesn't scale |
| `DependencyContainer.initialize()` orchestrates order | `setupServiceLocator()` does everything sequentially | Equivalent at current scale |
| Guard clauses prevent double registration | None | Minor risk |

**Assessment:** Current DI works fine for 5 features. Feature-based injection files become valuable at 10+ features. Low priority for now.

### 7. Import Rules

| Oqupa Rule | RIVR Status |
|---|---|
| Models never import from Services or UI | Violated — `ReachData` has serialization concerns |
| Services never import from UI | Respected |
| Features never import from other features | Needs verification — likely some cross-feature imports exist |
| Only `5_injection/` sees everything | `service_locator.dart` sees everything (equivalent) |

### 8. Numbered Folders

Oqupa uses `1_domain/`, `2_usecases/`, `0_config/`, etc. to enforce visual hierarchy in the IDE. This is a convention choice. RIVR can adopt it or use a non-numbered equivalent — the architectural benefits are identical either way.

---

## Dependency and Risk Map

### What Depends on What (Migration Order Constraints)

```
ServiceResult<T> pattern      ← Foundation, everything else depends on this
    ↓
Entity/DTO separation         ← ReachData decomposition, affects all features
    ↓
Datasource extraction         ← Split services into datasource + coordinator
    ↓
Coordinator creation          ← Implement contracts using datasources
    ↓
Provider rewiring             ← Providers call use cases instead of services directly
    ↓
Folder restructure            ← Move files into models/services/ui layout
    ↓
Feature-based DI              ← Split service_locator.dart into per-feature files
```

### Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| **ReachData decomposition** breaks 800+ lines of tightly coupled code | High | Do it in isolation first, behind the same public API, with comprehensive tests |
| **Import path changes** touch every file when folders move | Medium | Do the folder restructure as a single atomic commit; use IDE refactoring tools |
| **Existing 35+ tests break** when services split into datasources + coordinators | Medium | Migrate one feature at a time; update tests per feature before moving on |
| **Providers need rewiring** to call use cases instead of services | Medium | Use cases already exist but providers bypass them; gradual rewiring per feature |
| **Cross-feature imports** may exist and need untangling | Low | Audit imports before restructuring; promote shared code to `shared/` |
| **ServiceResult adoption** changes every return type in the service layer | Medium | Introduce alongside existing pattern; migrate one service at a time |

---

## What RIVR Can Skip from Oqupa

| Oqupa Concept | Recommendation for RIVR | Reason |
|---|---|---|
| BLoC/Cubit state management | **Skip** — keep Provider/ChangeNotifier | Works well for RIVR's complexity; avoids rewriting every screen and test |
| Value objects (`Email`, `PhoneNumber`) | **Skip for now** | RIVR has minimal user input (search, auth) — add value objects when input validation becomes complex |
| `freezed` / `Equatable` for immutability | **Optional** — evaluate after entity separation | RIVR models already use `copyWith()`; `Equatable` adds boilerplate for little gain at 7 models |
| Numbered folder prefixes (`1_domain/`, `2_usecases/`) | **Adopt or skip** — purely cosmetic | The visual ordering is helpful but not architecturally necessary |
| Coordinator layer (separate from datasource) | **Adopt selectively** | Only where caching/offline strategy exists (ForecastService, ReachCacheService); skip for simple pass-through services |

---

## What RIVR Should Adopt from Oqupa

| Oqupa Concept | Priority | Reason |
|---|---|---|
| `ServiceResult<T>` error handling | **High** | Eliminates thrown exceptions across layer boundaries; makes error handling explicit |
| Entity/DTO separation | **High** | `ReachData` is the most-touched file; separating concerns makes it maintainable |
| Datasource extraction | **High** | Monolithic services are the #1 testability and maintainability bottleneck |
| `models/` + `services/` + `ui/` top-level structure | **Medium** | Clearer than `core/` + `features/` hybrid; aligns mental model with Oqupa |
| Feature-based DI registration | **Low** | Current single file works; split when it exceeds ~300 lines |
| `shared/` vs `features/` within each layer | **Medium** | Already partially done; formalize the rule |
| Strict import rules (no cross-feature imports) | **Medium** | Enforce via code review; consider a lint rule later |

---

## Estimated Scope

| Phase | Files Created | Files Modified | Files Deleted | Tests Affected |
|---|---|---|---|---|
| Phase 1: ServiceResult + Foundation | ~5 new | ~10 | 0 | ~5 updated |
| Phase 2: Service Decomposition (settings) | ~4 new | ~6 | 0 | ~8 updated |
| Phase 3: Service Decomposition (remaining) | ~15 new | ~20 | 0 | ~20 updated |
| Phase 4: Entity/DTO Separation | ~5 new | ~15 | 0 | ~10 updated |
| Phase 5: Folder Restructure | 0 new | ~60 (imports) | 0 | ~35 updated |
| Phase 6: Provider Rewiring + DI | ~5 new | ~10 | ~1 | ~10 updated |
| **Total** | ~34 new | ~121 modified | ~1 | ~88 test updates |

**Note:** These are rough estimates. The actual count depends on how aggressively we decompose services and whether we do the folder restructure.

---

## Conclusion

RIVR is well-positioned for this migration. The hardest architectural work (use cases, repository interfaces, DI container) is already done. The remaining work is primarily:

1. **ServiceResult pattern** — make error handling consistent
2. **Service decomposition** — split monolithic services into datasources and coordinators
3. **Entity/DTO separation** — untangle `ReachData` and other models from serialization
4. **Folder reorganization** — move into the `models/` + `services/` + `ui/` structure

The app is small enough (5 features, ~60 lib files, 35+ tests) that a phased migration over several sessions is realistic. Each phase produces a working app. No big-bang rewrite required.
