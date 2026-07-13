// lib/ui/2_presentation/features/forecast/widgets/return_periods_sheet.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:rivr/utils/flow_format.dart';

/// Bottom sheet listing every return-period flood threshold for a stream, with
/// a one-tap "copy" that yields a cleanly aligned plain-text block.
///
/// [returnPeriods] maps recurrence interval (years) to flow, already in [unit].
class ReturnPeriodsSheet extends StatefulWidget {
  const ReturnPeriodsSheet({
    super.key,
    required this.returnPeriods,
    required this.unit,
    this.riverName,
  });

  final Map<int, double> returnPeriods;
  final String unit;
  final String? riverName;

  @override
  State<ReturnPeriodsSheet> createState() => _ReturnPeriodsSheetState();
}

class _ReturnPeriodsSheetState extends State<ReturnPeriodsSheet> {
  bool _copied = false;

  List<int> get _years => widget.returnPeriods.keys.toList()..sort();

  /// A tidy, column-aligned block: label left-padded, value right-aligned.
  String _plainText() {
    final years = _years;
    final labels = {for (final y in years) y: '$y-year'};
    final values = {
      for (final y in years) y: FlowFormat.grouped(widget.returnPeriods[y]!)
    };
    final labelW =
        labels.values.fold<int>(0, (m, s) => s.length > m ? s.length : m);
    final valueW =
        values.values.fold<int>(0, (m, s) => s.length > m ? s.length : m);

    final b = StringBuffer()
      ..writeln(widget.riverName == null
          ? 'Return periods'
          : 'Return periods — ${widget.riverName}');
    for (final y in years) {
      b.writeln('${labels[y]!.padRight(labelW)}   '
          '${values[y]!.padLeft(valueW)} ${widget.unit}');
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

  @override
  Widget build(BuildContext context) {
    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final rowBg =
        CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final sep = CupertinoColors.separator.resolveFrom(context);
    final accent = CupertinoColors.activeBlue.resolveFrom(context);
    final years = _years;

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
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: label)),
                  const SizedBox(height: 2),
                  Text(
                    widget.riverName == null
                        ? 'Flood-flow thresholds by recurrence interval'
                        : '${widget.riverName} · flood-flow thresholds',
                    style: TextStyle(fontSize: 13, color: sub),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: rowBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < years.length; i++) ...[
                      if (i > 0)
                        Container(
                            height: 0.5,
                            margin: const EdgeInsets.only(left: 16),
                            color: sep),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 13),
                        child: Row(
                          children: [
                            Text('${years[i]}-year',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: label)),
                            const Spacer(),
                            Text(
                              '${FlowFormat.grouped(widget.returnPeriods[years[i]]!)} ${widget.unit}',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: label,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
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
}
