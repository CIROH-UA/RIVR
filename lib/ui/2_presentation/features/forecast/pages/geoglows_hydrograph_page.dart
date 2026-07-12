// lib/ui/2_presentation/features/forecast/pages/geoglows_hydrograph_page.dart
//
// The full interactive hydrograph for a GEOGLOWS reach. GEOGLOWS data is a
// 15-day median + uncertainty band (not the NWM ForecastResponse the shared
// InteractiveChart/HydrographPage consume), so it gets its own Syncfusion
// chart: the median line, the uncertainty fan, and the same flood-category
// return-period plot bands used elsewhere (AppConstants.createFloodZonePlotBand).

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/services/0_config/shared/constants.dart';

class GeoglowsHydrographPage extends StatefulWidget {
  const GeoglowsHydrographPage({
    super.key,
    required this.points,
    required this.returnPeriods,
    required this.unit,
    required this.title,
  });

  final List<GeoglowsForecastPoint> points;
  final Map<int, double>? returnPeriods; // user unit
  final String unit;
  final String title;

  @override
  State<GeoglowsHydrographPage> createState() => _GeoglowsHydrographPageState();
}

class _GeoglowsHydrographPageState extends State<GeoglowsHydrographPage> {
  static const Color _teal = Color(0xFF0E5C78);

  late TrackballBehavior _trackball;
  bool _showBands = true;

  @override
  void initState() {
    super.initState();
    _trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipSettings: const InteractiveTooltip(enable: true, format: 'point.x : point.y'),
    );
  }

  List<PlotBand> _bands(double ymax) {
    final rp = widget.returnPeriods;
    if (rp == null) return [];
    final t2 = rp[2], t5 = rp[5], t10 = rp[10], t25 = rp[25];
    final bands = <PlotBand>[];
    if (t2 != null) bands.add(AppConstants.createFloodZonePlotBand(0, t2, 'normal'));
    if (t2 != null && t5 != null) {
      bands.add(AppConstants.createFloodZonePlotBand(t2, t5, 'action'));
    }
    if (t5 != null && t10 != null) {
      bands.add(AppConstants.createFloodZonePlotBand(t5, t10, 'moderate'));
    }
    if (t10 != null && t25 != null) {
      bands.add(AppConstants.createFloodZonePlotBand(t10, t25, 'major'));
    }
    if (t25 != null) {
      bands.add(AppConstants.createFloodZonePlotBand(t25, ymax, 'extreme'));
    }
    return bands;
  }

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    final maxUpper = pts.map((p) => p.upper).fold<double>(0, math.max);
    final t25 = widget.returnPeriods?[25];
    var ymax = maxUpper * 1.15;
    if (t25 != null) ymax = math.max(ymax, t25 * 1.15);
    final nowX = pts.isNotEmpty ? pts.first.validTime.toLocal() : null;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title, overflow: TextOverflow.ellipsis),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 16, 4),
                child: SfCartesianChart(
                  primaryXAxis: DateTimeAxis(
                    title: AxisTitle(
                      text: 'Date',
                      textStyle: TextStyle(
                        fontSize: 12,
                        color:
                            CupertinoColors.secondaryLabel.resolveFrom(context),
                      ),
                    ),
                    plotBands: nowX != null
                        ? [
                            PlotBand(
                              start: nowX,
                              end: nowX,
                              borderColor: CupertinoColors.systemBrown,
                              borderWidth: 1.5,
                              dashArray: const [2, 6],
                              text: 'Now\n',
                              textStyle: const TextStyle(
                                color: CupertinoColors.systemBrown,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                              verticalTextAlignment: TextAnchor.start,
                            ),
                          ]
                        : const [],
                  ),
                  primaryYAxis: NumericAxis(
                    minimum: 0,
                    maximum: ymax,
                    title: AxisTitle(
                      text: 'Flow (${widget.unit})',
                      textStyle: TextStyle(
                        fontSize: 12,
                        color:
                            CupertinoColors.secondaryLabel.resolveFrom(context),
                      ),
                    ),
                    plotBands: _showBands ? _bands(ymax) : const [],
                  ),
                  trackballBehavior: _trackball,
                  series: <CartesianSeries<GeoglowsForecastPoint, DateTime>>[
                    RangeAreaSeries<GeoglowsForecastPoint, DateTime>(
                      dataSource: pts,
                      xValueMapper: (p, _) => p.validTime.toLocal(),
                      highValueMapper: (p, _) => p.upper,
                      lowValueMapper: (p, _) => p.lower,
                      color: _teal.withValues(alpha: 0.16),
                      borderWidth: 0,
                      name: 'Uncertainty',
                    ),
                    LineSeries<GeoglowsForecastPoint, DateTime>(
                      dataSource: pts,
                      xValueMapper: (p, _) => p.validTime.toLocal(),
                      yValueMapper: (p, _) => p.median,
                      color: _teal,
                      width: 2.4,
                      name: 'Median',
                    ),
                  ],
                ),
              ),
            ),
            _controls(context),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                color: _showBands
                    ? CupertinoColors.activeBlue
                    : CupertinoColors.systemGrey5.resolveFrom(context),
                borderRadius: BorderRadius.circular(12),
                onPressed: () => setState(() => _showBands = !_showBands),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_showBands)
                      const Icon(CupertinoIcons.check_mark,
                          size: 16, color: CupertinoColors.white),
                    if (_showBands) const SizedBox(width: 6),
                    Text(
                      'Risk zones',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _showBands
                            ? CupertinoColors.white
                            : CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendDot(_teal),
              const SizedBox(width: 6),
              _legendText(context, 'Median'),
              const SizedBox(width: 18),
              _legendDot(_teal.withValues(alpha: 0.28)),
              const SizedBox(width: 6),
              _legendText(context, 'Uncertainty band'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color c) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
      );

  Widget _legendText(BuildContext context, String t) => Text(
        t,
        style: TextStyle(
          fontSize: 12,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      );
}
