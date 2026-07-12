// lib/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart
//
// The consolidated forecast page (NWM + GEOGLOWS). Replaces the separate
// reach-overview / geoglows-overview pages and the short/medium/long detail
// pages: one scrolling surface with a flood-category gauge hero, a range
// selector, and range-swappable detail widgets.
//
// STEP 2: gauge hero wired to real NWM data through the SSOT repository
// (reachSummary product). Range selector, detail widgets, GEOGLOWS, and the
// interactive chart land in later steps.

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_summary_payload.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/flow_gauge.dart';

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
  /// Watered-down category tints (from the app's return-period palette),
  /// keyed by category index; a soft blue stands in for Normal.
  static const List<Color> _tints = [
    Color(0xFFEAF3FE), // Normal
    Color(0xFFFFF9C4), // Action
    Color(0xFFFFE0B2), // Moderate
    Color(0xFFFFCDD2), // Major
    Color(0xFFE1BEE7), // Extreme
  ];
  static const Color _neutralTint = Color(0xFFEFF3F7);

  bool _loading = true;
  String? _error;
  ReachDetailsData? _details;

  /// Return periods converted from native CMS to the user's current unit,
  /// so the gauge can compare them against the (already-converted) flow.
  Map<int, double>? _returnPeriods;
  String _unit = 'ft³/s';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.source.isGeoglows) {
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

      // Return periods are stored in CMS; convert to the user's current unit
      // so they line up with the decoded flow value.
      final currentUnit = unitService.currentFlowUnit;
      final converted = details.returnPeriods?.map(
        (year, flow) => MapEntry(
          year,
          unitService.convertFlow(flow, 'CMS', currentUnit),
        ),
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
      setState(() {
        _details = ReachDetailsData(
          riverName: 'Stream ${widget.reachId}',
          formattedLocation: '',
          currentFlow: fc.currentMedian,
          returnPeriods: fc.returnPeriods,
        );
        // GEOGLOWS return periods are already in the user's unit (converted at
        // fetch/decode), so unlike NWM they need no CMS reconciliation here.
        _returnPeriods = fc.returnPeriods;
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

  int _categoryIndex() {
    final f = _details?.currentFlow;
    final rp = _returnPeriods;
    if (f == null || rp == null) return -1;
    final t = [rp[2], rp[5], rp[10], rp[25]];
    if (t.any((v) => v == null)) return -1;
    final tt = t.cast<double>();
    if (f < tt[0]) return 0;
    if (f < tt[1]) return 1;
    if (f < tt[2]) return 2;
    if (f < tt[3]) return 3;
    return 4;
  }

  String get _river =>
      _details?.riverName ?? (_loading ? '' : 'Stream ${widget.reachId}');
  String get _location => _details?.formattedLocation ?? '';

  @override
  Widget build(BuildContext context) {
    final i = _categoryIndex();
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
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      _buildHero(),
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

  Widget _buildHero() {
    if (_loading) {
      return const SizedBox(
        height: 210,
        child: Center(child: CupertinoActivityIndicator(radius: 14)),
      );
    }
    if (_error != null) {
      return SizedBox(
        height: 210,
        child: Center(
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
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: FlowGauge(
        currentFlow: _details?.currentFlow,
        returnPeriods: _returnPeriods,
        unit: _unit,
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
