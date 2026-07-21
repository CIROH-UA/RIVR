// lib/ui/2_presentation/features/forecast/pages/weekly_outlook_page.dart

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/features/forecast/weekly_outlook_row.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/4_infrastructure/forecast/weekly_outlook_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/utils/flow_format.dart';
import 'package:rivr/utils/forecast_trend.dart';

/// The Weekly Outlook — a once-a-week, at-a-glance digest of how each favorite
/// river is forecast to behave over the coming week (the "Digest List" design).
/// Rows are ranked most-newsworthy first.
class WeeklyOutlookPage extends StatefulWidget {
  const WeeklyOutlookPage({super.key});

  @override
  State<WeeklyOutlookPage> createState() => _WeeklyOutlookPageState();
}

class _WeeklyOutlookPageState extends State<WeeklyOutlookPage> {
  late final WeeklyOutlookService _service = WeeklyOutlookService(
    forecastService: GetIt.I<IForecastService>(),
    riverData: GetIt.I<IRiverDataRepository>(),
    unitService: GetIt.I<IFlowUnitPreferenceService>(),
  );

  bool _loading = true;
  String? _error;
  List<OutlookRow> _rows = const [];
  int _favoriteCount = 0;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final favorites = context.read<FavoritesProvider>().favorites;
      _favoriteCount = favorites.length;
      if (favorites.isEmpty) {
        setState(() {
          _rows = const [];
          _loading = false;
        });
        return;
      }
      final rows = await _service.buildOutlook(favorites);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
      // Persist the resolved labels so the weekly-digest Cloud Function can put
      // real names/places on the push banner (it can't geocode). Fire-and-forget.
      _persistLabels(rows);
    } catch (e) {
      AppLogger.error('WeeklyOutlookPage', 'Failed to build outlook', e);
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this week\'s outlook.';
        _loading = false;
      });
    }
  }

  /// Write each loaded favorite's resolved label to the user doc so the Friday
  /// digest banner reads the same name/place the app shows. Merges with existing
  /// labels (read-modify-write) so favorites that failed to load keep theirs.
  Future<void> _persistLabels(List<OutlookRow> rows) async {
    if (rows.isEmpty || !mounted) return;
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;
    try {
      final svc = GetIt.I<IUserSettingsService>();
      final settings = await svc.getUserSettings(userId);
      final merged = Map<String, String>.from(settings?.favoriteLabels ?? {});
      for (final r in rows) {
        merged[r.reachId] = r.title;
      }
      await svc.updateUserSettings(userId, {'favoriteLabels': merged});
    } catch (e) {
      AppLogger.debug('WeeklyOutlookPage', 'Label persist failed: $e');
    }
  }

  String get _dateRange {
    final now = DateTime.now();
    final end = now.add(const Duration(days: 6));
    final a = '${_months[now.month - 1]} ${now.day}';
    final b = now.month == end.month ? '${end.day}' : '${_months[end.month - 1]} ${end.day}';
    return '$a – $b';
  }

  String _dayLabel(DateTime? t) {
    if (t == null) return '—';
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return 'today';
    }
    return _weekdays[t.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('This Week'),
        previousPageTitle: 'Rivers',
      ),
      child: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator(radius: 15));
    }
    if (_error != null) {
      return _centeredMessage(
        CupertinoIcons.exclamationmark_triangle,
        _error!,
        CupertinoColors.systemOrange,
      );
    }
    if (_favoriteCount == 0) {
      return _centeredMessage(
        CupertinoIcons.heart,
        'Add favorite rivers to get your weekly outlook.',
        CupertinoColors.systemGrey,
      );
    }
    if (_rows.isEmpty) {
      return _centeredMessage(
        CupertinoIcons.cloud,
        'No forecast is available for your rivers right now.',
        CupertinoColors.systemGrey,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _header(),
        const SizedBox(height: 14),
        _summary(),
        const SizedBox(height: 14),
        for (final row in _rows) ...[
          _row(row),
          const SizedBox(height: 11),
        ],
      ],
    );
  }

  Widget _header() {
    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('This Week',
            style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: label)),
        const SizedBox(height: 2),
        Text('$_dateRange · ${_rows.length} river${_rows.length == 1 ? '' : 's'}',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500, color: sub)),
      ],
    );
  }

  Widget _summary() {
    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final rising = _rows.where((r) => r.trend.isRising).length;
    // The most newsworthy row leads (rows are already ranked).
    final top = _rows.first;
    final topElevated = top.categoryIndex >= 1;
    final accent = _catColor(top.category);

    final headline = topElevated
        ? '${top.displayName} reaches ${top.category} ${_dayLabel(top.peakTime)}.'
        : rising > 0
            ? 'A calm week — $rising rising, ${_rows.length - rising} steady or receding.'
            : 'A calm, steady week across your rivers.';

    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline,
              style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  letterSpacing: -0.1,
                  color: label)),
          const SizedBox(height: 7),
          Row(
            children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text('$rising rising · ${_rows.length - rising} steady/receding',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: sub)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(OutlookRow r) {
    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final color = _catColor(r.category);

    // Title = OutlookRow.title (name for named reaches, place for unnamed). The
    // subtitle carries the id so it never clips; named reaches show the place.
    final srcId = '${r.source.isGeoglows ? 'GEOGLOWS' : 'NWM'} · ${r.reachId}';
    final hasName = !r.displayName.contains(r.reachId);
    final title = r.title;
    final String subtitle;
    if (hasName) {
      subtitle = r.location ?? srcId;
    } else {
      subtitle = r.location != null
          ? srcId
          : (r.source.isGeoglows ? 'GEOGLOWS' : 'NWM');
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => AppRouter.pushForecast(context, reachId: r.reachId, source: r.source),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: CupertinoColors.separator.resolveFrom(context), width: 0.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: label)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: sub)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _trendChip(r.trend, color),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          r.peakFlow == null
                              ? 'no forecast'
                              : 'peak ${FlowFormat.grouped(r.peakFlow!)} ${r.unit} ${_dayLabel(r.peakTime)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w500, color: sub),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 88,
                  height: 40,
                  child: CustomPaint(painter: _SparklinePainter(r.sparkline, color)),
                ),
                const SizedBox(height: 6),
                _catPill(r.category, color),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _trendChip(FlowTrend trend, Color catColor) {
    final (arrow, text, color) = switch (trend) {
      FlowTrend.rising => ('↗', 'Rising', catColor),
      FlowTrend.falling => ('↘', 'Falling', CupertinoColors.systemBlue.resolveFrom(context)),
      FlowTrend.steady => ('→', 'Steady', CupertinoColors.systemGrey.resolveFrom(context)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text('$arrow $text',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _catPill(String category, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(category.toUpperCase(),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: color)),
    );
  }

  Widget _centeredMessage(IconData icon, String text, Color color) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: color),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context))),
          ],
        ),
      ),
    );
  }

  Color _catColor(String category) => CupertinoDynamicColor.resolve(
        AppConstants.getFlowCategoryColor(category),
        context,
      );
}

/// Minimal area+line sparkline for a favorite's upcoming flow series.
class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  const _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    const pad = 3.0;
    var min = data.first, max = data.first;
    for (final v in data) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    final span = (max - min).abs() < 1e-9 ? 1.0 : (max - min);
    double x(int i) => pad + i * (size.width - 2 * pad) / (data.length - 1);
    double y(double v) => size.height - pad - (v - min) / span * (size.height - 2 * pad);

    final line = Path()..moveTo(x(0), y(data.first));
    for (var i = 1; i < data.length; i++) {
      line.lineTo(x(i), y(data[i]));
    }

    final area = Path.from(line)
      ..lineTo(x(data.length - 1), size.height - pad)
      ..lineTo(x(0), size.height - pad)
      ..close();

    canvas.drawPath(
      area,
      Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.drawCircle(
      Offset(x(data.length - 1), y(data.last)),
      2.6,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.data != data || old.color != color;
}
