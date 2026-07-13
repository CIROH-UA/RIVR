# ADR 0002 — Canonical derived‑value layer: classify and format once, render everywhere

- **Status:** Accepted — Stage 1 (flood‑category classifier) delivered 2026-07-12; Stage 2 (source‑agnostic forecast model) parked, gated on the next source carrying detail
- **Date:** 2026-07-12
- **Deciders:** Jerson Garcia (lead)
- **Relates to:** ADR 0001 (`0001-river-data-layer-ssot-and-freshness.md`), `docs/internal/forecast-data-consistency-audit.md`
- **Context source:** a 5‑agent consistency audit of how forecast values reach the widgets (2026-07-12), which found the same displayed value computed differently in four+ places.

## Context and problem

ADR 0001 made the **data** a single source of truth: one network response is cached once (keyed `(source, reachId, product)`, native units) and fanned out to every widget through `RiverDataRepository`. That fixed *where values come from*.

It did **not** unify *how a raw value becomes what the user sees*. Each widget re‑derived the presentation itself — most damagingly the **flood category** (Normal/Action/Moderate/Major/Extreme), which is a function of `(flow, returnPeriods)`. The audit found four divergent implementations of that one function:

1. **Favorites card** classified a raw **CMS** flow against thresholds it had labeled **CFS** — wrong zone whenever the user was in CFS.
2. **Hourly timeline** used a **4‑bucket** ladder (Normal/Elevated/High/Flood) that disagreed with the gauge's **5‑zone** ladder for the same reach and flow.
3. **GEOGLOWS bottom sheet** hardcoded `'Normal'` regardless of the actual flow.
4. **Gauge / forecast page / `ReachData.getFlowCategory`** each carried their own inline copy of the 5‑zone ladder — correct, but three separate copies that could drift.

The root cause is structural, not a set of isolated bugs: **the mapping from data → displayed value lived in the widgets.** Every widget that shows a value owns a private copy of the derivation, so:

- the same reach can show two categories on two screens simultaneously;
- a threshold or unit rule fixed in one widget stays wrong in the others;
- adding a source means re‑deciding the derivation in every widget it touches (GEOGLOWS's hardcoded `'Normal'` is exactly this — a new source that never got wired into the ladder).

As we add sources, this multiplies. ADR 0001 removed the *fetch/cache* fork; this ADR removes the *derivation* fork.

## Decision drivers

- A value that means one thing (a category, a current flow, a formatted number) must be computed **once** and read everywhere — no widget re‑implements it.
- Classification must be **unit‑correct by construction**: it is impossible to compare a flow to a threshold in a different unit.
- Adding a new data source must not require touching any widget's derivation logic — the source provides `(flow, thresholds)` in a known unit and the canonical layer does the rest.
- Stay within the existing stack and layering (pure domain functions in `models/1_domain/`, no new dependency).
- Cheap, incremental, independently shippable — no big‑bang.

## Decisions

**D1 — One canonical classifier owns the flood‑category ladder.** `FlowClassification` (in `models/1_domain/shared/flow_classification.dart`) is the single definition of the 5‑zone ladder — Normal/Action/Moderate/Major/Extreme at the 2/5/10/25‑yr return periods. `kFloodCategories` is the ordered name list. `indexFor(flow, thresholds)` and `category(flow, thresholds)` are the only sanctioned way to compute a category anywhere in the app. No widget, service, or model may inline a threshold ladder.

**D2 — The classifier is unit‑agnostic; callers convert first.** `FlowClassification` compares numbers and assumes the caller passed `flow` and `thresholds` in the **same** unit. The contract is: **convert return periods into the flow's display unit, then classify.** Return periods are stored natively in CMS (`ReachData.returnPeriodUnit = 'cms'`); callers use `flowUnitService.convertFlow(rp, 'CMS', displayUnit)` (or `ReachData.getReturnPeriodsInUnit`) before calling in. This is what fixed the favorites CMS‑vs‑CFS bug — the conversion is now a visible, required step, not an accident.

**D3 — Category color is also canonical.** The category → color mapping lives once in `AppConstants.getFlowCategoryColor(category)` (systemBlue/Yellow/Orange/Red/Purple). Widgets map `category → color` through it rather than re‑deciding colors per zone.

**D4 — The pattern generalizes: derive‑once for every displayed value.** The flood category is the first and canonical instance of a broader rule — *any value the user sees that is derived from raw data should be derived in one place and read by widgets.* The next candidates (Stage 2 / audit medium‑likelihood items) are: **one canonical "current flow"** (today several caches and surfaces each pick a "now" value slightly differently) and **one flow‑formatting** path (number + unit label). The target is that a widget receives a display‑ready value (or calls one canonical pure function to get it), never re‑implements the rule.

**D5 — Derived values are pure functions over ADR‑0001 data, not a new cache.** This layer holds **no state** and does **no I/O**. It is pure `(data) → displayValue` functions sitting between `RiverDataRepository` (the data SSOT, ADR 0001) and the widgets. It composes with ADR 0001; it does not replace or duplicate it. Where a value must stay live, the widget still observes the repository (ADR 0001 D5) and passes the fresh data through the canonical function.

**D6 — Reach the source‑agnostic forecast model incrementally (inherits ADR 0001 D7/Step 7).** The largest remaining derivation fork is that NWM forecast **detail** (hourly/daily/calendar/peaks/chart) still renders from the NWM‑shaped `ForecastResponse` via `ForecastService`/`ReachDataProvider`, while GEOGLOWS renders from `GeoglowsForecast`. Unifying category/color/current‑flow derivation (D1–D4) is the cheap, high‑value slice and lands first. Retiring the `ForecastResponse`/`GeoglowsForecast` fork behind a capability‑based `RiverForecast` is the large, risky slice and lands last — gated on when a new source actually carries detail (so the generalization is designed against a real second detail shape, not a hypothetical one).

## Alternatives considered

- **Fix the four category bugs in place, leave derivation in the widgets.** Rejected — treats symptoms; the fifth widget (or the next source) re‑introduces the divergence. The audit explicitly asked for the structural fix.
- **Put derivation in the repository (ADR 0001 layer).** Rejected — the repository's job is data identity/freshness in native units; display derivation is unit‑ and presentation‑specific and belongs in a pure domain layer above it. Keeping them separate keeps the cache unit‑neutral (ADR 0001 D2).
- **A single 4‑bucket ladder** (adopt the timeline's scheme). Rejected — the 5‑zone ladder maps directly to the return‑period thresholds the app already computes and the notification pipeline already uses; the 4‑bucket scheme was the outlier.
- **Make the classifier unit‑aware (take a unit argument and convert internally).** Rejected — it would need a `FlowUnitPreferenceService` dependency inside a pure domain function, and callers already hold the converted return periods. Keeping it unit‑agnostic makes it trivially testable and dependency‑free (D2, D5).

## Consequences

**Positive**
- One reach shows one category on every screen — the class of "gauge says Action, timeline says High" bugs is gone structurally.
- Unit correctness is enforced by the call shape (convert‑then‑classify), not by each widget remembering to.
- A new source wires its category once (provide `flow` + `thresholds` in a known unit); it can never repeat GEOGLOWS's hardcoded‑`'Normal'` mistake.
- A threshold/ladder/color change is a one‑file edit with one test file guarding it.
- Pure, dependency‑free functions — exhaustively unit‑testable at the boundaries.

**Negative / risks**
- Every classifying call site must convert return periods to the flow's unit first; a caller that forgets re‑introduces a unit bug. Mitigate by making `getReturnPeriodsInUnit`/`convertFlow` the obvious path and keeping the classifier's unit contract documented at its definition.
- The current‑flow and formatting unifications (D4) are not yet done — those inconsistencies remain until Stage 2.
- The `ForecastResponse` fork (D6) still means NWM detail and GEOGLOWS detail render from different models; full uniformity waits on Step 7.

## Target architecture (sketch)

```
RiverDataRepository (ADR 0001)  ── native‑unit data SSOT ─────────────┐
        │  observe: (source, reachId, product) → { nativeValue, ... } │
        ▼                                                             │
Canonical derived‑value layer (this ADR — pure, stateless)           │
        ├─ FlowClassification.category(flow, thresholds)   ← the ladder, once
        ├─ AppConstants.getFlowCategoryColor(category)      ← category→color, once
        ├─ (Stage 2) canonicalCurrentFlow(data)             ← "now" value, once
        └─ (Stage 2) formatFlow(value, unit)                ← number+label, once
        ▼
Widgets  ── convert RP→flow unit, call the canonical fn, render ──────┘
  gauge · forecast page · favorites card · hourly timeline · bottom sheet
```

## Outcome (2026-07-12)

**Stage 1 delivered.** `FlowClassification` is the single flood‑category classifier; `ReachData.getFlowCategory`, `flow_gauge`, `reach_forecast_page`, `favorite_river_card`, `horizontal_flow_timeline`, and the GEOGLOWS `reach_details_bottom_sheet` all route through it. The three deterministic audit bugs (favorites CMS category, hourly 4‑bucket mismatch, GEOGLOWS hardcoded `'Normal'`) are fixed; the three redundant inline 5‑zone ladders are collapsed to one. Analyze‑clean; 662 unit/widget tests green (8 new for the classifier). Shipped on `chore/forecast-consistency-fixes`.

**Stage 2a delivered.** `FlowFormat` is the single flow formatter — `grouped` (`30,508`) for the prominent current‑flow readouts, `compact` (`30.5K`/`1.2M`) for dense spots — replacing seven near‑identical private `_formatFlow`/`_formatFlowValue` copies across the gauge, forecast page, chart, calendar cell/detail, timeline, and thresholds sheet. Analyze‑clean; 668 unit/widget tests green (6 new for the formatter). Shipped on `chore/canonical-current-flow`. Investigation also confirmed the current‑flow picker is *already* one‑per‑source (see plan step 3), so no standalone current‑flow refactor is warranted before 2b.

**Stage 2b parked, gated on the next source.** The source‑agnostic `RiverForecast` model that retires the `ForecastResponse`/`GeoglowsForecast` fork (ADR 0001 Step 7) — which also subsumes the *cross‑source* current‑flow and return‑period unification (audit #4–#7) — is the remaining work. It is sequenced when a new data source actually carries forecast *detail* — the forcing function that makes the generalization concrete rather than speculative, and the point at which not having it would force a fork.

## Development plan

1. **Canonical flood‑category classifier** — `FlowClassification` + route all category call sites through it; fix the three category bugs. *(done 2026-07-12)*
2. **Canonical flow formatting** — one `FlowFormat` (`grouped` for prominent readouts, `compact` for dense spots); remove the seven ad‑hoc `_formatFlow`/`_formatFlowValue` copies. *(done 2026-07-12)*
3. **Canonical current‑flow** — *investigated 2026-07-12: already one picker per source* (`ForecastService.getCurrentFlow` for NWM, `GeoglowsForecast.currentMedian` for GEOGLOWS); the `_currentFlowCache` mixin only memoizes the NWM picker. There is no same‑value‑computed‑differently bug within a source. The only remaining unification is *cross‑source*, which is Step 4 — so this folds into 2b rather than being a standalone step.
4. **Source‑agnostic `RiverForecast`** — retire the `ForecastResponse`/`GeoglowsForecast` fork so detail pages derive from a uniform, capability‑based model (= ADR 0001 Step 7). Subsumes the cross‑source current‑flow unification (step 3). Largest/riskiest; last; gated on the next detail‑carrying source.

## Open questions

- Where should the "convert RP → flow unit" step live so it's impossible to skip — a thin `classifyForDisplay(flow, rpNative, unit, service)` helper on the domain side, or leave it explicit at each call site?
- Does the canonical current‑flow value belong as a derived getter on the repository's forecast product, or as a pure function beside `FlowClassification`?
- When Stage 4 lands, does `RiverForecast` subsume `FlowClassification`'s inputs (carry thresholds + current flow directly), collapsing the convert‑then‑classify step into the model?
