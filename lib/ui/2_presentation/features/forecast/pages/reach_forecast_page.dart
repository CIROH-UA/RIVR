// lib/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart
//
// The consolidated forecast page (NWM + GEOGLOWS). Replaces the separate
// reach-overview / geoglows-overview pages and the short/medium/long detail
// pages: one scrolling surface with a flood-category gauge hero, a range
// selector, and range-swappable detail widgets.
//
// STEP 4: sticky range selector + stat card (Peak / Time to peak / Return
// period). The gauge reads reachSummary (NWM) or geoglowsForecast (GEOGLOWS);
// peaks come from the range forecast series. Outlook + detail widgets + the
// interactive chart land in later steps.

import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_summary_payload.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/flow_gauge.dart';

/// The forecast horizons the range selector offers.
enum ForecastRange { today, tenDay, thirtyDay, fifteenDay }

extension on ForecastRange {
  String get label => switch (this) {
        ForecastRange.today => 'Today',
        ForecastRange.tenDay => '10D',
        ForecastRange.thirtyDay => '30D',
        ForecastRange.fifteenDay => '15-day forecast',
      };
}

const List<Color> _zoneColors = [
  CupertinoColors.systemBlue,
  CupertinoColors.systemYellow,
  CupertinoColors.systemOrange,
  CupertinoColors.systemRed,
  CupertinoColors.systemPurple,
];
const List<String> _zoneNames = [
  'Normal',
  'Action',
  'Moderate',
  'Major',
  'Extreme',
];

String _formatFlow(double v) {
  final s = v.round().toString();
  final buf = StringBuffer();
  for (var k = 0; k < s.length; k++) {
    if (k > 0 && (s.length - k) % 3 == 0) buf.write(',');
    buf.write(s[k]);
  }
  return buf.toString();
}

/// Category index 0..4 for [flow] against [rp] (needs 2/5/10/25), or -1.
int _categoryFor(double? flow, Map<int, double>? rp) {
  if (flow == null || rp == null) return -1;
  final t = [rp[2], rp[5], rp[10], rp[25]];
  if (t.any((v) => v == null)) return -1;
  final tt = t.cast<double>();
  if (flow < tt[0]) return 0;
  if (flow < tt[1]) return 1;
  if (flow < tt[2]) return 2;
  if (flow < tt[3]) return 3;
  return 4;
}

class ReachForecastPage extends StatefulWidget {
  const ReachForecastPage({
    super.key,
    required this.reachId,
    this.source = ForecastSource.nwm,
  });

  final String reachId;
  final ForecastSource source;

  @override
  State<ReachForecastPage> createState() => _ReachForecastPageState();
}

class _ReachForecastPageState extends State<ReachForecastPage> {
  /// Watered-down category tints; a soft blue stands in for Normal.
  static const List<Color> _tints = [
    Color(0xFFEAF3FE),
    Color(0xFFFFF9C4),
    Color(0xFFFFE0B2),
    Color(0xFFFFCDD2),
    Color(0xFFE1BEE7),
  ];
  static const Color _neutralTint = Color(0xFFEFF3F7);

  bool _loading = true;
  String? _error;
  ReachDetailsData? _details;
  Map<int, double>? _returnPeriods; // in the user's display unit
  String _unit = 'ft³/s';

  late ForecastRange _range;

  // Forecast series used for per-range peaks (loaded after the gauge).
  ForecastResponse? _forecast; // NWM
  List<GeoglowsForecastPoint>? _geoPoints; // GEOGLOWS

  bool get _isGeoglows => widget.source.isGeoglows;

  @override
  void initState() {
    super.initState();
    _range = _isGeoglows ? ForecastRange.fifteenDay : ForecastRange.tenDay;
    _load();
  }

  Future<void> _load() async {
    if (_isGeoglows) {
      await _loadGeoglows();
      return;
    }

    final unitService = GetIt.I<IFlowUnitPreferenceService>();
    try {
      final entry = await GetIt.I<IRiverDataRepository>().read(
        RiverDataKey(
          source: ForecastSource.nwm,
          reachId: widget.reachId,
          product: ForecastProduct.reachSummary,
        ),
      );
      if (!mounted) return;
      if (entry == null) {
        throw Exception('No reach details available.');
      }
      final details = ReachSummaryPayload.decode(entry, unitService);
      final currentUnit = unitService.currentFlowUnit;
      final converted = details.returnPeriods?.map(
        (year, flow) =>
            MapEntry(year, unitService.convertFlow(flow, 'CMS', currentUnit)),
      );

      setState(() {
        _details = details;
        _returnPeriods = converted;
        _unit = unitService.getDisplayUnit();
        _loading = false;
      });
      _loadNwmForecast();
    } catch (e) {
      if (!mounted) return;
      AppLogger.error('ReachForecastPage', 'Error loading reach details', e);
      setState(() {
        _error = 'Failed to load reach details';
        _loading = false;
      });
    }
  }

  Future<void> _loadGeoglows() async {
    final unitService = GetIt.I<IFlowUnitPreferenceService>();
    try {
      final entry = await GetIt.I<IRiverDataRepository>().read(
        RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: widget.reachId,
          product: ForecastProduct.geoglowsForecast,
        ),
      );
      if (!mounted) return;
      if (entry == null) {
        throw Exception('No GEOGLOWS forecast available.');
      }
      final fc = GeoglowsForecastPayload.decode(entry, unitService);
      setState(() {
        _details = ReachDetailsData(
          riverName: 'Stream ${widget.reachId}',
          formattedLocation: '',
          currentFlow: fc.currentMedian,
          returnPeriods: fc.returnPeriods,
        );
        // Already in the user's unit (converted at decode) — no reconciliation.
        _returnPeriods = fc.returnPeriods;
        _geoPoints = fc.points;
        _unit = unitService.getDisplayUnit();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      AppLogger.error('ReachForecastPage', 'Error loading GEOGLOWS forecast', e);
      setState(() {
        _error = 'Failed to load forecast';
        _loading = false;
      });
    }
  }

  /// Loads the full NWM forecast (short/medium/long) so the stat card can show
  /// per-range peaks. Non-fatal: on failure the peaks simply stay blank.
  Future<void> _loadNwmForecast() async {
    try {
      final forecast = await GetIt.I<IForecastService>()
          .loadCompleteReachData(widget.reachId);
      if (!mounted) return;
      setState(() => _forecast = forecast);
    } catch (e) {
      AppLogger.warning(
        'ReachForecastPage',
        'Forecast series unavailable for peaks: $e',
      );
    }
  }

  int get _categoryIndex => _categoryFor(_details?.currentFlow, _returnPeriods);

  String get _river =>
      _details?.riverName ?? (_loading ? '' : 'Stream ${widget.reachId}');
  String get _location => _details?.formattedLocation ?? '';

  /// The representative series for a NWM range (ensemble mean when present).
  ForecastSeries? _nwmSeries(ForecastRange r) {
    final f = _forecast;
    if (f == null) return null;
    switch (r) {
      case ForecastRange.today:
        return f.shortRange;
      case ForecastRange.tenDay:
        return f.mediumRange['mean'] ??
            (f.mediumRange.isNotEmpty ? f.mediumRange.values.first : null);
      case ForecastRange.thirtyDay:
        return f.longRange['mean'] ??
            (f.longRange.isNotEmpty ? f.longRange.values.first : null);
      case ForecastRange.fifteenDay:
        return null;
    }
  }

  /// Peak (flow, time) within the selected range, or null while loading.
  ({double flow, DateTime time})? _peak() {
    Iterable<({double flow, DateTime time})> pts;
    if (_isGeoglows) {
      final g = _geoPoints;
      if (g == null || g.isEmpty) return null;
      pts = g.map((p) => (flow: p.median, time: p.validTime));
    } else {
      final s = _nwmSeries(_range);
      if (s == null || s.data.isEmpty) return null;
      pts = s.data.map((p) => (flow: p.flow, time: p.validTime));
    }
    ({double flow, DateTime time})? best;
    for (final p in pts) {
      if (best == null || p.flow > best.flow) best = p;
    }
    return best;
  }

  String _formatEta(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.isNegative) return 'now';
    if (d.inHours < 24) {
      final h = d.inHours < 1 ? 1 : d.inHours;
      return '$h hr';
    }
    final days = d.inDays;
    return '$days ${days == 1 ? 'day' : 'days'}';
  }

  /// Return-period recurrence band for the current flow.
  String _returnPeriodBand() {
    final f = _details?.currentFlow;
    final rp = _returnPeriods;
    final i = _categoryFor(f, rp);
    return switch (i) {
      0 => '< 2 yr',
      1 => '2–5 yr',
      2 => '5–10 yr',
      3 => '10–25 yr',
      4 => '25 yr +',
      _ => '—',
    };
  }

  @override
  Widget build(BuildContext context) {
    final i = _categoryIndex;
    final tint = i >= 0 ? _tints[i] : _neutralTint;

    return CupertinoPageScaffold(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              tint,
              Color.lerp(tint, CupertinoColors.white, 0.55)!,
              CupertinoColors.white,
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(river: _river, location: _location),
              Expanded(child: _buildScroll()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScroll() {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator(radius: 14));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _RangeHeaderDelegate(
            isGeoglows: _isGeoglows,
            selected: _range,
            onChanged: (r) => setState(() => _range = r),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: FlowGauge(
              currentFlow: _details?.currentFlow,
              returnPeriods: _returnPeriods,
              unit: _unit,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 0),
            child: _buildStatCard(),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildStatCard() {
    final peak = _peak();
    final unit = _unit;

    String peakValue;
    String peakSub;
    Color? peakColor;
    if (peak != null) {
      peakValue = _formatFlow(peak.flow);
      final ci = _categoryFor(peak.flow, _returnPeriods);
      if (ci >= 0) {
        peakSub = _zoneNames[ci];
        peakColor = CupertinoDynamicColor.resolve(_zoneColors[ci], context);
      } else {
        peakSub = unit;
      }
    } else {
      peakValue = '—';
      peakSub = '';
    }

    return _StatCard(
      peakValue: peakValue,
      peakSub: peakSub,
      peakColor: peakColor,
      etaValue: peak != null ? _formatEta(peak.time) : '—',
      rpValue: _returnPeriodBand(),
    );
  }
}

// ── Sticky range-selector header ─────────────────────────────────────────────

class _RangeHeaderDelegate extends SliverPersistentHeaderDelegate {
  _RangeHeaderDelegate({
    required this.isGeoglows,
    required this.selected,
    required this.onChanged,
  });

  final bool isGeoglows;
  final ForecastRange selected;
  final ValueChanged<ForecastRange> onChanged;

  static const double _height = 60;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return SizedBox(
      height: _height,
      child: Center(
        child: _RangeSelector(
          isGeoglows: isGeoglows,
          selected: selected,
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_RangeHeaderDelegate old) =>
      old.selected != selected || old.isGeoglows != isGeoglows;
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.isGeoglows,
    required this.selected,
    required this.onChanged,
  });

  final bool isGeoglows;
  final ForecastRange selected;
  final ValueChanged<ForecastRange> onChanged;

  static const List<ForecastRange> _nwmRanges = [
    ForecastRange.today,
    ForecastRange.tenDay,
    ForecastRange.thirtyDay,
  ];

  @override
  Widget build(BuildContext context) {
    // Frosted floating pill (no full-width bar; content scrolls behind it).
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(13),
            border:
                Border.all(color: CupertinoColors.white.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.systemGrey.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.all(3),
          child: isGeoglows
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 15, vertical: 7),
                  child: Text(
                    ForecastRange.fifteenDay.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in _nwmRanges) _segment(context, r),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, ForecastRange r) {
    final isSelected = r == selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(r),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? CupertinoColors.white : null,
          borderRadius: BorderRadius.circular(10),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: CupertinoColors.systemGrey.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          r.label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: isSelected
                ? CupertinoColors.label
                : CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ),
    );
  }
}

// ── Stat card ────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.peakValue,
    required this.peakSub,
    required this.peakColor,
    required this.etaValue,
    required this.rpValue,
  });

  final String peakValue;
  final String peakSub;
  final Color? peakColor;
  final String etaValue;
  final String rpValue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
      decoration: BoxDecoration(
        color: CupertinoColors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: CupertinoColors.white.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.systemGrey.withValues(alpha: 0.28),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _Stat(
              label: 'Peak · range',
              value: peakValue,
              subColor: peakColor,
              sub: peakSub,
            ),
          ),
          _divider(context),
          Expanded(
            child: _Stat(label: 'Time to peak', value: etaValue, sub: 'rising'),
          ),
          _divider(context),
          Expanded(
            child: _Stat(
              label: 'Return period',
              value: rpValue,
              sub: 'current',
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) => Container(
        width: 1,
        height: 44,
        color: CupertinoColors.separator.resolveFrom(context),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.sub,
    this.subColor,
  });

  final String label;
  final String value;
  final String sub;
  final Color? subColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: subColor ??
                  CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────────────

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
                if (location.isNotEmpty)
                  Text(
                    location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color:
                          CupertinoColors.secondaryLabel.resolveFrom(context),
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
