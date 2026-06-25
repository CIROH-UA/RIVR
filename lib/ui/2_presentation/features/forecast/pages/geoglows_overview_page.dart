// lib/ui/2_presentation/features/forecast/pages/geoglows_overview_page.dart

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/ui/1_state/features/forecast/geoglows_forecast_provider.dart';

/// Minimal forecast page for GEOGLOWS (global, non-US) rivers.
///
/// First-pass MVP: proves source-routing end to end by showing a real GEOGLOWS
/// forecast (current median + a 15-day daily summary) where the NWM path would
/// have failed. The richer ensemble-fan ("Riverlight" v3) UI builds on this.
class GeoglowsOverviewPage extends StatelessWidget {
  final String reachId;

  const GeoglowsOverviewPage({super.key, required this.reachId});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<GeoglowsForecastProvider>(
      create: (_) =>
          GeoglowsForecastProvider(GetIt.instance<IGeoglowsApiService>())
            ..load(reachId),
      child: CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(
          middle: Text('Forecast'),
        ),
        child: SafeArea(
          child: Consumer<GeoglowsForecastProvider>(
            builder: (context, provider, _) {
              if (provider.isLoading) {
                return const Center(child: CupertinoActivityIndicator());
              }
              if (provider.error != null || !provider.hasData) {
                return _ErrorState(
                  reachId: reachId,
                  message: provider.error ?? 'No forecast available.',
                  onRetry: () => provider.load(reachId),
                );
              }
              return _ForecastBody(forecast: provider.forecast!);
            },
          ),
        ),
      ),
    );
  }
}

class _ForecastBody extends StatelessWidget {
  final GeoglowsForecast forecast;
  const _ForecastBody({required this.forecast});

  @override
  Widget build(BuildContext context) {
    final daily = _toDaily(forecast.points);
    final current = forecast.currentMedian;
    final minFlow = forecast.points.map((p) => p.median).reduce(_min);
    final maxFlow = forecast.points.map((p) => p.median).reduce(_max);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text(
          'Stream ${forecast.riverId}',
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          'Global river forecast',
          style: TextStyle(
            fontSize: 14,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 22),

        // Current flow hero
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Flowing now',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    current == null ? '--' : _fmt(current),
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    forecast.unit,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color:
                          CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '15-day range  ${_fmt(minFlow)} – ${_fmt(maxFlow)} ${forecast.unit}',
                style: TextStyle(
                  fontSize: 13.5,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        Text(
          'NEXT 15 DAYS · DAILY MEDIAN',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: CupertinoColors.tertiaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 4),
        _Card(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < daily.length; i++)
                _DayRow(
                  day: daily[i],
                  unit: forecast.unit,
                  isLast: i == daily.length - 1,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'GEOGLOWS · 51-member ensemble · refreshed daily',
            style: TextStyle(
              fontSize: 11,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ),
        ),
      ],
    );
  }

  /// Aggregate the 3-hourly median series into per-day averages (local date).
  static List<_DailyMedian> _toDaily(List<GeoglowsForecastPoint> points) {
    final byDay = <DateTime, List<double>>{};
    for (final p in points) {
      final local = p.validTime.toLocal();
      final key = DateTime(local.year, local.month, local.day);
      byDay.putIfAbsent(key, () => []).add(p.median);
    }
    final days = byDay.keys.toList()..sort();
    return [
      for (final d in days)
        _DailyMedian(
          date: d,
          median: byDay[d]!.reduce((a, b) => a + b) / byDay[d]!.length,
        ),
    ];
  }

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;
}

class _DailyMedian {
  final DateTime date;
  final double median;
  const _DailyMedian({required this.date, required this.median});
}

class _DayRow extends StatelessWidget {
  final _DailyMedian day;
  final String unit;
  final bool isLast;
  const _DayRow({required this.day, required this.unit, required this.isLast});

  static const _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: CupertinoColors.separator.resolveFrom(context),
                  width: 0.5,
                ),
              ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              _weekdays[day.date.weekday - 1],
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '${_months[day.date.month - 1]} ${day.date.day}',
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const Spacer(),
          Text(
            '${_fmt(day.median)} $unit',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String reachId;
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({
    required this.reachId,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 40,
              color: CupertinoColors.systemOrange,
            ),
            const SizedBox(height: 12),
            Text(
              'Could not load the forecast for stream $reachId.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(18)});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: child,
    );
  }
}

/// Format a flow value: no decimals for large numbers, one for small.
String _fmt(double v) {
  if (v >= 100) return v.round().toString();
  if (v >= 10) return v.toStringAsFixed(0);
  return v.toStringAsFixed(1);
}
