// lib/ui/2_presentation/features/map/widgets/reach_details_disclosure.dart

import 'package:flutter/cupertino.dart';

/// One label/value pair inside the disclosure.
class DetailRow {
  const DetailRow(this.label, this.value);
  final String label;
  final String value;
}

/// Reach metadata, collapsed behind a single row.
///
/// Reach ID, stream order and coordinates used to sit *above* current flow and
/// at equal weight, so the sheet led with identifiers rather than the answer
/// the user tapped for. They are still one tap away — this is a disclosure, not
/// a deletion; the ids matter to the NWM and GEOGLOWS teams reading model
/// behaviour, just not to someone asking whether a river is high.
///
/// Expands in place rather than pushing a page: the metadata is short, and
/// keeping the flow tiles on screen while it unfolds preserves the context the
/// numbers belong to.
class ReachDetailsDisclosure extends StatefulWidget {
  const ReachDetailsDisclosure({
    super.key,
    required this.rows,
    this.thresholds = const [],
    this.initiallyExpanded = false,
  });

  final List<DetailRow> rows;

  /// Return-period thresholds, when the reach has them. Shown in their own
  /// group because they explain *why* a flow lands in a category — the one
  /// piece of metadata that is genuinely about the flood, not the reach.
  final List<DetailRow> thresholds;

  final bool initiallyExpanded;

  @override
  State<ReachDetailsDisclosure> createState() => _ReachDetailsDisclosureState();
}

class _ReachDetailsDisclosureState extends State<ReachDetailsDisclosure>
    with SingleTickerProviderStateMixin {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final line = CupertinoColors.separator.resolveFrom(context);
    final surface =
        CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: line, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              child: Row(
                children: [
                  Text(
                    'Details',
                    style: TextStyle(
                      fontSize: 13.5,
                      color: _expanded
                          ? CupertinoColors.label.resolveFrom(context)
                          : CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      CupertinoIcons.chevron_right,
                      size: 14,
                      color:
                          CupertinoColors.tertiaryLabel.resolveFrom(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // AnimatedSize over a conditional child, not AnimatedCrossFade:
          // cross-fade keeps both children mounted, so collapsed metadata
          // would still sit in the tree for VoiceOver to read out.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? _Body(rows: widget.rows, thresholds: widget.thresholds)
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.rows, required this.thresholds});

  final List<DetailRow> rows;
  final List<DetailRow> thresholds;

  @override
  Widget build(BuildContext context) {
    final line = CupertinoColors.separator.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 0, 13, 6),
      child: Column(
        children: [
          Container(height: 0.5, color: line),
          for (final r in rows) _Row(row: r),
          if (thresholds.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Row(
                children: [
                  Text(
                    'FLOOD THRESHOLDS',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color:
                          CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                ],
              ),
            ),
            for (final t in thresholds) _Row(row: t),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row});
  final DetailRow row;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.label,
            style: TextStyle(
              fontSize: 12.5,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              row.value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12.5,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
