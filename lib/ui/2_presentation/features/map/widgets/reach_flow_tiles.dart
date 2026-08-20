// lib/ui/2_presentation/features/map/widgets/reach_flow_tiles.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/services/0_config/shared/constants.dart';

/// What the second tile has to say about the days ahead.
enum PeakOutlook {
  /// The forecast peak is a higher category than the river is flowing now —
  /// the case where an orange line on the map reads "Normal" when tapped.
  rising,

  /// Already elevated and not going higher. Saying "no flooding expected"
  /// here would be flatly wrong, so the tile names the category instead.
  steady,

  /// Normal now, and nothing above the 2-year threshold in the window. Most
  /// rivers, most days.
  calm,

  /// Not classified yet, or classified as unknown. The tile waits rather than
  /// asserting an all-clear it cannot back up.
  unknown,
}

/// Which of the four states the second tile is in.
///
/// [peakIndex] is what the map is painting — an index into [kFloodCategories]
/// read off the daily flood tileset, or null when the reach carries no colour.
/// Null is meaningful, not missing: the tileset only contains reaches at or
/// above their own 2-year return period, so absence *is* the all-clear.
PeakOutlook peakOutlookFor({
  required int? peakIndex,
  required String? currentCategory,
  required bool isClassifying,
}) {
  if (isClassifying || currentCategory == null) return PeakOutlook.unknown;
  final now = kFloodCategories.indexOf(currentCategory);
  if (now < 0) return PeakOutlook.unknown;

  final peak = (peakIndex != null && peakIndex >= 1) ? peakIndex : 0;
  if (peak > now) return PeakOutlook.rising;
  return now == 0 ? PeakOutlook.calm : PeakOutlook.steady;
}

/// Current flow and the days ahead, side by side, over the flood ladder.
///
/// Replaces the full-width flow card and the text banner that used to explain
/// the map's colour. Two tiles of equal weight make the comparison structural:
/// the gap between two categories needs no sentence.
///
/// The peak tile leads with the category *word*, not a flow figure. The tile
/// carries `cat` and nothing else — no peak discharge, no peak time — so a
/// number here would have to be fetched or invented. Naming the category is
/// the honest thing the data supports.
class ReachFlowTiles extends StatelessWidget {
  const ReachFlowTiles({
    super.key,
    required this.flowText,
    required this.currentCategory,
    required this.peakCategoryIndex,
    required this.horizonLabel,
    required this.isClassifying,
  });

  /// Already formatted and unit-converted, e.g. `74.2 CFS`.
  final String flowText;
  final String? currentCategory;
  final int? peakCategoryIndex;

  /// e.g. `Next 5 days` — the real window for this reach's source.
  final String horizonLabel;
  final bool isClassifying;

  PeakOutlook get _outlook => peakOutlookFor(
        peakIndex: peakCategoryIndex,
        currentCategory: currentCategory,
        isClassifying: isClassifying,
      );

  /// Ladder index the peak marker sits on.
  int get _peakIndex {
    final p = peakCategoryIndex;
    if (p != null && p >= 1 && p < kFloodCategories.length) return p;
    return _nowIndex;
  }

  int get _nowIndex {
    final i = kFloodCategories.indexOf(currentCategory ?? '');
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // IntrinsicHeight so the two tiles match whichever is taller. Without
        // it, `stretch` asks for an unbounded height inside the Column and the
        // layout asserts.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _NowTile(
                flowText: flowText,
                category: currentCategory,
                isClassifying: isClassifying,
              )),
              const SizedBox(width: 9),
              Expanded(child: _PeakTile(
                outlook: _outlook,
                peakCategory: _peakIndex < kFloodCategories.length
                    ? kFloodCategories[_peakIndex]
                    : null,
                horizonLabel: horizonLabel,
              )),
            ],
          ),
        ),
        if (_outlook != PeakOutlook.unknown) ...[
          const SizedBox(height: 11),
          _FloodLadder(nowIndex: _nowIndex, peakIndex: _peakIndex),
        ],
      ],
    );
  }
}

/// Shared tile shell so both halves keep the same height and metrics.
class _Tile extends StatelessWidget {
  const _Tile({required this.child, this.borderColor, this.tint});

  final Widget child;
  final Color? borderColor;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: tint ??
            CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor ?? CupertinoColors.separator.resolveFrom(context),
          width: borderColor == null ? 0.5 : 1,
        ),
      ),
      child: child,
    );
  }
}

Widget _caption(BuildContext context, String text) => Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        // Paired ink, not hardcoded white: white on the Action yellow measures
        // 1.6:1 and on Moderate 2.3:1.
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppConstants.getFlowCategoryOnColor(label),
        ),
      ),
    );
  }
}

class _NowTile extends StatelessWidget {
  const _NowTile({
    required this.flowText,
    required this.category,
    required this.isClassifying,
  });

  final String flowText;
  final String? category;
  final bool isClassifying;

  @override
  Widget build(BuildContext context) {
    // "74.2 CFS" -> value + unit, so the unit can sit back without a second
    // formatter that could drift from the first.
    final cut = flowText.lastIndexOf(' ');
    final value = cut > 0 ? flowText.substring(0, cut) : flowText;
    final unit = cut > 0 ? flowText.substring(cut + 1) : '';

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption(context, 'Now'),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          if (isClassifying || category == null)
            const SizedBox(
              height: 20,
              child: Align(
                alignment: Alignment.centerLeft,
                child: CupertinoActivityIndicator(radius: 7),
              ),
            )
          else
            _Chip(
              label: category!,
              color: CupertinoDynamicColor.resolve(
                AppConstants.getFlowCategoryColor(category),
                context,
              ),
            ),
        ],
      ),
    );
  }
}

class _PeakTile extends StatelessWidget {
  const _PeakTile({
    required this.outlook,
    required this.peakCategory,
    required this.horizonLabel,
  });

  final PeakOutlook outlook;
  final String? peakCategory;
  final String horizonLabel;

  /// "Next 5 days" -> "next 5 days", for use inside a sentence fragment.
  String get _windowPhrase {
    final l = horizonLabel.trim();
    if (l.isEmpty) return 'the days ahead';
    return l[0].toLowerCase() + l.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    switch (outlook) {
      case PeakOutlook.unknown:
        return _Tile(
          child: SizedBox(
            height: 72,
            child: Center(
              child: CupertinoActivityIndicator(
                radius: 8,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
            ),
          ),
        );

      case PeakOutlook.calm:
        final green = CupertinoColors.systemGreen.resolveFrom(context);
        return _Tile(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.checkmark_circle, color: green, size: 24),
                const SizedBox(height: 6),
                Text(
                  'No flooding expected',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _windowPhrase,
                  style: TextStyle(
                    fontSize: 10,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
        );

      case PeakOutlook.rising:
      case PeakOutlook.steady:
        final color = CupertinoDynamicColor.resolve(
          AppConstants.getFlowCategoryColor(peakCategory),
          context,
        );
        return _Tile(
          borderColor: color,
          tint: color.withValues(alpha: 0.08),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _caption(
                context,
                outlook == PeakOutlook.rising ? 'Expected' : 'Peak',
              ),
              const SizedBox(height: 5),
              Text(
                peakCategory ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.4,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                _windowPhrase,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// The five categories as rungs, with a marker for now and one for the peak.
///
/// Redundant with the chips by design: the chips name the states, the ladder
/// shows the *distance* between them and how much headroom is left.
class _FloodLadder extends StatelessWidget {
  const _FloodLadder({required this.nowIndex, required this.peakIndex});

  final int nowIndex;
  final int peakIndex;

  @override
  Widget build(BuildContext context) {
    final same = nowIndex == peakIndex;
    final nowColor = CupertinoDynamicColor.resolve(
      AppConstants.getFlowCategoryColor(kFloodCategories[nowIndex]),
      context,
    );
    final peakColor = CupertinoDynamicColor.resolve(
      AppConstants.getFlowCategoryColor(kFloodCategories[peakIndex]),
      context,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 9),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground
            .resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.separator.resolveFrom(context),
          width: 0.5,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < kFloodCategories.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  child: Container(
                    height: 7,
                    decoration: BoxDecoration(
                      color: CupertinoDynamicColor.resolve(
                        AppConstants.getFlowCategoryColor(kFloodCategories[i]),
                        context,
                      ).withValues(
                        alpha: (i == nowIndex || i == peakIndex) ? 1 : 0.26,
                      ),
                      borderRadius: BorderRadius.circular(3.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < kFloodCategories.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  child: (i == nowIndex || i == peakIndex)
                      ? _Marker(
                          label: same
                              ? 'now & peak'
                              : (i == nowIndex ? 'now' : 'peak'),
                          color: i == nowIndex && !same ? nowColor : peakColor,
                        )
                      : const SizedBox(height: 22),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(CupertinoIcons.triangle_fill, size: 6, color: color),
        const SizedBox(height: 1),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
