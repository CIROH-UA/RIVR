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
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/utils/flow_format.dart';
import 'package:rivr/utils/forecast_peak.dart';
import 'package:rivr/utils/forecast_trend.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/return_periods_sheet.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/stream_map_sheet.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/geo/geocoding_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_summary_payload.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/geoglows_hydrograph_page.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/flow_gauge.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/horizontal_flow_timeline.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/long_range_calendar.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/daily_flow_forecast_widget.dart';

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
/// Category index 0..4 (or -1) via the single app-wide classifier.
int _categoryFor(double? flow, Map<int, double>? rp) =>
    FlowClassification.indexFor(flow, rp);

class ReachForecastPage extends StatefulWidget {
  const ReachForecastPage({
    super.key,
    required this.reachId,
    this.source = ForecastSource.nwm,
    this.lat,
    this.lon,
  });

  final String reachId;
  final ForecastSource source;

  /// Tap coordinate (from the map). Used to reverse-geocode a location for
  /// GEOGLOWS reaches, which have no name/location of their own.
  final double? lat;
  final double? lon;

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

  // GEOGLOWS 15-day median points (peak source). NWM peaks come from the
  // ReachDataProvider's currentForecast (loaded below, read in build).
  List<GeoglowsForecastPoint>? _geoPoints;

  bool get _isGeoglows => widget.source.isGeoglows;

  @override
  void initState() {
    super.initState();
    _range = _isGeoglows ? ForecastRange.fifteenDay : ForecastRange.tenDay;
    _load();
    if (!_isGeoglows) {
      // Load the NWM forecast series into the shared provider (powers the
      // stat-card peaks + the embedded hourly/daily/calendar widgets).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final provider = context.read<ReachDataProvider>();
        if (provider.currentReach?.reachId != widget.reachId) {
          // loadReach (complete load) computes the ensemble 'mean' member and
          // warms the session cache, so the embedded widgets AND the reused
          // HydrographPage chart get a full ForecastResponse for every range.
          provider.loadReach(widget.reachId);
        }
      });
    }
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

      // GEOGLOWS reaches have no name — reverse-geocode the tap coordinate to a
      // place so the header reads "Stream near {city}" with a "City, Country"
      // subtitle, matching how NWM streams show their location.
      var riverName = 'Stream ${widget.reachId}';
      var location = '';
      if (widget.lat != null && widget.lon != null) {
        try {
          final geo = await GeocodingService.reverseGeocode(
              widget.lat!, widget.lon!);
          // 'state'/region is unreliable internationally (Mapbox returns codes
          // like '13' for French departments), so name from city + country.
          final city = geo['city'];
          final country = geo['country'];
          if (city != null && city.isNotEmpty) {
            riverName = 'Stream near $city';
          }
          location = [city, country]
              .where((s) => s != null && s.isNotEmpty)
              .join(', ');
        } catch (_) {
          // Keep the id fallback if geocoding fails.
        }
        if (!mounted) return;
      }

      setState(() {
        _details = ReachDetailsData(
          riverName: riverName,
          formattedLocation: location,
          currentFlow: fc.currentMedian,
          returnPeriods: fc.returnPeriods,
        );
        // Already in the user's unit (converted at decode) — no reconciliation.
        _returnPeriods = fc.returnPeriods;
        // Forecast, not retrospective: keep only from the current reading
        // onward. GEOGLOWS series start at the model-init time (often earlier
        // today); showing that recent past muddies "peak"/trend and the chart.
        // Trimming here makes everything downstream (chart, weekly split, peak,
        // day count) forward-looking from a single source.
        final fwd = ForecastPeak.upcomingPoints(
            fc.points.map((p) => (flow: p.median, time: p.validTime)));
        final firstUpcoming = fwd.isEmpty ? null : fwd.first.time;
        _geoPoints = firstUpcoming == null
            ? fc.points
            : fc.points
                .where((p) => !p.validTime.isBefore(firstUpcoming))
                .toList();
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

  int get _categoryIndex => _categoryFor(_details?.currentFlow, _returnPeriods);

  String get _river =>
      _details?.riverName ?? (_loading ? '' : 'Stream ${widget.reachId}');
  String get _location => _details?.formattedLocation ?? '';

  /// Number of distinct local calendar days covered by a series.
  int? _daySpan(ForecastSeries? s) {
    if (s == null || s.data.isEmpty) return null;
    return s.data
        .map((p) {
          final d = p.validTime.toLocal();
          return DateTime(d.year, d.month, d.day);
        })
        .toSet()
        .length;
  }

  /// Dynamic label for a NWM range ("9D"/"10D"/"30D"); nominal while loading.
  String _rangeLabel(ForecastRange r, ForecastResponse? nwm) {
    if (r == ForecastRange.today) return 'Today';
    final n = _daySpan(_nwmSeries(nwm, r));
    return n == null ? r.label : '${n}D';
  }

  /// Dynamic label for the GEOGLOWS forecast ("15-day forecast" etc.).
  String _geoLabel() {
    final pts = _geoPoints;
    if (pts == null || pts.isEmpty) return ForecastRange.fifteenDay.label;
    final n = pts
        .map((p) {
          final d = p.validTime.toLocal();
          return DateTime(d.year, d.month, d.day);
        })
        .toSet()
        .length;
    return '$n-day forecast';
  }

  /// The representative series for a NWM range (ensemble mean when present).
  ForecastSeries? _nwmSeries(ForecastResponse? f, ForecastRange r) {
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

  /// The upcoming (flow, time) points for the selected source/range — from the
  /// current reading onward (see [ForecastPeak]). This forecast page is
  /// forward-looking, so both the peak and the trend derive from this.
  List<({double flow, DateTime time})> _upcoming(ForecastResponse? nwm) {
    Iterable<({double flow, DateTime time})> pts;
    if (_isGeoglows) {
      final g = _geoPoints; // already trimmed to forward-only at load
      if (g == null || g.isEmpty) return const [];
      pts = g.map((p) => (flow: p.median, time: p.validTime));
    } else {
      final s = _nwmSeries(nwm, _range);
      if (s == null || s.data.isEmpty) return const [];
      pts = s.data.map((p) => (flow: p.flow, time: p.validTime));
    }
    return ForecastPeak.upcomingPoints(pts);
  }

  /// The highest *upcoming* flow, or null while loading — never a crest that
  /// already passed. See [ForecastPeak].
  ({double flow, DateTime time})? _peak(ForecastResponse? nwm) {
    ({double flow, DateTime time})? best;
    for (final p in _upcoming(nwm)) {
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
              _Header(
                river: _river,
                location: _location,
                onTitleTap: ((_details?.latitude ?? widget.lat) != null &&
                        (_details?.longitude ?? widget.lon) != null)
                    ? _showStreamMapSheet
                    : null,
              ),
              Expanded(child: _buildScroll()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScroll() {
    if (_loading) {
      return const _ForecastSkeleton();
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

    // The ReachDataProvider is a shared singleton, so guard against a stale
    // reach: only use its forecast when it's actually for THIS reach. While it
    // loads the new reach, the peaks/detail show their loading states instead
    // of the previous reach's numbers.
    ForecastResponse? nwm;
    if (!_isGeoglows) {
      final provider = context.watch<ReachDataProvider>();
      if (provider.currentReach?.reachId == widget.reachId) {
        nwm = provider.currentForecast;
      }
    }
    // Labels reflect the actual data: medium/long return a variable number of
    // days per reach (e.g. 9 vs 10), so the selector shows 9D/10D dynamically.
    final labels = <ForecastRange, String>{
      ForecastRange.today: 'Today',
      ForecastRange.tenDay: _rangeLabel(ForecastRange.tenDay, nwm),
      ForecastRange.thirtyDay: _rangeLabel(ForecastRange.thirtyDay, nwm),
      ForecastRange.fifteenDay: _geoLabel(),
    };

    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _RangeHeaderDelegate(
            isGeoglows: _isGeoglows,
            selected: _range,
            onChanged: (r) => setState(() => _range = r),
            labels: labels,
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
            child: _buildStatCard(nwm),
          ),
        ),
        // Outlook trend + detail: NWM range widgets, or the GEOGLOWS 15-day list.
        if (!_isGeoglows) ..._nwmBodySlivers(nwm),
        if (_isGeoglows) ..._geoglowsBodySlivers(),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  String _trendTitle() => switch (_range) {
        ForecastRange.today => "Today's trend",
        ForecastRange.tenDay => '10-day trend',
        ForecastRange.thirtyDay => '30-day trend',
        ForecastRange.fifteenDay => '15-day trend',
      };

  String _rangeForecastType() => switch (_range) {
        ForecastRange.today => 'short_range',
        ForecastRange.tenDay => 'medium_range',
        ForecastRange.thirtyDay => 'long_range',
        ForecastRange.fifteenDay => 'medium_range',
      };

  /// Opens the full interactive hydrograph (Syncfusion) for the current range.
  void _openChart() {
    AppRouter.pushHydrograph(
      context,
      reachId: widget.reachId,
      forecastType: _rangeForecastType(),
    );
  }

  List<Widget> _nwmBodySlivers(ForecastResponse? nwm) {
    final series = _nwmSeries(nwm, _range);
    final flows = series?.data.map((p) => p.flow).toList();
    final catI = _categoryFor(_details?.currentFlow, _returnPeriods);
    final color = catI >= 0
        ? CupertinoDynamicColor.resolve(_zoneColors[catI], context)
        : CupertinoColors.systemBlue.resolveFrom(context);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 0),
          child: _OutlookSection(
            title: _trendTitle(),
            flows: flows,
            color: color,
            onExpand: _openChart,
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 22),
          child: _buildDetail(nwm),
        ),
      ),
    ];
  }

  Widget _buildDetail(ForecastResponse? nwm) {
    // nwm is null until the shared provider holds THIS reach (see _buildScroll);
    // the hourly/calendar widgets read that same provider, so gate them too.
    if (nwm == null) return const _DetailLoading();
    switch (_range) {
      case ForecastRange.today:
        return HorizontalFlowTimeline(reachId: widget.reachId);
      case ForecastRange.tenDay:
        return DailyFlowForecastWidget(
          forecastResponse: nwm,
          forecastType: 'medium_range',
          allowMultipleExpanded: false,
          maxHeight: 620,
        );
      case ForecastRange.thirtyDay:
        return LongRangeCalendar(reachId: widget.reachId);
      case ForecastRange.fifteenDay:
        return const SizedBox.shrink();
    }
  }

  void _openGeoglowsChart() {
    final pts = _geoPoints;
    if (pts == null || pts.isEmpty) return;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => GeoglowsHydrographPage(
          points: pts,
          returnPeriods: _returnPeriods,
          unit: _unit,
          title: _river,
        ),
      ),
    );
  }

  List<Widget> _geoglowsBodySlivers() {
    final pts = _geoPoints;
    // Resolve the category palette once for the painters/widgets below, which
    // can't resolve CupertinoDynamicColor without a context.
    final catColors = _zoneColors
        .map((c) => CupertinoDynamicColor.resolve(c, context))
        .toList();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
          // For GEOGLOWS the 15-day ensemble reads as a trend, not a table:
          // the category-colored median + uncertainty-band chart IS the detail,
          // and the weekly split synthesizes it into "this week / next week".
          child: (pts == null || pts.isEmpty)
              ? const _DetailLoading()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _GeoglowsChartCard(
                      points: pts,
                      returnPeriods: _returnPeriods,
                      unit: _unit,
                      catColors: catColors,
                      onExpand: _openGeoglowsChart,
                    ),
                    const SizedBox(height: 24),
                    _GeoglowsWeeklySplit(
                      points: pts,
                      returnPeriods: _returnPeriods,
                      unit: _unit,
                      catColors: catColors,
                    ),
                  ],
                ),
        ),
      ),
    ];
  }

  Widget _buildStatCard(ForecastResponse? nwm) {
    final peak = _peak(nwm);
    final unit = _unit;

    String peakValue;
    String peakSub;
    Color? peakColor;
    if (peak != null) {
      peakValue = FlowFormat.grouped(peak.flow);
      final ci = _categoryFor(peak.flow, _returnPeriods);
      if (ci >= 0) {
        peakSub = kFloodCategories[ci];
        peakColor = CupertinoDynamicColor.resolve(_zoneColors[ci], context);
      } else {
        peakSub = unit;
      }
    } else {
      peakValue = '—';
      peakSub = '';
    }

    // Forward-looking trend from the current reading onward. This app forecasts,
    // so the middle stat says where the flow is *heading* — not a "time to peak"
    // that degenerates to a confusing "now / receding" once the river is already
    // at its high. "Rising" surfaces a genuine upcoming crest (with its ETA);
    // otherwise we describe the direction from now on.
    final up = _upcoming(nwm);
    String trendValue;
    String trendSub;
    if (up.isEmpty || peak == null) {
      trendValue = '—';
      trendSub = '';
    } else {
      // Shared with the weekly outlook so the two never disagree.
      switch (computeFlowTrend([for (final p in up) p.flow])) {
        case FlowTrend.rising:
          trendValue = 'Rising';
          trendSub = 'peaks ${_formatEta(peak.time)}';
        case FlowTrend.falling:
          trendValue = 'Falling';
          trendSub = 'easing';
        case FlowTrend.steady:
          trendValue = 'Steady';
          trendSub = 'holding';
      }
    }

    final rpSub = switch (_categoryFor(_details?.currentFlow, _returnPeriods)) {
      0 => 'below flood',
      1 => 'action stage',
      2 => 'moderate',
      3 => 'major',
      4 => 'extreme',
      _ => '',
    };

    final rp = _returnPeriods;
    return _StatCard(
      peakValue: peakValue,
      peakSub: peakSub,
      peakColor: peakColor,
      trendValue: trendValue,
      trendSub: trendSub,
      rpValue: _returnPeriodBand(),
      rpSub: rpSub,
      // Tapping the return period opens the full threshold list (with copy).
      onReturnPeriodTap:
          (rp != null && rp.isNotEmpty) ? _showReturnPeriodsSheet : null,
    );
  }

  /// Opens a bottom sheet with this one stream highlighted on a 3D map.
  void _showStreamMapSheet() {
    final lat = _details?.latitude ?? widget.lat;
    final lon = _details?.longitude ?? widget.lon;
    if (lat == null || lon == null) return;
    final catI = _categoryFor(_details?.currentFlow, _returnPeriods);
    final color = catI >= 0
        ? CupertinoDynamicColor.resolve(_zoneColors[catI], context)
        : CupertinoColors.activeBlue.resolveFrom(context);
    showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => StreamMapSheet(
        reachId: widget.reachId,
        isGeoglows: _isGeoglows,
        lat: lat,
        lon: lon,
        title: _river,
        subtitle: _location,
        highlightColor: color,
      ),
    );
  }

  void _showReturnPeriodsSheet() {
    final rp = _returnPeriods;
    if (rp == null || rp.isEmpty) return;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => ReturnPeriodsSheet(
        returnPeriods: rp,
        unit: _unit,
        riverName: _river,
        sourceNote: _isGeoglows
            ? 'Gumbel-derived · GEOGLOWS'
            : 'NWM return periods · CIROH',
      ),
    );
  }
}

// ── Sticky range-selector header ─────────────────────────────────────────────

class _RangeHeaderDelegate extends SliverPersistentHeaderDelegate {
  _RangeHeaderDelegate({
    required this.isGeoglows,
    required this.selected,
    required this.onChanged,
    required this.labels,
  });

  final bool isGeoglows;
  final ForecastRange selected;
  final ValueChanged<ForecastRange> onChanged;
  final Map<ForecastRange, String> labels;

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
          labels: labels,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_RangeHeaderDelegate old) =>
      old.selected != selected ||
      old.isGeoglows != isGeoglows ||
      !mapEquals(old.labels, labels);
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.isGeoglows,
    required this.selected,
    required this.onChanged,
    required this.labels,
  });

  final bool isGeoglows;
  final ForecastRange selected;
  final ValueChanged<ForecastRange> onChanged;
  final Map<ForecastRange, String> labels;

  static const List<ForecastRange> _nwmRanges = [
    ForecastRange.today,
    ForecastRange.tenDay,
    ForecastRange.thirtyDay,
  ];

  @override
  Widget build(BuildContext context) {
    // Frosted floating pill: BackdropFilter blurs whatever scrolls behind it,
    // and a top-lit gradient + white edge give it a glass sheen even at rest.
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            // Light frosted-white glass (not grey): the selected segment still
            // reads because it's opaque white with a shadow over this translucent
            // track, and the blur frosts whatever scrolls behind.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                CupertinoColors.white.withValues(alpha: 0.42),
                CupertinoColors.white.withValues(alpha: 0.20),
              ],
            ),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.7),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.systemGrey.withValues(alpha: 0.22),
                blurRadius: 16,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          padding: const EdgeInsets.all(3),
          child: isGeoglows
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 15, vertical: 7),
                  child: Text(
                    labels[ForecastRange.fifteenDay] ??
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
          labels[r] ?? r.label,
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
    required this.trendValue,
    required this.trendSub,
    required this.rpValue,
    required this.rpSub,
    this.onReturnPeriodTap,
  });

  final String peakValue;
  final String peakSub;
  final Color? peakColor;
  final String trendValue;
  final String trendSub;
  final String rpValue;
  final String rpSub;
  final VoidCallback? onReturnPeriodTap;

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
            child: _Stat(label: 'Trend', value: trendValue, sub: trendSub),
          ),
          _divider(context),
          Expanded(
            child: _Stat(
              label: 'Return period',
              value: rpValue,
              sub: rpSub,
              onTap: onReturnPeriodTap,
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
    this.onTap,
  });

  final String label;
  final String value;
  final String sub;
  final Color? subColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final column = Column(
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
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
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
            ),
            if (onTap != null) ...[
              const SizedBox(width: 3),
              Icon(
                CupertinoIcons.chevron_right,
                size: 12,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
            ],
          ],
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
    if (onTap == null) return column;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: column,
    );
  }
}

// ── Outlook trend ────────────────────────────────────────────────────────────

class _OutlookSection extends StatelessWidget {
  const _OutlookSection({
    required this.title,
    required this.flows,
    required this.color,
    this.onExpand,
  });

  final String title;
  final List<double>? flows;
  final Color color;

  /// When set, an Expand affordance opens the full interactive chart.
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final f = flows;
    final accent = CupertinoColors.activeBlue.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            if (onExpand != null)
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                onPressed: onExpand,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.arrow_up_left_arrow_down_right,
                        size: 13, color: accent),
                    const SizedBox(width: 4),
                    Text(
                      'Expand',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onExpand,
          child: Container(
            height: 80,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: CupertinoColors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(14),
            ),
            child: (f == null || f.length < 2)
                ? const Center(child: CupertinoActivityIndicator())
                : CustomPaint(
                    size: Size.infinite,
                    painter: _SparkPainter(f, color),
                  ),
          ),
        ),
      ],
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.flows, this.color);

  final List<double> flows;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (flows.length < 2) return;
    final maxV = flows.reduce((a, b) => a > b ? a : b);
    final minV = flows.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);

    Offset pt(int i) {
      final x = i / (flows.length - 1) * size.width;
      final norm = (flows[i] - minV) / range;
      final y = size.height - 6 - norm * (size.height - 14);
      return Offset(x, y);
    }

    final line = Path();
    final area = Path()..moveTo(0, size.height);
    for (var i = 0; i < flows.length; i++) {
      final p = pt(i);
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
      area.lineTo(p.dx, p.dy);
    }
    area
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.color != color || old.flows != flows;
}

class _DetailLoading extends StatelessWidget {
  const _DetailLoading();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: CupertinoColors.systemGrey5.resolveFrom(context),
      highlightColor: CupertinoColors.systemGrey6.resolveFrom(context),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 18),
        height: 130,
        decoration: BoxDecoration(
          color: CupertinoColors.white,
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

/// Skeleton shown while the gauge's reachSummary loads.
class _ForecastSkeleton extends StatelessWidget {
  const _ForecastSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double h, {double? w, double r = 16, EdgeInsets? m}) => Container(
          margin: m ?? const EdgeInsets.symmetric(horizontal: 20),
          height: h,
          width: w,
          decoration: BoxDecoration(
            color: CupertinoColors.white,
            borderRadius: BorderRadius.circular(r),
          ),
        );

    return Shimmer.fromColors(
      baseColor: CupertinoColors.systemGrey5.resolveFrom(context),
      highlightColor: CupertinoColors.systemGrey6.resolveFrom(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          bar(52, w: 210, r: 13),
          const SizedBox(height: 26),
          bar(150, r: 24),
          const SizedBox(height: 26),
          bar(92, r: 22),
          const SizedBox(height: 24),
          bar(88, r: 14),
        ],
      ),
    );
  }
}

// ── GEOGLOWS 15-day chart (median + uncertainty band) ────────────────────────

/// Concept #1 — the category-colored median + uncertainty-band hydrograph.
/// The median is coloured per segment by flood category, return-period
/// thresholds are drawn as labelled guide-lines, and the peak is called out.
class _GeoglowsChartCard extends StatelessWidget {
  const _GeoglowsChartCard({
    required this.points,
    required this.returnPeriods,
    required this.unit,
    required this.catColors,
    required this.onExpand,
  });

  final List<GeoglowsForecastPoint> points;
  final Map<int, double>? returnPeriods;
  final String unit;
  final List<Color> catColors;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final accent = CupertinoColors.activeBlue.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Outlook',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 0),
              onPressed: onExpand,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.arrow_up_left_arrow_down_right,
                      size: 13, color: accent),
                  const SizedBox(width: 4),
                  Text('Expand',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: accent)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onExpand,
          child: Container(
            height: 214,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: CupertinoColors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: CustomPaint(
              size: Size.infinite,
              painter: _HydrographPainter(
                points: points,
                returnPeriods: returnPeriods,
                unit: unit,
                catColors: catColors,
                accent: accent,
                gridColor: CupertinoColors.separator.resolveFrom(context),
                labelColor: CupertinoColors.secondaryLabel.resolveFrom(context),
                calloutBg: CupertinoColors.label.resolveFrom(context),
                calloutFg:
                    CupertinoColors.systemBackground.resolveFrom(context),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HydrographPainter extends CustomPainter {
  _HydrographPainter({
    required this.points,
    required this.returnPeriods,
    required this.unit,
    required this.catColors,
    required this.accent,
    required this.gridColor,
    required this.labelColor,
    required this.calloutBg,
    required this.calloutFg,
  });

  final List<GeoglowsForecastPoint> points;
  final Map<int, double>? returnPeriods;
  final String unit;
  final List<Color> catColors;
  final Color accent, gridColor, labelColor, calloutBg, calloutFg;

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  int _cat(double v) => FlowClassification.indexFor(v, returnPeriods);

  @override
  void paint(Canvas canvas, Size size) {
    final n = points.length;
    if (n < 2) return;

    final med = points.map((p) => p.median).toList();
    final lo = points.map((p) => p.lower).toList();
    final hi = points.map((p) => p.upper).toList();

    // Peak = highest flow in the (forward-only) series. Points before "now" are
    // trimmed upstream, so the max is by definition still upcoming.
    var peakI = 0;
    for (var i = 1; i < n; i++) {
      if (med[i] > med[peakI]) peakI = i;
    }

    // Build the peak callout up front so we can reserve headroom for it above
    // the peak — it then sits in clear space instead of on top of the line.
    final pd = points[peakI].validTime.toLocal();
    final tpTop = _tp('PEAK · ${_wd[pd.weekday - 1]} ${pd.day}',
        calloutFg.withValues(alpha: 0.72), 8.5, FontWeight.w700);
    final tpBot = _tp('${FlowFormat.grouped(med[peakI])} $unit', calloutFg, 11.5,
        FontWeight.w800);
    const cPadX = 10.0, cPadY = 6.0, cGap = 2.0;
    final calloutW =
        (tpTop.width > tpBot.width ? tpTop.width : tpBot.width) + cPadX * 2;
    final calloutH = cPadY * 2 + tpTop.height + cGap + tpBot.height;

    var minV = lo.reduce((a, b) => a < b ? a : b);
    var maxV = hi.reduce((a, b) => a > b ? a : b);
    final span0 = (maxV - minV).abs();
    final pad = span0 < 1e-6 ? 1.0 : span0 * 0.10;
    minV -= pad;
    maxV += pad;
    final range = maxV - minV;

    final padTop = calloutH + 12; // reserved headroom for the peak callout
    const padBottom = 16.0; // x labels
    final plotTop = padTop;
    final plotBottom = size.height - padBottom;
    const left = 2.0;
    final right = size.width - 2.0;

    double x(int i) => left + (right - left) * i / (n - 1);
    double y(double v) =>
        plotBottom - (v - minV) / range * (plotBottom - plotTop);

    // Uncertainty band.
    final band = Path()..moveTo(x(0), y(hi[0]));
    for (var i = 1; i < n; i++) {
      band.lineTo(x(i), y(hi[i]));
    }
    for (var i = n - 1; i >= 0; i--) {
      band.lineTo(x(i), y(lo[i]));
    }
    band.close();
    canvas.drawPath(band, Paint()..color = accent.withValues(alpha: 0.13));

    // Return-period threshold guide-lines (only those within view).
    final rp = returnPeriods;
    if (rp != null) {
      const yearToCat = {2: 1, 5: 2, 10: 3, 25: 4};
      final dashPaint = Paint()..strokeWidth = 1;
      yearToCat.forEach((year, ci) {
        final t = rp[year];
        if (t == null || t < minV || t > maxV) return;
        final yy = y(t);
        dashPaint.color = catColors[ci].withValues(alpha: 0.32);
        _dashedH(canvas, yy, left, right, dashPaint);
        _text(canvas, kFloodCategories[ci], Offset(right, yy - 13),
            catColors[ci].withValues(alpha: 0.9),
            size: 10, weight: FontWeight.w700, alignRight: true);
      });
    }

    // Median line, coloured per segment by the higher category of its endpoints.
    final seg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var i = 0; i < n - 1; i++) {
      final a = _cat(med[i]);
      final b = _cat(med[i + 1]);
      final ci = a >= b ? a : b;
      seg.color = ci >= 0 ? catColors[ci] : accent;
      canvas.drawLine(
          Offset(x(i), y(med[i])), Offset(x(i + 1), y(med[i + 1])), seg);
    }

    // X-axis baseline + date ticks.
    canvas.drawLine(Offset(left, plotBottom), Offset(right, plotBottom),
        Paint()..color = gridColor..strokeWidth = 1);
    const ticks = 4;
    for (var k = 0; k <= ticks; k++) {
      final i = ((n - 1) * k / ticks).round();
      final d = points[i].validTime.toLocal();
      _text(canvas, '${d.month}/${d.day}', Offset(x(i), plotBottom + 3),
          labelColor,
          size: 9.5, weight: FontWeight.w600, center: true);
    }

    // Peak dot + callout, placed above the peak in the reserved headroom so it
    // never sits over the plotted line.
    final pc = _cat(med[peakI]);
    final dotColor = pc >= 0 ? catColors[pc] : accent;
    final px = x(peakI);
    final py = y(med[peakI]);
    canvas.drawCircle(Offset(px, py), 5.5, Paint()..color = calloutFg);
    canvas.drawCircle(Offset(px, py), 4, Paint()..color = dotColor);

    var bx = px - calloutW / 2;
    if (bx < left) bx = left;
    if (bx + calloutW > right) bx = right - calloutW;
    final by = py - 10 - calloutH;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(bx, by, calloutW, calloutH), const Radius.circular(8)),
        Paint()..color = calloutBg);
    tpTop.paint(canvas, Offset(bx + cPadX, by + cPadY));
    tpBot.paint(canvas, Offset(bx + cPadX, by + cPadY + tpTop.height + cGap));
  }

  void _dashedH(Canvas c, double yy, double x0, double x1, Paint p) {
    const dash = 2.0, gap = 5.0;
    var xx = x0;
    while (xx < x1) {
      final xe = (xx + dash) > x1 ? x1 : (xx + dash);
      c.drawLine(Offset(xx, yy), Offset(xe, yy), p);
      xx += dash + gap;
    }
  }

  void _text(Canvas c, String s, Offset o, Color color,
      {double size = 10,
      FontWeight weight = FontWeight.w600,
      bool alignRight = false,
      bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(color: color, fontSize: size, fontWeight: weight)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = o.dx;
    if (alignRight) dx = o.dx - tp.width;
    if (center) dx = o.dx - tp.width / 2;
    tp.paint(c, Offset(dx, o.dy));
  }

  TextPainter _tp(String s, Color color, double size, FontWeight weight) =>
      TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(color: color, fontSize: size, fontWeight: weight)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(_HydrographPainter old) =>
      old.points != points ||
      old.returnPeriods != returnPeriods ||
      old.unit != unit ||
      old.catColors != catColors;
}

/// Concept #6 — synthesizes the 15-day series into "this week / next week",
/// each placed on the flood-category scale with its peak, trend, and range.
class _GeoglowsWeeklySplit extends StatelessWidget {
  const _GeoglowsWeeklySplit({
    required this.points,
    required this.returnPeriods,
    required this.unit,
    required this.catColors,
  });

  final List<GeoglowsForecastPoint> points;
  final Map<int, double>? returnPeriods;
  final String unit;
  final List<Color> catColors;

  static DateTime _day(DateTime t) {
    final d = t.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  @override
  Widget build(BuildContext context) {
    final days = points.map((p) => _day(p.validTime)).toSet().toList()..sort();
    if (days.length < 4) return const SizedBox.shrink();

    final cut = days.length > 7 ? 7 : (days.length / 2).ceil();
    final boundary = days[cut];
    final wk1 =
        points.where((p) => _day(p.validTime).isBefore(boundary)).toList();
    final wk2 =
        points.where((p) => !_day(p.validTime).isBefore(boundary)).toList();
    if (wk1.isEmpty || wk2.isEmpty) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _WeekCard(
            title: 'This week',
            pts: wk1,
            returnPeriods: returnPeriods,
            unit: unit,
            catColors: catColors,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _WeekCard(
            title: 'Next week',
            pts: wk2,
            returnPeriods: returnPeriods,
            unit: unit,
            catColors: catColors,
          ),
        ),
      ],
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({
    required this.title,
    required this.pts,
    required this.returnPeriods,
    required this.unit,
    required this.catColors,
  });

  final String title;
  final List<GeoglowsForecastPoint> pts;
  final Map<int, double>? returnPeriods;
  final String unit;
  final List<Color> catColors;

  static const _mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  @override
  Widget build(BuildContext context) {
    // Summaries reflect the *upcoming* part of the week (from the current
    // reading onward), so a week's "peak" is never a crest that already passed
    // — consistent with the stat card and chart. See [ForecastPeak].
    final upcoming = ForecastPeak.upcomingPoints(
        [for (final p in pts) (flow: p.median, time: p.validTime)]);
    final meds = (upcoming.isEmpty ? pts.map((p) => p.median) : upcoming.map((p) => p.flow))
        .toList();
    final minMed = meds.reduce((a, b) => a < b ? a : b);
    final maxMed = meds.reduce((a, b) => a > b ? a : b);
    final cat = FlowClassification.indexFor(maxMed, returnPeriods);
    final rising = pts.last.median >= pts.first.median;
    final start = pts.first.validTime.toLocal();
    final end = pts.last.validTime.toLocal();

    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final faint = CupertinoColors.tertiaryLabel.resolveFrom(context);
    final catColor = cat >= 0 ? catColors[cat] : sub;

    String range() {
      final sameMonth = start.month == end.month;
      return sameMonth
          ? '${_mo[start.month - 1]} ${start.day}–${end.day}'
          : '${_mo[start.month - 1]} ${start.day} – ${_mo[end.month - 1]} ${end.day}';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: label)),
          Text(range(),
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: faint)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(FlowFormat.grouped(maxMed),
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: label)),
              const SizedBox(width: 4),
              Text(unit,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: sub)),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: catColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${cat >= 0 ? kFloodCategories[cat] : 'Peak'} · ${rising ? '▲ rising' : '▼ easing'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: sub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          // Category ladder with only the week's peak category highlighted
          // (longer, full colour, outlined). The full scale already lives in the
          // gauge arc above, so here we just show which category the week hits.
          Row(
            children: [
              for (var i = 0; i < 5; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  flex: i == cat ? 26 : 10,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: i == cat
                          ? catColors[i]
                          : catColors[i].withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(4),
                      border:
                          i == cat ? Border.all(color: label, width: 1.5) : null,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text('range ${FlowFormat.compact(minMed)}–${FlowFormat.compact(maxMed)}',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w600, color: faint)),
        ],
      ),
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.river, required this.location, this.onTitleTap});

  final String river;
  final String location;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Row(
        children: [
          _CircleButton(
            icon: CupertinoIcons.back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            // Tapping the name/location opens the stream on a map.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTitleTap,
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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (onTitleTap != null) ...[
                          Icon(CupertinoIcons.map, size: 11, color: sub),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: sub),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          // Balances the back button so the title stays centred. A real
          // overflow menu (share / favourite / units) can slot in here later.
          const SizedBox(width: 40),
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
