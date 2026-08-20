# 0007 — One source of truth for flood category colours

**Status:** Proposed — spec only, nothing built
**Raised by:** Jerson, 2026-08-20, from the NWM medium-range expandable rows
**Related:** ADR 0002 (canonical derived values), ADR 0005 (map flood colours)

## The reported symptom

Expanding a row in the NWM medium-range widget shows a timeline whose bars
"only accept the blue of normal flow but not the rest of the colours".

## Root cause: a dead vocabulary

`ReachData.getFlowCategory()` → `FlowClassification.category()` returns the
canonical ladder:

```
Normal · Action · Moderate · Major · Extreme        (+ 'Unknown')
```

The widgets under `daily_expandable_widget/` switch on a **different, retired
ladder**:

```dart
// micro_bar_chart.dart:151
switch (category.toLowerCase()) {
  case 'normal':     return CupertinoColors.systemBlue;
  case 'elevated':   return CupertinoColors.systemGreen;
  case 'high':       return CupertinoColors.systemOrange;
  case 'flood risk': return CupertinoColors.systemRed;
  default:           return CupertinoColors.systemGrey;   // ← everything real
}
```

`Action`, `Moderate`, `Major` and `Extreme` match no case, so they fall to
`default` and paint **grey**. Only `Normal` resolves. The ladder produced and
the ladder consumed have not shared a vocabulary since the ADR 0002 migration.

Note the second path: `_getColorForFlow` only classifies when
`reach.hasReturnPeriods`; otherwise it calls `_getGradientColor`, which colours
by *relative position within the visible range*. That produces blue for
low-in-range values regardless of flood state — plausible-looking colour with no
relationship to the ladder, and a second reason bars can read "all blue".

### Every surviving copy

`horizontal_flow_timeline.dart` was migrated during ADR 0002 and carries a
comment saying so. The `daily_expandable_widget/` folder was missed entirely —
**five** private implementations, all on the dead vocabulary:

| File | Line | Also wrong |
|---|---|---|
| `hourly_display/micro_bar_chart.dart` | 151 | the reported bars |
| `hourly_display/micro_bar_chart.dart` | 305 | second class, same file |
| `hourly_display/flow_value_indicator.dart` | 199 | |
| `flow_range_bar.dart` | 148 | |
| `flow_condition_icon.dart` | 76 | **and its icon switch at 63** |

So the whole expanded row is affected — bars, range bar, value indicator and
condition icon — not just the bars.

## The larger problem: three palettes, no owner

Even once the vocabulary is fixed, "the colour of Moderate" has three different
answers in this repo:

| Source | Normal | Action | Moderate | Major | Extreme |
|---|---|---|---|---|---|
| `AppConstants.getFlowCategoryColor` | `systemBlue` | `systemYellow` | `systemOrange` | `systemRed` | `systemPurple` |
| `map_vector_tiles_service` (tileset) | `#191970` | `#FFC400` | `#FF8C00` | `#E53935` | `#8E24AA` |
| `condition_legend` (map legend) | `#191970` | `#FFC400` | `#FF8C00` | `#E53935` | `#8E24AA` |
| `daily_expandable_widget/*` | `systemBlue` | — | — | — | — |

The map's two agree with each other by hand-copied literal, not by construction.
The forecast pages use iOS system colours. **Normal is navy on the map and blue
in the sheet**; a river tapped from the map changes colour between the line and
the tile describing it.

Nothing enforces any of this. There is a canonical *ladder*
(`kFloodCategories`) and a canonical *classifier* (`FlowClassification`), but no
canonical *palette* — which is precisely the gap ADR 0002 closed for values and
left open for colour.

## Proposal

**1. One palette, next to the ladder.** Add `FloodPalette` beside
`kFloodCategories` in `flow_classification.dart`, keyed by ladder index so a
category can only be coloured by first being classified:

```dart
Color floodColor(int index);       // 0..4
Color floodColorFor(String? name); // name -> index -> colour, Unknown -> grey
```

Fixed hex, not `CupertinoColors`. The map cannot use dynamic colours — it feeds
ints to Mapbox — so a system-colour palette can never be the shared one. Fixed
hex works everywhere; light/dark variants live in the palette rather than at
each call site.

**2. Adopt the map's hex as canonical.** It is already the published contract:
it is baked into a daily vector tileset, printed in the legend, and seen by
every user on the map. Changing it means rebuilding tiles; changing the forecast
pages to match is a UI-only edit. Cheapest correct direction.

*Open question for Jerson:* Normal as `#191970` midnight navy is right for a
thin line on a map, but heavy for a chip or a bar. Options: keep navy
everywhere; or let Normal alone differ by surface and document why.

**3. Delete all five private switches** and the icon switch, routing them
through the palette. Delete `_getGradientColor` — colour that implies flood
state without consulting the ladder is worse than no colour.

**4. Make the mismatch impossible to reintroduce.** The bug survived because a
`String` category and a `switch` with a `default` cannot fail loudly. Either:

- **(a)** classify to an `int` index or enum at the boundary, so an unhandled
  category is a compile error rather than grey; or
- **(b)** keep strings but have `floodColorFor` assert in debug on an
  unrecognised non-null, non-'Unknown' name.

(a) is the real fix; (b) is a cheap net that could ship immediately.

**5. Pin it with tests.** One asserting every `kFloodCategories` entry resolves
to a distinct colour; one asserting the map service, legend and palette agree
literal-for-literal — the check that would have caught this divergence.

## Sequencing

Step 3 alone fixes the reported bug and is small. Steps 1–2 are the SSOT and
touch more surfaces. Step 4(a) is the durable fix and is best done while the
call sites are already open.

## Not in scope

Whether the ladder's colours are the *right* colours. Action `#FFC400` and
Moderate `#FF8C00` are the closest pair in the ramp and the hardest to tell
apart, particularly for red-green colour blindness. Every surface currently
labels as well as colours, so nothing depends on hue alone — worth revisiting,
but separately from unifying.
