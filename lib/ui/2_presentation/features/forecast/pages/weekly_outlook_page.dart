// lib/ui/2_presentation/features/forecast/pages/weekly_outlook_page.dart

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/features/forecast/weekly_outlook_row.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/4_infrastructure/forecast/weekly_outlook_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/features/forecast/load_view_state.dart';
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
  /// Built in initState, NOT as a `late final` field initializer.
  ///
  /// A `late final` runs on first touch, and the first touch was
  /// `_service.buildOutlook(...)` inside `_load()`'s try — so an unregistered
  /// GetIt type became "Could not load this week's outlook." with a Retry that
  /// could never succeed. That is the same defect the NWM forecast page fixes by
  /// keeping its resolution outside the try, and review round 11 caught that the
  /// fix had not been swept here. A missing registration must surface as a
  /// wiring bug, not be laundered into a data-load failure.
  late final WeeklyOutlookService _service;

  bool _loading = true;
  String? _error;
  List<OutlookRow> _rows = const [];
  int _favoriteCount = 0;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Held so the listener can be removed in dispose without a context lookup.
  FavoritesProvider? _favoritesProvider;

  /// Set once the outlook has been built, so a later notification from the
  /// provider does not rebuild it.
  bool _outlookBuilt = false;

  /// Resolved in initState with everything else (guard 8, no carve-outs):
  /// round 16 found these two lookups still inside caught bodies, where a
  /// missing registration degraded to a debug log line.
  late final IUserSettingsService _settingsService;

  /// Falls back to the empty state if favourites never arrive.
  Timer? _emptyStateFallback;

  /// How long to wait for favourites before believing there are none.
  static const _favouritesGracePeriod = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    // Constructed by DI (Phase 3): the page must not assemble the service's
    // dependency graph — that pulled the fetch contract into lib/ui.
    _service = GetIt.I<WeeklyOutlookService>();
    _settingsService = GetIt.I<IUserSettingsService>();
    final provider = context.read<FavoritesProvider>();
    _favoritesProvider = provider;
    provider.addListener(_onFavoritesChanged);
    _load();
  }

  @override
  void dispose() {
    _favoritesProvider?.removeListener(_onFavoritesChanged);
    _emptyStateFallback?.cancel();
    super.dispose();
  }

  /// Favourites finished loading after this page was already on screen.
  void _onFavoritesChanged() {
    // `!mounted` is defensive: dispose() removes this listener, so no test can
    // drive the unmounted case. Labelled per the ADR.
    if (_outlookBuilt || !mounted) return;
    if (_favoritesProvider?.favorites.isNotEmpty ?? false) _load();
  }

  /// Resolve each row's place label AFTER the page is on screen. Awaiting these
  /// inside the row build gated the whole page on geocoding.
  ///
  /// Coordinates come off the row itself. Matching back to a favourite by
  /// `reachId` alone ignored `source` and, on no match, fell back to an
  /// arbitrary favourite — which would have labelled one river with another
  /// river's city.
  Future<void> _fillPlaceLabels(List<OutlookRow> rows) {
    final pending = <Future<void>>[];
    for (final row in rows) {
      pending.add(
        Future(() => _service.placeLabelFor(row.latitude, row.longitude))
            // The catch covers the GEOCODE ONLY. Wrapping the `.then` too
            // swallowed everything the callback could throw, `setState() called
            // after dispose()` included — which made the `mounted` check
            // unfalsifiable. Review round 11 removed that check and no test
            // could see it.
            .catchError((Object e) {
          AppLogger.debug('WeeklyOutlookPage', 'Place label failed: $e');
          return null;
        }).then((label) {
          if (!mounted || label == null || label.isEmpty) return;
          // Matched by identity, not by index: an index captured before the
          // await binds to a position, and a later rebuild that reordered
          // `_rows` would attach one river's city to another.
          setState(() => _rows = [
                for (final r in _rows)
                  if (r.reachId == row.reachId && r.source == row.source)
                    r.withLocation(label)
                  else
                    r,
              ]);
        }),
      );
    }
    return Future.wait(pending);
  }

  void _retry() {
    setState(() {
      _error = null;
      _loading = true;
      // The no-forecast empty state is reached with _outlookBuilt = true (the
      // build "succeeded", it just had nothing). Without this reset, Retry from
      // that state early-returns at the top of _load() and spins forever.
      _outlookBuilt = false;
    });
    _load();
  }

  Future<void> _load() async {
    if (_outlookBuilt) return;
    OutlookResult? outcome;
    try {
      final favorites =
          (_favoritesProvider ?? context.read<FavoritesProvider>()).favorites;
      _favoriteCount = favorites.length;

      // A notification tap opens this page during launch, before
      // FavoritesProvider has loaded from Firestore. `context.read` does not
      // subscribe, so rendering the empty state here left "Add favorite rivers
      // to get your weekly outlook" on screen permanently for someone with
      // three favourites — and skipped _recordOutlookOpen, so the digest
      // back-off counter never reset either.
      //
      // Hold the spinner instead and let _onFavoritesChanged retry. The timer
      // is the floor: an account that genuinely has no favourites still gets
      // the empty state, just not instantly.
      if (favorites.isEmpty) {
        // Rescheduled, not `??=`. Once the first timer had fired, `??=` left a
        // non-null completed Timer, so a later _load() with no favourites —
        // reachable via Retry — scheduled nothing and returned with `_loading`
        // still true: a permanent spinner. Round 13 flagged it as a latent
        // hypothesis; cheaper to remove than to argue about reachability.
        _emptyStateFallback?.cancel();
        _emptyStateFallback = Timer(_favouritesGracePeriod, () {
          // Defensive, both halves: dispose() cancels this timer, and _load()
          // cancels it in the same synchronous block that sets _outlookBuilt —
          // so neither condition is reachable and no test can drive this line.
          // Labelled per the ADR rather than left reading as a guarded pair.
          if (!mounted || _outlookBuilt) return;
          setState(() {
            _rows = const [];
            _loading = false;
          });
        });
        return;
      }

      _outlookBuilt = true;
      _emptyStateFallback?.cancel();

      outcome = await _service.buildOutlook(favorites);
    } catch (e) {
      AppLogger.error('WeeklyOutlookPage', 'Failed to build outlook', e);
      // Defensive, and honestly labelled as such: `buildOutlook` catches per
      // row and returns an OutlookResult rather than throwing, so nothing an
      // upstream can do reaches this catch — only a programming error does.
      // No test can drive it, so removing this line kills nothing. The
      // reachable outage path is `isTotalFailure` below, which IS guarded.
      if (!mounted) return;
      setState(() {
        // Reset, or the guard at the top of _load() early-returns forever and
        // neither Retry nor a later favourites notification can ever rebuild —
        // the page would be permanently stuck with no way out.
        _outlookBuilt = false;
        _error = 'Could not load this week\'s outlook.';
        _loading = false;
      });
      return;
    }

    // Everything below is OUTSIDE the try, deliberately. Inside it, a
    // `setState() called after dispose()` was caught here and rendered as a
    // load failure — so deleting a `mounted` check changed nothing observable
    // and no test could guard it. Round 12 proved that on all four surfaces.
    if (!mounted) return;
    // Copied to a local: promotion does not survive into the closure.
    final result = outcome;

    // Opening the outlook is engagement whether or not the load succeeded —
    // the back-off counter resets on the OUTAGE path too. Round 16 caught this
    // running after the isTotalFailure return, so a user who opened the page
    // during an outage kept escalating toward digest suppression.
    _recordOutlookOpen();

    // Every favourite failed. buildOutlook catches per row, so this is the
    // shape a real outage takes — and it used to render "No forecast is
    // available for your rivers right now" with no Retry, a dead end reached by
    // the most ordinary failure there is.
    if (result.isTotalFailure) {
      setState(() {
        _outlookBuilt = false;
        _error = _failureMessage(result.failedNames);
        _loading = false;
      });
      return;
    }

    final rows = result.rows;
    setState(() {
      _rows = rows;
      // A load that succeeded must clear any earlier failure. Without this the
      // recovery path _onFavoritesChanged exists for rebuilt correctly and the
      // page still showed the outage card, with the loaded rows hidden behind
      // it — `loadViewStateFor` makes error win over content.
      _error = null;
      _loading = false;
    });
    // Persist the digest labels only AFTER the geocodes have resolved, reading
    // the rows as they are THEN. `withLocation` returns new objects into
    // `_rows`, so the list built above never acquires a label — round 15 caught
    // this persisting "Station 9962444" over a previously-correct "Provo, UT"
    // in the user doc the Friday push banner reads. The screen was right and
    // the write was wrong, which is the worst combination: nothing visible ever
    // disagrees.
    // No mounted check here: _persistDigestLabels checks once at its own top,
    // where the context read happens. A second one at this call site made both
    // undeletable-without-detection (round 16, the "Two redundant checks"
    // shape yet again).
    unawaited(_fillPlaceLabels(rows).then((_) => _persistDigestLabels(_rows)));
  }

  /// Name what failed, as the map sheet does — "Failed to load X" beats a
  /// generic apology, and with two or three favourites the names fit.
  static String _failureMessage(List<String> failed) {
    if (failed.isEmpty) return 'Could not load this week\'s outlook.';
    if (failed.length <= 2) return 'Could not load ${failed.join(' or ')}.';
    return 'Could not load ${failed.take(2).join(', ')} '
        'and ${failed.length - 2} more.';
  }

  /// Reset the digest back-off counter: opening the outlook is engagement.
  Future<void> _recordOutlookOpen() async {
    if (!mounted) return;
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;
    try {
      await _settingsService
          .updateUserSettings(userId, {'weeklyDigestsSinceOpen': 0});
    } catch (e) {
      AppLogger.debug('WeeklyOutlookPage', 'Outlook-open persist failed: $e');
    }
  }

  /// Persist each row's resolved label to the user doc, so the Friday digest
  /// banner (functions/src/weekly-digest.ts reads `favoriteLabels`) shows the
  /// same name/place the app shows. Called after the geocodes settle.
  ///
  /// Placeholder titles are SKIPPED, not written: a title that embeds the reach
  /// id means "no name and no label", and writing it would overwrite a correct
  /// label persisted on an earlier open. The write is read-modify-write so
  /// labels for rows that did not load this week survive (guarded: round 16
  /// proved the merge was deletable with the suite green).
  ///
  /// Known limits, accepted: the map is keyed by reachId alone because
  /// functions/src/weekly-digest.ts reads it that way — an NWM COMID and a
  /// GEOGLOWS LINKNO that collide numerically would share a label slot. And a
  /// reach that stored a river name in an earlier week but is unnamed now gets
  /// its geocoded place written over the name.
  Future<void> _persistDigestLabels(List<OutlookRow> rows) async {
    if (!mounted || rows.isEmpty) return;
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;
    try {
      final svc = _settingsService;
      final settings = await svc.getUserSettings(userId);
      final merged = Map<String, String>.from(settings?.favoriteLabels ?? {});
      var changed = false;
      for (final r in rows) {
        if (r.title.contains(r.reachId)) continue; // placeholder — never write
        if (merged[r.reachId] == r.title) continue;
        merged[r.reachId] = r.title;
        changed = true;
      }
      if (!changed) return;
      await svc.updateUserSettings(userId, {'favoriteLabels': merged});
    } catch (e) {
      AppLogger.debug('WeeklyOutlookPage', 'Digest-label persist failed: $e');
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
    // Precedence lives in loadViewStateFor, not in the order of these ifs.
    final view = loadViewStateFor(hasError: _error != null, isLoading: _loading);
    if (view == LoadViewState.error) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _centeredMessage(
            CupertinoIcons.exclamationmark_triangle,
            _error!,
            CupertinoColors.systemOrange,
          ),
          // A terminal state with no way out is a dead end — the same rule the
          // map sheet follows.
          CupertinoButton(
            onPressed: _retry,
            child: const Text('Retry'),
          ),
        ],
      );
    }
    if (view == LoadViewState.loading) {
      return const Center(child: CupertinoActivityIndicator(radius: 15));
    }
    if (_favoriteCount == 0) {
      return _centeredMessage(
        CupertinoIcons.heart,
        'Add favorite rivers to get your weekly outlook.',
        CupertinoColors.systemGrey,
      );
    }
    if (_rows.isEmpty) {
      // Reachable without any failure: every favourite answering 200 with no
      // usable series (a partial-publication window). Honest — but a state the
      // user may sit in for minutes, so it gets a Retry like every other
      // terminal state (guard 6). Round 15 flagged it as the one dead end left.
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _centeredMessage(
            CupertinoIcons.cloud,
            'No forecast is available for your rivers right now.',
            CupertinoColors.systemGrey,
          ),
          CupertinoButton(
            onPressed: _retry,
            child: const Text('Retry'),
          ),
        ],
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
