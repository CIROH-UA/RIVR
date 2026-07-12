// lib/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart
//
// The consolidated forecast page (NWM + GEOGLOWS). Replaces the separate
// reach-overview / geoglows-overview pages and the short/medium/long detail
// pages: one scrolling surface with a flood-category gauge hero, a range
// selector, and range-swappable detail widgets.
//
// STEP 1 (scaffold): gauge hero on static sample data + watered category
// background. Real data wiring, range selector, detail widgets, and the
// interactive chart land in later steps.

import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/flow_gauge.dart';

class ReachForecastPage extends StatelessWidget {
  const ReachForecastPage({
    super.key,
    required this.reachId,
    this.source = ForecastSource.nwm,
  });

  final String reachId;
  final ForecastSource source;

  // ---- STEP 1 placeholder data (Step 2 replaces with repository reads) ----
  double get _currentFlow => 640;
  Map<int, double> get _returnPeriods => const {
        2: 1200,
        5: 2400,
        10: 3600,
        25: 5800,
      };
  String get _unit => 'ft³/s';
  String get _riverName => 'Provo River';
  String get _location => 'Provo, Utah';

  /// Watered-down category tints (from the app's return-period palette),
  /// keyed by category index; a soft blue stands in for Normal.
  static const List<Color> _tints = [
    Color(0xFFEAF3FE), // Normal
    Color(0xFFFFF9C4), // Action
    Color(0xFFFFE0B2), // Moderate
    Color(0xFFFFCDD2), // Major
    Color(0xFFE1BEE7), // Extreme
  ];

  int _categoryIndex() {
    final f = _currentFlow;
    final rp = _returnPeriods;
    final t = [rp[2], rp[5], rp[10], rp[25]];
    if (t.any((v) => v == null)) return -1;
    final tt = t.cast<double>();
    if (f < tt[0]) return 0;
    if (f < tt[1]) return 1;
    if (f < tt[2]) return 2;
    if (f < tt[3]) return 3;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final i = _categoryIndex();
    final tint = i >= 0 ? _tints[i] : const Color(0xFFEFF3F7);

    return CupertinoPageScaffold(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tint, Color.lerp(tint, CupertinoColors.white, 0.55)!,
                CupertinoColors.white],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(river: _riverName, location: _location),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: FlowGauge(
                          currentFlow: _currentFlow,
                          returnPeriods: _returnPeriods,
                          unit: _unit,
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.river, required this.location});

  final String river;
  final String location;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Row(
        children: [
          _CircleButton(
            icon: CupertinoIcons.back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  river,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          _CircleButton(icon: CupertinoIcons.ellipsis, onPressed: () {}),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(40, 40),
      onPressed: onPressed,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: CupertinoColors.white.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(color: CupertinoColors.white.withValues(alpha: 0.7)),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.systemGrey.withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: 20,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      ),
    );
  }
}
