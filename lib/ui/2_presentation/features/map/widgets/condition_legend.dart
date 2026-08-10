// lib/ui/2_presentation/features/map/widgets/condition_legend.dart

import 'package:flutter/cupertino.dart';

/// Compact, collapsible key explaining the flood-condition stream colors. The
/// swatch colors must match the map exactly (see
/// `MapVectorTilesService` category colors + the GEOGLOWS base color).
class ConditionLegend extends StatefulWidget {
  const ConditionLegend({super.key});

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
            ],
          ],
        ),
      ),
    );
  }
}
