// lib/ui/2_presentation/features/forecast/widgets/return_periods_sheet.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/utils/flow_format.dart';

/// Bottom sheet listing every return-period flood threshold for a stream, tinted
/// by the flood category each threshold marks, with a one-tap "copy" that yields
/// a cleanly aligned plain-text block.
///
/// [returnPeriods] maps recurrence interval (years) to flow, already in [unit].
/// [sourceNote] labels where the values come from (e.g. Gumbel / GEOGLOWS).
class ReturnPeriodsSheet extends StatefulWidget {
  const ReturnPeriodsSheet({
    super.key,
    required this.returnPeriods,
    required this.unit,
    this.riverName,
    this.sourceNote,
  });

  final Map<int, double> returnPeriods;
  final String unit;
  final String? riverName;
  final String? sourceNote;

  @override
  State<ReturnPeriodsSheet> createState() => _ReturnPeriodsSheetState();
}

class _ReturnPeriodsSheetState extends State<ReturnPeriodsSheet> {
  bool _copied = false;

  List<int> get _years => widget.returnPeriods.keys.toList()..sort();

  /// Flood category a given recurrence interval marks the start of.
  int _catForYear(int y) =>
      y >= 25 ? 4 : (y >= 10 ? 3 : (y >= 5 ? 2 : (y >= 2 ? 1 : 0)));

  /// A tidy, column-aligned block: label, category, and right-aligned value.
  String _plainText() {
    final years = _years;
    final labels = {for (final y in years) y: '$y-year'};
    final cats = {for (final y in years) y: kFloodCategories[_catForYear(y)]};
    final values = {
      for (final y in years) y: FlowFormat.grouped(widget.returnPeriods[y]!)
    };
    int maxLen(Iterable<String> xs) =>
        xs.fold(0, (m, s) => s.length > m ? s.length : m);
    final lw = maxLen(labels.values);
    final cw = maxLen(cats.values);
    final vw = maxLen(values.values);

    final b = StringBuffer()
      ..writeln(widget.riverName == null
          ? 'Return periods'
          : 'Return periods — ${widget.riverName}');
    for (final y in years) {
      b.writeln('${labels[y]!.padRight(lw)}   ${cats[y]!.padRight(cw)}   '
          '${values[y]!.padLeft(vw)} ${widget.unit}');
    }
    return b.toString().trimRight();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _plainText()));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _copied = false);
  }

  /// Width of the widest "N-year" label, so every category chip aligns to the
  /// same column regardless of the year's digit count or the user's text scale.
  double _yearColumnWidth(BuildContext context) {
    const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
    final scaler = MediaQuery.textScalerOf(context);
    var w = 0.0;
    for (final y in _years) {
      final tp = TextPainter(
        text: TextSpan(text: '$y-year', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      if (tp.width > w) w = tp.width;
    }
    return w + 2;
  }

  @override
  Widget build(BuildContext context) {
    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final faint = CupertinoColors.tertiaryLabel.resolveFrom(context);
    final accent = CupertinoColors.activeBlue.resolveFrom(context);
    final years = _years;
    final yearW = _yearColumnWidth(context);

    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Return periods',
                      style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          color: label)),
                  const SizedBox(height: 2),
                  Text(
                    widget.riverName ?? 'Flood-flow thresholds',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500, color: sub),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                children: [
                  for (final y in years) _row(context, y, yearW, label),
                ],
              ),
            ),
            if (widget.sourceNote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.info_circle,
                        size: 12.5, color: faint),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(widget.sourceNote!,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: faint)),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  color: _copied
                      ? CupertinoColors.systemGreen.resolveFrom(context)
                      : accent,
                  borderRadius: BorderRadius.circular(14),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  onPressed: _copy,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                          _copied
                              ? CupertinoIcons.checkmark_alt
                              : CupertinoIcons.doc_on_clipboard,
                          size: 18,
                          color: CupertinoColors.white),
                      const SizedBox(width: 8),
                      Text(_copied ? 'Copied' : 'Copy values',
                          style: const TextStyle(
                              color: CupertinoColors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 16)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int year, double yearW, Color label) {
    final ci = _catForYear(year);
    final cat = kFloodCategories[ci];
    final color = CupertinoDynamicColor.resolve(
        AppConstants.getFlowCategoryColor(cat), context);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          // Fixed-width year column keeps every category chip aligned.
          SizedBox(
            width: yearW,
            child: Text('$year-year',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: label)),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(cat.toUpperCase(),
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: color)),
          ),
          const Spacer(),
          Text(
            '${FlowFormat.grouped(widget.returnPeriods[year]!)} ${widget.unit}',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: label,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
