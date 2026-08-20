// lib/ui/2_presentation/features/map/widgets/condition_legend.dart

import 'package:flutter/cupertino.dart';

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

  // (label, color) from calm to severe. "Normal" is the base stream color.
  static const List<(String, Color)> _entries = [
    ('Normal', Color(0xFF191970)), // midnight blue — shared base, both sources
    ('Action', Color(0xFFFFC400)), // yellow  — > 2-yr
    ('Moderate', Color(0xFFFF8C00)), // orange — > 5-yr
    ('Major', Color(0xFFE53935)), // red      — > 10-yr
    ('Extreme', Color(0xFF8E24AA)), // purple  — > 25-yr
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
