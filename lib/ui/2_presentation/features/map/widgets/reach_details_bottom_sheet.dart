// lib/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_flow_tiles.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_disclosure.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_metadata_payload.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/components/reach_action_buttons.dart';

/// Bottom sheet for a tapped stream, loaded progressively (ADR 0011 Phase 1).
///
/// Three narrow reads are issued together and each renders the moment it lands:
/// identity (name/coords), current flow, and return-period thresholds. The
/// flood category is derived once flow and thresholds have both arrived. They
/// fail independently, so a river can be named when no flow exists anywhere —
/// which is not hypothetical: on 2026-08-22 NOAA's `/streamflow` returned 504
/// for every series while `/reaches/{id}` kept answering.
///
/// The forecast page reads these same three keys, so "See forecast" is a cache
/// hit without this sheet warming anything — and the same flow number is
/// literally the same cache entry on both screens.
///
/// Layout: current flow and the days ahead sit side by side as equal tiles
/// ([ReachFlowTiles]) over the flood ladder, and reach metadata is collapsed
/// behind [ReachDetailsDisclosure]. This replaced a full-width flow card and a
/// three-line text banner that explained the map's colour in prose; the
/// decision of what the second tile says now lives in [peakOutlookFor].
class ReachDetailsBottomSheet extends StatefulWidget {
  final SelectedReach selectedReach;
  final VoidCallback? onViewForecast;

  /// Called with the flood-category color (resolved ARGB) once the flow has been
  /// classified, so the map can recolor its stream highlight to match.
  final void Function(int argb)? onFlowCategoryColor;

  const ReachDetailsBottomSheet({
    super.key,
    required this.selectedReach,
    this.onViewForecast,
    this.onFlowCategoryColor,
  });

  @override
  State<ReachDetailsBottomSheet> createState() =>
      _ReachDetailsBottomSheetState();
}

class _ReachDetailsBottomSheetState extends State<ReachDetailsBottomSheet> {

  // Progressive loading states
  bool _isLoadingFlow = false;
  bool _isLoadingClassification = false;
  bool _isCancelled = false;
  String? _errorMessage;

  // Essential data
  String? _riverName;
  String? _formattedLocation;
  double? _currentFlow;
  String? _flowCategory;
  double? _latitude;
  double? _longitude;

  /// Which parts failed, so the error card can name them instead of saying
  /// "Failed to load reach details" whatever went wrong.
  final Set<String> _failedProducts = {};

  @override
  void initState() {
    super.initState();
    _loadDataProgressively();
  }

  @override
  void dispose() {
    _isCancelled = true;
    super.dispose();
  }

  String _formatFlow(double flow) {
    final currentUnit = GetIt.I<IFlowUnitPreferenceService>().currentFlowUnit;

    // Format the value (no conversion needed)
    String formattedValue;
    if (flow >= 1000000) {
      formattedValue = '${(flow / 1000000).toStringAsFixed(1)}M';
    } else if (flow >= 1000) {
      formattedValue = '${(flow / 1000).toStringAsFixed(1)}K';
    } else if (flow >= 100) {
      formattedValue = flow.toStringAsFixed(0);
    } else {
      formattedValue = flow.toStringAsFixed(1);
    }

    return '$formattedValue $currentUnit';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [_buildHeader(), _buildContent(), _buildActions()],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    // No bottom divider. It made sense when the content below was flat rows
    // that could scroll under it; every block is now a bordered card, so the
    // rule was just a second hairline at the same weight sitting hard against
    // the tiles. The 16pt bottom padding is the separation.
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Stream order icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppConstants.getStreamOrderColor(
                widget.selectedReach.streamOrder,
              ).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              AppConstants.getStreamOrderIcon(widget.selectedReach.streamOrder),
              color: AppConstants.getStreamOrderColor(
                widget.selectedReach.streamOrder,
              ),
              size: 24,
              semanticLabel:
                  'Stream order ${widget.selectedReach.streamOrder}',
            ),
          ),
          const SizedBox(width: 12),

          // Title and subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Show loading state until we have the real river name
                if (_riverName != null)
                  Text(
                    _riverName!,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  )
                else if (_isLoadingFlow)
                  Row(
                    children: [
                      Container(
                        width: 120,
                        height: 18,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey4.resolveFrom(
                            context,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CupertinoActivityIndicator(radius: 6),
                      ),
                    ],
                  )
                else
                  Text(
                    widget
                        .selectedReach
                        .displayName, // Fallback if loading failed
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  widget.selectedReach.streamOrderDescription,
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),

          // Loading indicator or close button
          if (_isLoadingFlow)
            const CupertinoActivityIndicator(radius: 8)
          else
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(context),
              child: Icon(
                CupertinoIcons.xmark_circle_fill,
                color: CupertinoColors.systemGrey2.resolveFrom(context),
                size: 24,
                semanticLabel: 'Close',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Flow first, metadata second. The old order led with Reach ID and
          // coordinates, so the sheet answered "which reach is this" before
          // "is the river high" — which is the question that opened it.
          if (_errorMessage != null) _buildErrorCard(),
          if (_currentFlow != null) ...[
            ReachFlowTiles(
              flowText: _formatFlow(_currentFlow!),
              currentCategory: _flowCategory,
              peakCategoryIndex: widget.selectedReach.mapFloodCategoryIndex,
              horizonLabel: _forecastHorizon,
              isClassifying: _isLoadingClassification,
            ),
            const SizedBox(height: 11),
          ],
          if (_currentFlow == null && !_isLoadingFlow && _errorMessage == null)
            _buildNoFlowDataCard(),
          ReachDetailsDisclosure(rows: _detailRows),
        ],
      ),
    );
  }

  List<DetailRow> get _detailRows {
    final location = (_formattedLocation?.isNotEmpty == true)
        ? _formattedLocation!
        : (widget.selectedReach.hasLocation
            ? widget.selectedReach.formattedLocation
            : null);
    return [
      DetailRow('Reach ID', widget.selectedReach.reachId),
      DetailRow('Stream order', '${widget.selectedReach.streamOrder}'),
      DetailRow('Coordinates', widget.selectedReach.coordinatesString),
      DetailRow('Forecast window', _forecastHorizon),
      if (location != null && location.isNotEmpty)
        DetailRow('Location', location),
      DetailRow(
        'Source',
        widget.selectedReach.source.isGeoglows ? 'GEOGLOWS' : 'NOAA NWM',
      ),
    ];
  }

  // Return-period thresholds are deliberately NOT shown here — a product
  // decision, not a technical one. The unit hazard that used to justify this is
  // gone: ReturnPeriodPayload.decode now converts from native CMS to the
  // reader's unit, so they could be rendered through _formatFlow safely.

  Widget _buildErrorCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemRed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemRed.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                CupertinoIcons.exclamationmark_triangle,
                color: CupertinoColors.systemRed,
                size: 16,
              ),
              SizedBox(width: 8),
              Text(
                'Loading Error',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.systemRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Named, not generic: which part failed changes what the user can do
          // about it, and a sheet that always says the same thing whatever
          // broke teaches people to ignore it.
          Text(
            _errorMessage!,
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _retryLoad,
              child: const Text('Retry', style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  /// Re-run the load. The reads are cheap and independent, so retrying all
  /// three is simpler than tracking which to repeat, and a user who taps Retry
  /// wants the sheet to work — not a partial repair.
  void _retryLoad() {
    setState(() {
      _errorMessage = null;
      _isLoadingFlow = true;
      _isLoadingClassification = true;
    });
    _loadDataProgressively();
  }

  Widget _buildNoFlowDataCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemOrange.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                CupertinoIcons.info_circle,
                color: CupertinoColors.systemOrange,
                size: 16,
              ),
              SizedBox(width: 8),
              Text(
                'Flow Data',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.systemOrange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Current flow data is not available for this reach.',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return ReachActionButtons(
      selectedReach: widget.selectedReach,
      riverName: _riverName,
      formattedLocation: _formattedLocation,
      formattedFlow: _currentFlow != null ? _formatFlow(_currentFlow!) : null,
      flowCategory: _flowCategory,
      latitude: _latitude,
      longitude: _longitude,
      currentFlow: _currentFlow,
    );
  }

  /// Load all reach details via the use case (returns ServiceResult).
  Future<void> _loadDataProgressively() async {
    setState(() {
      _isLoadingFlow = true;
      _isLoadingClassification = true;
      _errorMessage = null;
    });

    AppLogger.debug(
      'ReachDetailsSheet',
      'Loading details for: ${widget.selectedReach.reachId}',
    );

    // GEOGLOWS reaches are not on the NOAA/NWM API — load their current flow
    // from the GEOGLOWS proxy instead of hitting NOAA (which 500s on a LINKNO).
    if (widget.selectedReach.source.isGeoglows) {
      await _loadGeoglowsDetails();
      return;
    }

    await _loadNwmDetailsProgressively();
  }

  /// Three independent reads, issued together, each rendering the moment it
  /// lands (ADR 0011 Phase 1).
  ///
  /// This replaced a single `reachSummary` read, which looked cheap at the call
  /// site and was not: building it fetches reach info, current flow, return
  /// periods **and** a medium-range forecast *serially*, the 156 KB
  /// forecast series accounting for most of it. The sheet never
  /// rendered that series; the forecast peak it shows comes from the map tile
  /// (`selectedReach.mapFloodCategoryIndex`), not from a fetch. So it is not
  /// deferred here, it is simply not requested.
  ///
  /// The three products fail independently, which matters: during the
  /// 2026-08-22 outage NOAA's `/streamflow` returned 504 for every series while
  /// `/reaches/{id}` kept answering, so the sheet can still name the river when
  /// no flow exists anywhere.
  Future<void> _loadNwmDetailsProgressively() async {
    final repo = GetIt.I<IRiverDataRepository>();
    final reachId = widget.selectedReach.reachId;
    RiverDataKey keyFor(ForecastProduct p) =>
        RiverDataKey(source: ForecastSource.nwm, reachId: reachId, product: p);

    final unitService = GetIt.I<IFlowUnitPreferenceService>();
    final started = DateTime.now();
    var anySucceeded = false;
    var settled = 0;
    _failedProducts.clear();

    // Phase 0 guard 3's device timing, folded into this phase per the ADR.
    void logTiming(String what, bool ok) => AppLogger.metric(
          'ReachDetailsSheet',
          'timing reach=$reachId product=$what ok=$ok '
              'elapsedMs=${DateTime.now().difference(started).inMilliseconds}',
        );

    // A read has finished, whatever the outcome. Only once all three have
    // settled with nothing to show is this actually a failure — a named river
    // with no flow is a usable sheet.
    void markSettled() {
      settled++;
      if (settled < 3 || _isCancelled || !mounted) return;
      setState(() {
        _isLoadingFlow = false;
        _isLoadingClassification = false;
        if (!anySucceeded) {
          _errorMessage = _failedProducts.isEmpty
              ? 'Failed to load reach details'
              : 'Failed to load ${_failedProducts.join(', ')}';
        }
      });
    }

    // Recomputed whenever either input lands, so whichever arrives second
    // completes the category. Derived via FlowClassification — the single
    // canonical classifier (ADR 0002); nothing re-implements it here.
    Map<int, double>? thresholds;
    void recomputeCategory() {
      final flow = _currentFlow;
      if (flow == null || thresholds == null) return;
      setState(() => _flowCategory =
          FlowClassification.category(flow, thresholds));
      _notifyCategoryColor();
    }

    // 1. Identity — measured the cheapest of the three (~0.5 KB), so it
    //    usually lands first. Note "usually": all three are issued together
    //    with no head start, so this is an expectation, not a guarantee. During the
    // 2026-08-22 outage this kept answering while every flow series 504'd.
    unawaited(repo.read(keyFor(ForecastProduct.reachMetadata)).then((entry) {
      logTiming('reachMetadata', entry != null);
      if (_isCancelled || !mounted || entry == null) return;
      final m = ReachMetadataPayload.decode(entry);
      anySucceeded = true;
      setState(() {
        _riverName = m.riverName;
        _formattedLocation = m.formattedLocation;
        _latitude = m.latitude;
        _longitude = m.longitude;
      });
      // The place name is decoration, so it is resolved after the title is
      // already on screen rather than in front of it (ADR 0011, geocoding off the critical path).
      if (m.formattedLocation == null || m.formattedLocation!.isEmpty) {
        _fillPlaceLabel(m.latitude, m.longitude);
      }
    }).catchError((Object e) {
      logTiming('reachMetadata', false);
      _failedProducts.add('name');
      AppLogger.warning('ReachDetailsSheet', 'Reach metadata failed: $e');
    }).whenComplete(markSettled));

    // 2. Current flow — rendered the moment it lands. It is deliberately NOT
    // joined with the thresholds read: gating the headline number on a separate
    // call means a slow threshold fetch hides a flow value that is ready.
    unawaited(
        repo.read(keyFor(ForecastProduct.analysisAssimilation)).then((entry) {
      logTiming('analysisAssimilation', entry != null);
      if (_isCancelled || !mounted || entry == null) return;
      final flow = CurrentFlowPayload.decode(
        entry,
        GetIt.I<IForecastService>(),
        unitService,
      );
      if (flow == null) {
        // Upstream answered but carried no usable value. That is a failure of
        // this product, not a success — without this it is never named in the
        // error card and never counted.
        _failedProducts.add('current flow');
        return;
      }
      anySucceeded = true;
      setState(() {
        _currentFlow = flow;
        _isLoadingFlow = false;
      });
      recomputeCategory();
    }).catchError((Object e) {
      logTiming('analysisAssimilation', false);
      _failedProducts.add('current flow');
      AppLogger.warning('ReachDetailsSheet', 'Current flow failed: $e');
    }).whenComplete(markSettled));

    // 3. Thresholds — only the flood category depends on these.
    unawaited(repo.read(keyFor(ForecastProduct.returnPeriods)).then((entry) {
      logTiming('returnPeriods', entry != null);
      if (_isCancelled || !mounted || entry == null) return;
      thresholds = ReturnPeriodPayload.decode(entry, unitService);
      if (thresholds == null) return;
      anySucceeded = true;
      setState(() => _isLoadingClassification = false);
      recomputeCategory();
    }).catchError((Object e) {
      logTiming('returnPeriods', false);
      _failedProducts.add('flood risk');
      AppLogger.warning('ReachDetailsSheet', 'Return periods failed: $e');
    }).whenComplete(markSettled));

  }

  /// Resolve the place label after the sheet is already usable. Best-effort:
  /// `GeocodingService` catches internally and yields null rather than throwing.
  void _fillPlaceLabel(double? lat, double? lon) {
    unawaited(GetIt.I<IGeocodingService>().placeLabel(lat, lon).then((label) {
      if (_isCancelled || !mounted || label == null || label.isEmpty) return;
      setState(() => _formattedLocation = label);
    }));
  }



  /// GEOGLOWS reach preview: current flow from the proxy (median of the latest
  /// forecast). GEOGLOWS streams are unnamed, so displayName falls back to
  /// `Stream <id>`. Flood classification for GEOGLOWS is not wired yet.
  Future<void> _loadGeoglowsDetails() async {
    try {
      final entry = await GetIt.I<IRiverDataRepository>().read(
        RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: widget.selectedReach.reachId,
          product: ForecastProduct.geoglowsForecast,
        ),
      );
      if (_isCancelled || !mounted) return;
      if (entry == null) {
        throw Exception('No GEOGLOWS forecast available for this river.');
      }
      final forecast = GeoglowsForecastPayload.decode(
        entry,
        GetIt.I<IFlowUnitPreferenceService>(),
      );
      setState(() {
        _riverName = null;
        _formattedLocation = '';
        _currentFlow = forecast.currentMedian;
        // GEOGLOWS return periods (Gumbel) come in the model's unit, same as
        // currentMedian — classify through the one app-wide ladder instead of
        // hardcoding 'Normal'.
        _flowCategory = FlowClassification.category(
          forecast.currentMedian,
          forecast.returnPeriods,
        );
        _latitude = widget.selectedReach.latitude;
        _longitude = widget.selectedReach.longitude;
        _isLoadingFlow = false;
        _isLoadingClassification = false;
      });
      _notifyCategoryColor();
      AppLogger.info(
        'ReachDetailsSheet',
        'GEOGLOWS details loaded, flow: $_currentFlow',
      );
    } catch (e) {
      if (_isCancelled || !mounted) return;
      AppLogger.error('ReachDetailsSheet', 'Error loading GEOGLOWS details', e);
      setState(() {
        _errorMessage = 'Could not load GEOGLOWS forecast for this river.';
        _isLoadingFlow = false;
        _isLoadingClassification = false;
      });
    }
  }

  /// Hand the resolved flood-category color to the map so it can recolor the
  /// tapped-stream highlight. No-op until the flow has actually been classified.
  void _notifyCategoryColor() {
    final cb = widget.onFlowCategoryColor;
    if (cb == null || _flowCategory == null || !mounted) return;
    final base = AppConstants.getFlowCategoryColor(_flowCategory);
    final resolved = CupertinoDynamicColor.maybeResolve(base, context) ?? base;
    cb(resolved.toARGB32());
  }

  /// How far ahead the flood colour for this reach looks.
  ///
  /// One tileset, three horizons — GEOGLOWS publishes 15 days outside the US,
  /// NOAA 5 days across CONUS and Alaska, and only 48 hours for Hawaii and
  /// Puerto Rico. The legend stays deliberately vague ("in the days ahead")
  /// because no single number is true everywhere; the exact window belongs
  /// here, where someone has asked about one specific river (ADR 0005).
  String get _forecastHorizon {
    if (widget.selectedReach.source.isGeoglows) return 'Next 15 days';

    // NOAA's Hawaii and Puerto Rico products are 48-hour only; there is no
    // 5-day variant for them. Both use NHDPlus COMIDs in the 800M-921M band,
    // which is how a US reach is identified as an island one.
    final id = int.tryParse(widget.selectedReach.reachId);
    if (id != null && id >= 800000000 && id <= 921999999) {
      return 'Next 48 hours';
    }
    return 'Next 5 days';
  }

}
