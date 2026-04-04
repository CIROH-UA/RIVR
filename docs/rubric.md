# Flutter App Architecture Rubric
### API-Driven Mobile Apps — Android & iOS

**Total: 1000 points**

Use this rubric to grade the software architecture of any Flutter app that relies heavily on REST APIs and Firebase services. Score each item from 0 to its maximum. A score of 0 means the item is absent or broken. A partial score means partial implementation. Full score means the item is fully implemented and consistent across the codebase.

---

## Scoring Scale

| Score | Grade | Meaning |
|-------|-------|---------|
| 920 – 1000 | A+ | Production-ready. Scalable, maintainable, and resilient. |
| 830 – 919 | A | Strong architecture. A few gaps worth closing. |
| 700 – 829 | B | Solid foundation with notable missing pieces. |
| 550 – 699 | C | Works but fragile. Significant refactoring needed. |
| 400 – 549 | D | Major structural problems. High technical debt. |
| 0 – 399 | F | Not production-ready. Foundational work required. |

---

## Category 1 — API & Networking Layer `/160`

The most critical category for apps that live and die by external data. Every point lost here compounds into UX failures, data loss, and fragile code.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 1.1 | **Abstracted HTTP client** — All HTTP calls go through a dedicated data source or repository layer. Zero raw `http`/`Dio` calls in widgets, providers, or use cases. The HTTP client (whether `http`, `Dio`, or `Chopper`) is wrapped behind an interface so it can be swapped or mocked without touching callers. | 25 | 0 if raw calls exist in UI; 10–20 if partially abstracted; 25 if fully abstracted behind interface |
| 1.2 | **Timeout configuration** — Connect, send, and receive timeouts are explicitly configured per request priority. Not relying on OS defaults. | 10 | 0 if no timeouts; 5 if one type configured; 10 if all three configured, ideally per-priority |
| 1.3 | **Retry with exponential backoff + jitter** — Transient failures (5xx, network drops, timeouts) are automatically retried with increasing delays and randomized jitter to avoid thundering-herd problems. Max retry count is capped. | 25 | 0 if no retry; 10 if basic retry; 20 if backoff present; 25 if jitter + cap included |
| 1.4 | **Request cancellation** — In-flight requests are cancelled when the calling widget or provider is disposed. No dangling requests updating dead state or charging quota unnecessarily. | 15 | 0 if no cancellation; 10 if partially done; 15 if consistent across all calls |
| 1.5 | **Centralized error mapping** — HTTP status codes and transport errors map to typed domain errors before leaving the data layer. No raw exceptions (e.g., `SocketException`, `TimeoutException`, `HttpException`) reaching the domain or presentation layers. | 20 | 0 if no mapping; 10 if partial; 20 if consistent typed error hierarchy |
| 1.6 | **Auth injection via interceptor** — API keys or bearer tokens are injected at a single point (interceptor or base client wrapper), not repeated manually in every call. | 10 | 0 if manual per call; 10 if interceptor or wrapper handles it |
| 1.7 | **Request/response logging (debug only)** — Requests, responses, and errors are logged in debug builds. Logging is stripped or disabled in release builds via build flavor or assert blocks. | 10 | 0 if none; 5 if logging also runs in release; 10 if debug-only |
| 1.8 | **Environment-based configuration** — Base URLs and API endpoints are configurable per environment (dev / staging / prod) without modifying source code. Switching environments is a config change, not a code change. | 15 | 0 if hardcoded; 5 if partially externalized; 15 if full environment config |
| 1.9 | **Connection-aware behavior** — The app detects when it is offline and responds gracefully: shows cached data, queues mutations, or displays an offline state. It never silently fails or shows a blank screen. | 20 | 0 if no awareness; 10 if detects offline but only shows error; 20 if falls back to cache or queues |
| 1.10 | **Request deduplication** — Identical concurrent requests (same endpoint + params) share a single in-flight `Future`. Common on screens with multiple widgets triggering the same fetch simultaneously. | 5 | 0 if no dedup; 5 if implemented consistently |
| 1.11 | **Response validation** — API responses are validated against the expected shape before parsing. Unexpected nulls or type mismatches produce a typed `ParseError`, not an unhandled exception. | 5 | 0 if no validation; 3 if partial; 5 if consistent |

**Category 1 Total: /160**

---

## Category 2 — Caching & Data Persistence `/130`

For API-heavy apps, caching is not optional. It determines perceived speed, offline capability, and API cost. This is the second most impactful category.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 2.1 | **In-memory cache with TTL** — Recently fetched data is held in memory with a time-to-live. Repeated calls within the TTL window return cached data without hitting the network. The cache is bounded in entry count. | 20 | 0 if none; 10 if present but no TTL or no bound; 20 if TTL-based and bounded |
| 2.2 | **Persistent disk cache** — Structured data that should survive app restarts is written to a proper local database (Hive, Isar, SQLite/drift, or similar). `SharedPreferences` is acceptable only for primitive scalars and flags, not for complex nested data. | 25 | 0 if none; 5 if SharedPreferences for everything; 15 if structured DB for complex data; 25 if proper schema with typed queries |
| 2.3 | **Cache invalidation strategy** — Cached data has an explicit invalidation rule: TTL expiry, event-driven invalidation, or user-initiated refresh. No data that is cached indefinitely with no update path. | 20 | 0 if no strategy; 10 if ad-hoc or implicit; 20 if defined and consistent |
| 2.4 | **Stale-while-revalidate** — Cached data is shown immediately on screen load while a background refresh runs. The UI updates when fresh data arrives. Users never stare at a spinner for data they already have cached. | 25 | 0 if always waits for network; 15 if shows cache then refreshes but with visual jank; 25 if smooth background refresh |
| 2.5 | **Deterministic cache keys** — Cache keys are collision-free and constructed systematically from endpoint path + sorted query parameters. No ad-hoc or hand-typed key strings. | 5 | 0 if ad-hoc strings; 3 if mostly consistent; 5 if systematic |
| 2.6 | **Cache size limits & eviction** — Disk and memory caches have size caps. Old or least-recently-used entries are evicted automatically. The app cannot grow its local storage indefinitely. | 10 | 0 if unbounded; 5 if partially limited; 10 if LRU or TTL-based eviction enforced |
| 2.7 | **Offline-first data access** — The app loads cached data when offline and clearly communicates to the user that they are viewing offline content. Core features remain functional without a connection. | 25 | 0 if broken offline; 10 if partially works; 25 if graceful offline experience with clear indicator |

**Category 2 Total: /130**

---

## Category 3 — State Management `/100`

Inconsistent or poorly scoped state leads to stale data, unnecessary re-renders, and subtle bugs that are hard to reproduce.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 3.1 | **Single consistent pattern** — One state management approach (Provider, Riverpod, Bloc, etc.) is used throughout the app. No mixing of raw `setState` with a provider library in the same feature. | 15 | 0 if mixed; 8 if mostly consistent with exceptions; 15 if fully consistent |
| 3.2 | **Explicit loading / error / data states** — Every async operation has three modeled states. The UI never assumes data is ready. `isLoading`, `error`, and `data` are first-class and always handled. | 25 | 0 if no modeling; 10 if partial; 20 if most flows; 25 if all async flows covered |
| 3.3 | **No business logic in widgets** — Widgets only read state and dispatch events. Data transformation, filtering, and decisions live in use cases or providers/blocs, never in `build()` or widget callbacks. | 20 | 0 if logic in widgets; 10 if partially separated; 20 if fully separated |
| 3.4 | **Granular state and selective rebuilds** — Widgets rebuild only when the slice of state they consume changes. `select`, `Consumer` scoping, or equivalent used to avoid unnecessary renders. | 15 | 0 if coarse global state; 8 if some scoping; 15 if fine-grained throughout |
| 3.5 | **Immutable state objects** — State is treated as immutable. Updates produce new objects via `copyWith` or equivalent. No mutating state in-place and calling notify. | 5 | 0 if mutable; 5 if consistent |
| 3.6 | **Proper resource disposal** — Controllers, streams, animation controllers, and subscriptions are disposed in `dispose()`. No memory leaks from undisposed listeners. | 20 | 0 if not disposed; 10 if partial; 20 if consistent across all stateful widgets and providers |

**Category 3 Total: /100**

---

## Category 4 — Error Handling & Resilience `/80`

Apps that depend on external APIs will encounter failures. The question is whether those failures are managed gracefully or exposed as crashes and blank screens.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 4.1 | **Typed error hierarchy** — A domain-specific error type system exists: `NetworkError`, `ParseError`, `AuthError`, `NotFoundError`, `ServerError`, etc. Errors carry enough context for the UI to show the right message and the right action. Defined in the domain layer, independent of infrastructure types. | 20 | 0 if untyped exceptions; 10 if partial typing; 20 if consistent hierarchy in domain layer |
| 4.2 | **User-facing error messages** — Every error state the user can encounter shows a clear, human-readable message with an actionable hint. No raw exception messages, stack traces, or empty screens. | 20 | 0 if raw errors or blank screen; 10 if partial; 20 if all error states covered |
| 4.3 | **Graceful degradation** — When one API endpoint or feature fails, the rest of the app continues working. Failures are isolated and do not cascade to unrelated features. | 20 | 0 if one failure breaks the app; 10 if partial isolation; 20 if well-isolated per feature |
| 4.4 | **Global exception boundary** — Unhandled exceptions are caught at the app level via `FlutterError.onError` and `PlatformDispatcher.instance.onError`, logged to a crash reporter, and surfaced as a friendly error screen — not a white crash screen. | 10 | 0 if none; 5 if partially configured; 10 if fully configured and routed to crash reporter |
| 4.5 | **Retry affordance in UI** — Every error state in the UI offers the user a way to retry. There are no dead-end error screens. | 10 | 0 if no retry; 5 if some screens; 10 if all error states |

**Category 4 Total: /80**

---

## Category 5 — Performance & Optimization `/60`

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 5.1 | **Pagination / lazy loading** — Lists never load all records at once. Data is fetched in pages as the user scrolls. Neither Firestore nor REST list endpoints are called without a limit. | 20 | 0 if loads everything; 10 if some lists paginate; 20 if consistent |
| 5.2 | **Network image caching** — All network images are cached to disk via `cached_network_image` or equivalent. Images do not re-download on every render or screen revisit. | 10 | 0 if no caching; 10 if consistent |
| 5.3 | **Widget build optimization** — `const` constructors used wherever possible. `ListView.builder` / `SliverList` used for all long lists. No expensive computation or I/O inside `build()`. | 10 | 0 if unoptimized; 5 if partially; 10 if consistent |
| 5.4 | **Cold start performance** — Heavy initialization (DB setup, large config loads, Firebase init) is deferred to after the first frame. The app renders something quickly on mid-range devices. | 10 | 0 if blocking init on main thread; 5 if partially deferred; 10 if properly deferred |
| 5.5 | **Release build optimization** — Tree-shaking enabled, unused assets excluded, `--obfuscate` and `--split-debug-info` used for release APK/IPA. App size is minimized intentionally. | 10 | 0 if no configuration; 5 if partial; 10 if fully configured for release |

**Category 5 Total: /60**

---

## Category 6 — Security `/70`

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 6.1 | **No secrets in source code** — API keys, tokens, passwords, and connection strings are never hardcoded in Dart or TypeScript source. They live in gitignored config files, environment variables, or a secrets manager. The git history contains no credentials. | 25 | 0 if any secrets committed; 25 if fully clean including history |
| 6.2 | **Secure storage for sensitive data** — User tokens, credentials, and PII are stored in `flutter_secure_storage` (iOS Keychain / Android Keystore), not in `SharedPreferences` or plain files. Sensitive fields are never written to logs. | 20 | 0 if plain storage used for secrets; 10 if partially; 20 if consistent |
| 6.3 | **Certificate / SSL pinning** — Critical API endpoints (especially those sending user data or receiving sensitive forecasts) are protected against man-in-the-middle attacks via certificate or public key pinning. | 10 | 0 if no pinning; 10 if implemented |
| 6.4 | **Release obfuscation** — `--obfuscate` and `--split-debug-info` are configured for release builds. Debug symbols are stored separately and not shipped with the app binary. | 10 | 0 if not configured; 10 if fully configured |
| 6.5 | **Input validation at boundaries** — User input is validated before use in API calls or storage writes. API responses are validated before parsing into domain objects. | 5 | 0 if no validation; 3 if partial; 5 if consistent |

**Category 6 Total: /70**

---

## Category 7 — Testing `/60`

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 7.1 | **Unit tests for use cases, services, and models** — Core parsing logic, data models, business rules, and domain use cases are covered by unit tests. Regressions in API parsing or business decisions are caught automatically, not discovered in production. | 25 | 0 if none; 10 if minimal; 18 if moderate coverage of critical paths; 25 if high coverage |
| 7.2 | **Widget tests for critical user flows** — Key screens (auth, primary feature, error states, empty states) have widget tests that verify the UI renders correctly under different state conditions. | 15 | 0 if none; 8 if 1–2 screens; 12 if main flows; 15 if comprehensive |
| 7.3 | **Mock infrastructure** — All external dependencies (HTTP client, Firestore, Auth, FCM) have mock or fake implementations. Tests never make real network or Firebase calls. Repository interfaces from Clean Architecture make this straightforward. | 10 | 0 if tests hit real services; 5 if partial; 10 if all external deps mocked consistently |
| 7.4 | **Integration / end-to-end tests** — At least one critical end-to-end flow (e.g., login → load favorites → view forecast) is covered by an integration test running on a real device or emulator. | 10 | 0 if none; 10 if at least one flow covered |

**Category 7 Total: /60**

---

## Category 8 — Clean Architecture `/90`

> **This category is the structural backbone of the entire rubric.** All other categories depend on it: you cannot properly test, cache, swap data sources, or add features without clean separation of layers.

Clean Architecture enforces a single rule — **dependencies point inward only**. The Domain layer knows nothing about Flutter, Firebase, Dio, or any infrastructure. The Data and Presentation layers depend on the Domain, never on each other. Replacing a data source (e.g., switching from REST to GraphQL, or from Firestore to a different DB) should touch only the Data layer.

### Required folder structure per feature

```
features/
  <feature_name>/
    domain/
      entities/        -- pure Dart business objects; no framework imports
      repositories/    -- abstract contracts (interfaces) for data access
      usecases/        -- one class per operation; calls repository interfaces
    data/
      models/          -- DTOs: JSON/Firestore shapes with toDomain() / fromJson()
      datasources/     -- remote_data_source.dart, local_data_source.dart
      repositories/    -- concrete implementations of domain contracts
    presentation/
      pages/
      widgets/
      providers/       -- (or blocs/) call use cases; never data sources directly
```

Shared domain types and cross-feature entities live in `core/domain/`.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 8.1 | **Three-layer structure enforced** — Every feature contains Domain, Data, and Presentation layers organized as above. The folder structure is consistent and navigable. Adding a new feature or data source means adding a new module, not modifying existing ones. | 20 | 0 if no layering; 8 if partially structured; 15 if mostly consistent; 20 if fully consistent across all features |
| 8.2 | **Pure domain layer** — Domain entities and use cases import only `dart:core` and other domain classes. No Flutter, Firebase, Dio, `http`, or any infrastructure package appears in `domain/`. The domain layer is testable with plain `dart test` — no framework mocking required. | 20 | 0 if domain imports infrastructure; 10 if partially clean; 20 if fully framework-free |
| 8.3 | **Repository abstraction** — Abstract repository contracts are defined in `domain/repositories/`. The presentation and domain layers depend only on the abstract contract, never on a concrete implementation or a Firebase/HTTP client directly. Concrete implementations live in `data/repositories/` and are wired via DI. | 15 | 0 if no abstraction; 8 if abstract class exists but bypassed; 15 if consistently respected |
| 8.4 | **Use cases as the single entry point to business logic** — Each distinct operation (fetch forecast, add favorite, authenticate, send alert) is encapsulated in a use case class with a single `call()` method. Providers and blocs call use cases; use cases call repository interfaces. No provider reaches directly into a data source or Firebase SDK. | 20 | 0 if no use cases; 8 if some exist; 15 if most operations covered; 20 if consistent |
| 8.5 | **DTOs separated from domain entities** — API response shapes and Firestore document shapes (DTOs) live in `data/models/` and implement `toDomain()`. Domain entities are never directly deserialized from JSON or Firestore maps. Changing the API response format or Firestore schema requires touching only the DTO — not the domain layer or UI. | 15 | 0 if entities are DTOs; 8 if partially separated; 15 if fully and consistently separated |

**Category 8 Total: /90**

---

## Category 9 — User Experience & Accessibility `/80`

Good UX in an API-heavy app is mostly about managing the wait and the failure gracefully. Accessibility ensures the app works for all users, including those who rely on larger text, screen readers, or other assistive technologies.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 9.1 | **Skeleton / shimmer loading screens** — Data screens show a skeleton placeholder while loading, not a bare spinner or a blank screen. The layout is recognizable before data arrives. The skeleton matches the shape of the real content. | 15 | 0 if spinner or blank only; 8 if some screens have skeletons; 15 if consistent across all data screens |
| 9.2 | **Optimistic updates** — Mutations (favorites, settings, user actions) are reflected in the UI immediately and rolled back on failure. Users do not wait for a server round-trip to see their own actions. | 10 | 0 if all updates wait for server; 5 if some; 10 if consistent |
| 9.3 | **Pull-to-refresh** — All data screens support manual refresh via a pull gesture. Users have agency over when to re-fetch. | 10 | 0 if none; 5 if some screens; 10 if all data screens |
| 9.4 | **Empty state screens** — When a list or data view has no content, a clear, contextual empty state is shown — not a blank screen or a hidden error. The empty state tells the user why it is empty and what to do next. | 10 | 0 if blank; 5 if partial; 10 if all data views have meaningful empty states |
| 9.5 | **Offline / connectivity banner** — A persistent, clearly visible indicator appears when the app is offline. It disappears automatically when connectivity is restored. Cached content is still accessible and labeled as such. | 15 | 0 if none; 8 if shown briefly or only on error; 15 if persistent, auto-dismissing, and content remains accessible |
| 9.6 | **Text scale factor support** — The UI adapts correctly when users increase their system font size (via iOS Display & Text Size or Android Font Size settings). No text clips, overflows, or becomes unreadable at `textScaleFactor` values of 1.3, 1.5, and 2.0. Layout uses flexible sizing (`Flexible`, `Expanded`, `FittedBox`) rather than fixed-pixel containers for text. Older users or visually impaired users who rely on large system fonts must have a fully functional app. | 15 | 0 if text overflows or clips at large sizes; 5 if partially handled; 10 if mostly works; 15 if fully tested at 1.3×, 1.5×, and 2.0× |
| 9.7 | **Accessibility semantics** — Interactive elements have semantic labels. Images have `semanticLabel`. Icon-only buttons have `Semantics(label: ...)`. Screen reader users can navigate the primary flows (view data, perform key actions, read status). Cupertino widgets provide reasonable defaults — score higher if custom widgets add explicit semantics. | 5 | 0 if no semantics consideration; 3 if partial; 5 if primary flows are screen-reader navigable |

**Category 9 Total: /80**

---

## Category 10 — Observability & Monitoring `/40`

You cannot improve what you cannot measure. In production, observability is what separates reactive firefighting from proactive reliability.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 10.1 | **Crash reporting (Crashlytics or equivalent)** — Unhandled exceptions and fatal errors are automatically reported to a crash reporter in production. Non-fatal errors are also logged. Developers are alerted to new crash types. User identifiers are attached to crash reports without PII (use hashed IDs). | 15 | 0 if not installed; 5 if installed but only fatal crashes; 10 if fatal + non-fatal; 15 if fully configured with non-PII user context |
| 10.2 | **Analytics instrumentation** — Key user flows and feature interactions are tracked with named events (screen views, feature use, alert received, data loaded, error encountered). Not just installed — actively sending events that inform product decisions. | 15 | 0 if not installed or installed but unused; 5 if installed with minimal events; 10 if key flows covered; 15 if comprehensive and consistent |
| 10.3 | **API latency and error rate awareness** — Slow or failing API calls are surfaced via crash reporting custom keys, analytics events, or a monitoring tool. The developer can identify degraded endpoints without waiting for user reports. | 10 | 0 if none; 5 if logged locally only; 10 if reported to remote monitoring |

**Category 10 Total: /40**

---

## Category 11 — Routing & Navigation `/20`

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 11.1 | **Declarative routing** — Routes are declared in a single location using a router package (`go_router`, `auto_route`, etc.). Navigation is not driven by `Navigator.push` scattered across the codebase. Route definitions are type-safe and navigable. | 10 | 0 if imperative push everywhere; 5 if partially declarative; 10 if fully declarative |
| 11.2 | **Deep link support** — The app handles incoming deep links and universal links. Users arriving from a push notification or an external URL land on the correct screen with the correct state loaded. | 5 | 0 if no deep links; 5 if implemented |
| 11.3 | **Centralized route guards** — Auth-protected routes automatically redirect unauthenticated users. Guard logic lives in the router, not duplicated in each page's `initState` or `didChangeDependencies`. | 5 | 0 if no guards or guards are per-page; 5 if centralized in router |

**Category 11 Total: /20**

---

## Category 12 — CI/CD & Developer Experience `/10`

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 12.1 | **Automated tests and analysis on push** — `flutter test` and `flutter analyze` run automatically on every push or PR. Failures are visible immediately and block merging. No manual "did you run tests?" step. | 5 | 0 if manual only; 3 if runs but doesn't block; 5 if enforced via CI |
| 12.2 | **Automated build artifacts** — Release APK/IPA are built by CI, not by hand on a developer machine. Builds are reproducible and versioned automatically. | 5 | 0 if manual builds; 5 if CI builds |

**Category 12 Total: /10**

---

## Category 13 — Code Style & Organization `/20`

These rules enforce consistency and readability. Lower stakes than architecture but compound in impact as the codebase grows and new contributors join.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 13.1 | **One public concept per file** — Each file exposes one primary public class, widget, use case, or function. Private state classes (`_*State` in StatefulWidgets) and sealed subtype variants are the only accepted exceptions. Having a `ForecastPage` and an unrelated `ForecastCard` in the same file is a violation. | 7 | 0 if files regularly contain multiple unrelated public types; 4 if mostly followed; 7 if consistent |
| 13.2 | **Consistent file naming by role** — All Dart files use `snake_case`. Files are suffixed by their role: `*_page.dart`, `*_widget.dart`, `*_provider.dart`, `*_bloc.dart`, `*_usecase.dart`, `*_repository.dart`, `*_model.dart`, `*_entity.dart`. The suffix alone tells you what a file contains. | 6 | 0 if ad-hoc naming; 3 if partially consistent; 6 if fully consistent |
| 13.3 | **No magic numbers or inline strings** — Numeric constants and string literals used in logic are defined as named constants. No unexplained `86400`, `"status_active"`, or `0xFF00AAFF` inline. | 5 | 0 if magic values throughout; 3 if partially extracted; 5 if consistent |
| 13.4 | **No deep callback nesting** — Anonymous functions are not nested more than two levels deep inside `build()` or async methods. Nested logic is extracted into named methods, use cases, or helper widgets. | 2 | 0 if deeply nested callbacks are common; 2 if consistently flat |

**Category 13 Total: /20**

---

## Category 14 — Firebase Services `/80`

Firebase is not just a backend — it is an active part of the app's architecture. Each service has its own set of best practices that, when ignored, produce billing surprises, stale data, security gaps, and silent failures.

| # | Item | Max | How to score |
|---|------|-----|--------------|
| 14.1 | **Firestore type-safe access with `.withConverter()`** — All Firestore collection reads and writes use `.withConverter<T>()` with a typed `fromFirestore` / `toFirestore` pair. No raw `Map<String, dynamic>` casting in app code. DTO models in the data layer handle serialization. Changing a Firestore document schema only requires updating the DTO, not hunting through the codebase. | 15 | 0 if raw maps everywhere; 8 if partially converted; 15 if consistent |
| 14.2 | **Firestore security rules version-controlled and tested** — Security rules are stored in `firestore.rules` and deployed alongside code. Rules enforce that users can only read and write their own documents (`request.auth.uid == userId`). Rules are not just "authenticated users can do everything." | 10 | 0 if rules not in repo or overly permissive; 5 if basic auth check; 10 if fine-grained, version-controlled, and deployed via CLI |
| 14.3 | **Firestore listener lifecycle management** — Real-time `snapshots()` listeners are cancelled (via the returned `StreamSubscription`) when the subscribing provider or widget is disposed. Lingering listeners cause memory leaks, stale data, and unnecessary Firestore read billing. | 10 | 0 if listeners are not cancelled; 5 if partially managed; 10 if consistently cancelled in `dispose()` |
| 14.4 | **Auth state stream as source of truth** — The app's authentication state is driven by `FirebaseAuth.instance.authStateChanges()` (a stream), not by manually toggled boolean flags. Sign-in and sign-out transitions happen automatically as the stream emits. Token expiry and session restoration are handled by the SDK, not manually. | 10 | 0 if manual flags; 5 if mixed; 10 if fully stream-driven |
| 14.5 | **Auth error codes mapped to user messages** — All relevant `FirebaseAuthException.code` values are caught and mapped to actionable user-facing messages: `wrong-password`, `user-not-found`, `too-many-requests`, `email-already-in-use`, `weak-password`, `network-request-failed`, etc. No raw Firebase error messages shown to users. | 8 | 0 if unmapped; 4 if common cases mapped; 8 if comprehensive |
| 14.6 | **FCM token refresh handled** — FCM token rotation is listened to via `FirebaseMessaging.instance.onTokenRefresh`. When a new token is issued, it is written back to Firestore immediately. Stale FCM tokens cause silent notification failures with no error surfaced to the user. | 8 | 0 if no refresh handling; 5 if partially handled; 8 if fully implemented |
| 14.7 | **Notification permission requested contextually** — Push notification permission is requested at a moment where the user understands why (e.g., after enabling alerts, not on cold app launch). On iOS, provisional permission (`UNAuthorizationOptionProvisional`) is used where appropriate to deliver quiet notifications before the user grants full permission. | 5 | 0 if requested on launch; 3 if contextual but no provisional; 5 if contextual with provisional iOS flow |
| 14.8 | **Firebase Crashlytics integrated and active** — The `firebase_crashlytics` package is installed and initialized. Both fatal crashes (`FlutterError.onError`, `PlatformDispatcher.onError`) and non-fatal errors are reported via `FirebaseCrashlytics.instance.recordError()`. A non-PII user identifier is set on login. `developer.log()` alone is not sufficient — local logs vanish when the device is not connected to a computer. | 8 | 0 if not installed; 4 if installed but only fatal crashes; 6 if fatal + non-fatal; 8 if fully configured with user context |
| 14.9 | **Firebase Analytics actively instrumented** — The `firebase_analytics` package is installed and sends meaningful named events: screen views, feature interactions (forecast viewed, alert toggled, favorite added/removed), and key error events. "Installed but unused" scores 0 — it provides no value and adds dead weight. Events are named consistently (`snake_case`, verb-noun format). | 6 | 0 if not installed or installed but unused; 3 if minimal events; 6 if key flows instrumented consistently |

**Category 14 Total: /80**

---

## Score Summary

| Category | Max | Score |
|----------|-----|-------|
| 1. API & Networking Layer | 160 | |
| 2. Caching & Data Persistence | 130 | |
| 3. State Management | 100 | |
| 4. Error Handling & Resilience | 80 | |
| 5. Performance & Optimization | 60 | |
| 6. Security | 70 | |
| 7. Testing | 60 | |
| 8. Clean Architecture | 90 | |
| 9. User Experience & Accessibility | 80 | |
| 10. Observability & Monitoring | 40 | |
| 11. Routing & Navigation | 20 | |
| 12. CI/CD & Developer Experience | 10 | |
| 13. Code Style & Organization | 20 | |
| 14. Firebase Services | 80 | |
| **Total** | **1000** | |

---

## Priority Order for Remediation

When improving a codebase, address gaps in this order:

1. **Security** — Exposed secrets or insecure storage can cause irreversible damage. Fix before anything else.
2. **Clean Architecture** — Without proper layering, every other improvement is harder. Fix the structure before optimizing what sits on top of it.
3. **Firebase Services** — Incorrect Firebase usage (missing Crashlytics, dangling listeners, no `.withConverter()`, permissive security rules) silently corrupts data, drains billing, and hides production crashes.
4. **Observability** — Install Crashlytics and activate Analytics before shipping to real users. You cannot fix what you cannot see.
5. **Error handling** — Crashes and blank screens drive users away faster than slow loads.
6. **API layer** — Fragile networking poisons everything above it.
7. **Caching** — Perceived speed is the single biggest UX lever for API-heavy apps.
8. **State management** — Stale state and unnecessary rebuilds compound as the app grows.
9. **Testing** — Without tests, every refactor is a gamble. Clean Architecture makes this easier.
10. **UX & Accessibility** — Skeletons, offline banners, text scaling, and empty states once the core is solid.
11. **Performance** — Optimize after you can measure.
12. **Code style** — Enforce via `analysis_options.yaml` with stricter linting rules.
13. **Routing** — Migrate to declarative routing when adding deep links or new navigation flows.
14. **CI/CD** — Automate once the workflow is repeatable and tests are reliable.
