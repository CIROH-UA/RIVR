// test/ui/2_presentation/features/forecast/interactive_chart_test.dart
//
// ADR 0011 Phase 3, review round 1, B1 — a live defect: the chart extracted
// its series once in initState and re-extracted only on prop/unit changes.
// Phase 3's provider publishes the overview immediately and merges medium and
// long range as they arrive, so a chart opened during that window (tapping
// the outlook sparkline while its spinner still shows) locked onto an empty
// series and displayed "No chart data available" forever — the data arriving
// seconds later rebuilt the Consumer with identical props, which the old
// didUpdateWidget ignored.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/interactive_chart.dart';

class _Unit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  String normalizeUnit(String unit) => unit.toUpperCase().contains('CMS')
      ? 'CMS'
      : 'CFS';
  @override
  double convertFlow(double v, String from, String to) => v;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Medium range is gated behind [releaseMedium] — the window the defect lives
/// in: overview lands, the chart mounts, medium range is still in flight.
class _GatedRepo implements IRiverDataRepository {
  bool mediumReleased = false;
  final List<void Function()> _pendingMedium = [];

  void releaseMedium() {
    mediumReleased = true;
    for (final complete in _pendingMedium) {
      complete();
    }
    _pendingMedium.clear();
  }

  RiverDataEntry _entry(ForecastProduct p, Map<String, dynamic> payload) {
    final now = DateTime.now().toUtc();
    return RiverDataEntry(
      key: RiverDataKey(
          source: ForecastSource.nwm, reachId: '123', product: p),
      window: FreshnessWindow(
          fetchedAt: now, validUntil: now.add(const Duration(hours: 1))),
      unit: 'CFS',
      payload: payload,
    );
  }

  Map<String, dynamic> get _reach => {
        'reachId': '123',
        'name': 'Test River',
        'latitude': 40.0,
        'longitude': -111.0,
        'streamflow': ['short_range'],
      };

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    switch (key.product) {
      case ForecastProduct.shortRange:
        return _entry(key.product, {
          'reach': _reach,
          'shortRange': {
            'series': {
              'referenceTime': '2026-08-23T12:00:00',
              'units': 'ft³/s',
              'data': [
                {
                  'validTime': DateTime.now()
                      .toUtc()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                  'flow': 640.0,
                },
              ],
            },
          },
        });
      case ForecastProduct.mediumRange:
        if (!mediumReleased) {
          final gate = Completer<void>();
          _pendingMedium.add(gate.complete);
          await gate.future;
        }
        return _entry(key.product, {
          'reach': _reach,
          'mediumRange': {
            'mean': {
              'referenceTime': '2026-08-23T06:00:00',
              'units': 'ft³/s',
              'data': [
                for (var d = 1; d <= 10; d++)
                  {
                    'validTime': DateTime.now()
                        .toUtc()
                        .add(Duration(days: d))
                        .toIso8601String(),
                    'flow': 700.0 + d,
                  },
              ],
            },
          },
        });
      default:
        return null;
    }
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) => read(key);
  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) =>
      ValueNotifier(null);
  @override
  Future<void> ingest(RiverDataEntry e) async {}
}

void main() {
  setUp(() =>
      GetIt.I.registerSingleton<IFlowUnitPreferenceService>(_Unit()));
  tearDown(() => GetIt.I.reset());

  testWidgets(
      'a chart opened while medium range is in flight fills when it lands',
      (t) async {
    final repo = _GatedRepo();
    final provider = ReachDataProvider(repository: repo, unitService: _Unit());

    await provider.loadAllData('123'); // overview lands; medium is gated

    await t.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<ReachDataProvider>.value(
        value: provider,
        child: Consumer<ReachDataProvider>(
          builder: (_, p, __) => Scaffold(
            body: InteractiveChart(
              reachId: '123',
              forecastType: 'medium_range',
              showReturnPeriods: false,
              showTooltips: false,
              reachProvider: p,
            ),
          ),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('No chart data'), findsOneWidget,
        reason: 'precondition: the chart mounted inside the in-flight window');

    // Medium range lands — the provider merges and notifies.
    repo.releaseMedium();
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('No chart data'), findsNothing,
        reason: 'the data arrived; a chart that never re-extracts shows '
            '"No chart data available" forever — review round 1 reproduced '
            'exactly this by tapping the outlook mid-load');
  });
}
