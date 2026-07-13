// lib/ui/2_presentation/features/forecast/widgets/flow_gauge.dart
//
// The forecast-page hero: a five-zone flood-category gauge scaled to a
// reach's return-period thresholds. The arc is split into the app's
// Normal / Action / Moderate / Major / Extreme zones (equal slices); a
// marker rides the arc at the current flow, and the big number + category
// label sit inside the semicircle.
//
// Category colours come from the app's existing return-period palette
// (see AppConstants.getFlowCategoryColor): systemBlue / systemYellow /
// systemOrange / systemRed / systemPurple.

import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/utils/flow_format.dart';

class FlowGauge extends StatelessWidget {
  const FlowGauge({
    super.key,
    required this.currentFlow,
    required this.returnPeriods,
    required this.unit,
  });

  /// Current flow in the user's unit (null = unavailable).
  final double? currentFlow;

  /// Return-period thresholds keyed by recurrence year (needs 2/5/10/25).
  /// Null or incomplete => neutral gauge (no category).
  final Map<int, double>? returnPeriods;

  /// Display unit, e.g. "ft³/s" or "m³/s".
  final String unit;

  static const List<Color> _dynZoneColors = [
    CupertinoColors.systemBlue,
    CupertinoColors.systemYellow,
    CupertinoColors.systemOrange,
    CupertinoColors.systemRed,
    CupertinoColors.systemPurple,
  ];

  /// Ordered thresholds [t2, t5, t10, t25] or null when incomplete.
  List<double>? get _thresholds {
    final rp = returnPeriods;
    if (rp == null) return null;
    final t = [rp[2], rp[5], rp[10], rp[25]];
    if (t.any((v) => v == null)) return null;
    return t.cast<double>();
  }

  /// Category index 0..4, or -1 when it can't be determined. Uses the single
  /// app-wide classifier — never reimplement the ladder here.
  int get _categoryIndex =>
      FlowClassification.indexFor(currentFlow, returnPeriods);

  /// Marker position along the arc, 0 (left) .. 1 (right); -1 when unknown.
  double get _position {
    final f = currentFlow;
    final t = _thresholds;
    final i = _categoryIndex;
    if (f == null || t == null || i < 0) return -1;
    final bounds = [0.0, t[0], t[1], t[2], t[3], t[3] * 1.6];
    final lo = bounds[i];
    final hi = bounds[i + 1];
    final frac = hi > lo ? ((f - lo) / (hi - lo)).clamp(0.0, 1.0) : 1.0;
    return (i + frac) / 5.0;
  }

  @override
  Widget build(BuildContext context) {
    final i = _categoryIndex;
    final hasCategory = i >= 0;

    Color resolve(Color c) => CupertinoDynamicColor.resolve(c, context);
    final zoneColors = _dynZoneColors.map(resolve).toList();
    final neutral = resolve(CupertinoColors.systemGrey3);
    final markerColor = hasCategory ? zoneColors[i] : neutral;

    return AspectRatio(
      aspectRatio: 300 / 176,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _GaugePainter(
                zoneColors: hasCategory
                    ? zoneColors
                    : List.filled(5, neutral),
                position: _position,
                markerColor: markerColor,
                tickColor: resolve(CupertinoColors.label).withValues(alpha: 0.22),
                ringColor: resolve(CupertinoColors.systemBackground),
              ),
            ),
          ),
          // Flow value + category, seated inside the semicircle.
          Align(
            alignment: const Alignment(0, 0.32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: currentFlow != null
                            ? FlowFormat.grouped(currentFlow!)
                            : '—',
                        style: TextStyle(
                          fontSize: 54,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.5,
                          color: resolve(CupertinoColors.label),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      TextSpan(
                        text: ' $unit',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: resolve(CupertinoColors.secondaryLabel),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  hasCategory
                      ? kFloodCategories[i].toUpperCase()
                      : 'NO FLOOD DATA',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                    color: hasCategory
                        ? markerColor
                        : resolve(CupertinoColors.secondaryLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.zoneColors,
    required this.position,
    required this.markerColor,
    required this.tickColor,
    required this.ringColor,
  });

  final List<Color> zoneColors;
  final double position; // 0..1, or -1
  final Color markerColor;
  final Color tickColor;
  final Color ringColor;

  static const double _band = 15;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - 22;
    final center = Offset(size.width / 2, r + 12);
    final rect = Rect.fromCircle(center: center, radius: r);

    // Five equal category zones across the top semicircle (π .. 2π).
    const gap = 0.022;
    final zonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _band
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final start = math.pi + i * (math.pi / 5) + gap;
      final sweep = math.pi / 5 - 2 * gap;
      zonePaint.color = zoneColors[i];
      canvas.drawArc(rect, start, sweep, false, zonePaint);
    }

    // Tick marks around the rim.
    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    for (var k = 0; k <= 40; k++) {
      final a = math.pi + (k / 40) * math.pi;
      final dir = Offset(math.cos(a), math.sin(a));
      final inner = center + dir * (r + _band / 2 + 3);
      final outer = center + dir * (r + _band / 2 + (k % 5 == 0 ? 11 : 7));
      canvas.drawLine(inner, outer, tickPaint);
    }

    // Marker riding the arc at the current flow.
    if (position >= 0) {
      final a = math.pi + position.clamp(0.0, 1.0) * math.pi;
      final p = center + Offset(math.cos(a), math.sin(a)) * r;
      canvas.drawCircle(p, 16, Paint()..color = markerColor.withValues(alpha: 0.18));
      canvas.drawCircle(p, 9, Paint()..color = markerColor);
      canvas.drawCircle(
        p,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..color = ringColor,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.position != position ||
      old.markerColor != markerColor ||
      !_listEq(old.zoneColors, zoneColors);

  static bool _listEq(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
