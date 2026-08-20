// lib/ui/2_presentation/features/map/widgets/condition_legend.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/services/0_config/shared/constants.dart';

/// Compact, collapsible key explaining the flood-condition stream colors. The
/// swatch colors must match the map exactly (see
/// `MapVectorTilesService` category colors + the GEOGLOWS base color).
class ConditionLegend extends StatefulWidget {
  const ConditionLegend({super.key, this.dataDate});

  /// The date the colours describe, `YYYY-MM-DD`, from Remote Config.
  ///
  /// Always shown when known, not only when stale. If the date appeared only
  /// sometimes its absence would have to be *inferred* as "this is current",
  /// and an intermittent label reads as a warning rather than as information.
  /// It is the OLDER of the two source dates — the tileset mixes GEOGLOWS'
  /// daily run with whichever NOAA cycle was latest — so it never overstates
  /// freshness (ADR 0005).
  final String? dataDate;

  /// The base stream colour, which is what an un-flooded river actually looks
  /// like on this map. Not a flood category and not in the shared palette — it
  /// is the network's geometry colour, and the legend's job here is to explain
  /// the map rather than to restate the ladder.
  static const Color _streamColor = Color(0xFF191970); // midnight navy

  /// (label, colour) from calm to severe.
  ///
  /// Rungs 1-4 come from the shared palette; only the "Normal" swatch is local,
  /// because on the map a normal river is drawn as base network rather than
  /// painted by the flood tileset. Previously all five were hand-copied hex
  /// that happened to match the map service's hand-copied hex (ADR 0007).
  static List<(String, Color)> get _entries => [
    ('Normal', _streamColor),
    for (var i = 1; i < kFloodCategories.length; i++)
      (kFloodCategories[i], AppConstants.floodCategoryColors[i]),
  ];

  @override
  State<ConditionLegend> createState() => _ConditionLegendState();
}

class _ConditionLegendState extends State<ConditionLegend> {
  bool _expanded = true;

  static const List<String> _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// `2026-08-20` -> `As of August 20th`. Null when unknown, so the row is
  /// omitted rather than showing a placeholder the user has to interpret.
  String? get _formattedDate {
    final raw = widget.dataDate;
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return 'As of ${_months[parsed.month - 1]} ${_ordinal(parsed.day)}';
  }

  /// 1 -> `1st`, 22 -> `22nd`, 13 -> `13th`. The teens are all `th` regardless
  /// of their last digit, which is the case a naive lookup gets wrong.
  static String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    return switch (day % 10) {
      1 => '${day}st',
      2 => '${day}nd',
      3 => '${day}rd',
      _ => '${day}th',
    };
  }

  @override
  Widget build(BuildContext context) {
    final bg = CupertinoColors.systemBackground
        .resolveFrom(context)
        .withValues(alpha: 0.92);
    final labelColor = CupertinoColors.label.resolveFrom(context);
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.black.withValues(alpha: 0.15),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'FLOOD RISK',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: secondary,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  _expanded
                      ? CupertinoIcons.chevron_down
                      : CupertinoIcons.chevron_up,
                  size: 12,
                  color: secondary,
                ),
              ],
            ),
            if (_expanded) ...[
              // One line, not two. The forecast window this covers is not
              // stated here on purpose: it depends on which model covers the
              // area — GEOGLOWS publishes 15 days outside the US, NOAA 5 days
              // across CONUS and Alaska, and only 48 hours for Hawaii and
              // Puerto Rico — so any number would be wrong somewhere. The
              // exact window for one river belongs in its detail sheet, where
              // it can be specific (ADR 0005).
              if (_formattedDate != null) ...[
                const SizedBox(height: 6),
                Text(
                  _formattedDate!,
                  style: TextStyle(fontSize: 11, color: secondary),
                ),
              ],
              const SizedBox(height: 8),
              for (final (label, color) in ConditionLegend._entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 16,
                        height: 6,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(fontSize: 12.5, color: labelColor),
                      ),
                    ],
                  ),
                ),
              // NOAA's terms require their material to be identified and not
              // presented as our own; GEOGLOWS asks to be credited likewise.
              const SizedBox(height: 2),
              Text(
                'NOAA NWM · GEOGLOWS',
                style: TextStyle(fontSize: 10, color: secondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
