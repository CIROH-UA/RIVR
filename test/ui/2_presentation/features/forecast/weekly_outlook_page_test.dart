// test/ui/2_presentation/features/forecast/weekly_outlook_page_test.dart
//
// The Weekly Outlook page had NO widget test. `weekly_outlook_race_test.dart`
// hand-reimplements the state machine and says so in its own header — that is a
// model of the code, not a guard on it, and review counted it as such.
//
// Round 11 rejected the first attempt at this file for a worse reason than
// absence: it drove the error state by leaving `IGeocodingService`
// unregistered, which only *worked* because `_service` was a `late final`
// resolved inside `_load()`'s try. That is a defect the same phase fixes on the
// NWM forecast page — so three of four tests were pinning a bug as expected
// behaviour, and hoisting the resolution (the fix) turned them red. The
// resolution now happens in initState, and every failure below is one the
// upstream can actually produce.
//
// What these tests kill: the failure never reaching the screen, the failure
// having no Retry, the failure not naming what broke, `_outlookBuilt` staying
// set so nothing can ever retry, the place label never arriving, and a setState
// landing after dispose.
//
// What they do NOT kill, stated plainly: the *precedence* between `_error` and
// `_loading`. Reversing `loadViewStateFor` leaves this file green, because the
// catch clears `_loading` in the same setState that sets `_error`, so the
// both-set input never occurs through this widget. That is why the rule was
// extracted into a pure function; `load_view_state_test.dart` pins it with both
// inputs set.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/features/auth/auth_user.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/weekly_outlook_page.dart';

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double v, String from, String to) {
    if (from == to) return v;
    if (from == 'CMS' && to == 'CFS') return v * 35.3147;
    return v;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// The real upstream failure: NOAA is down, so every favourite throws. This is
/// the shape the outage takes, and — since `buildOutlook` catches per row — the
/// only failure shape it can produce.
class _Forecast implements IForecastService {
  _Forecast({this.fail = false, this.delay});

  /// Mutable so a test can heal the upstream mid-run and prove the page
  /// recovers — the recovery path is the one the outage path leads into.
  bool fail;

  /// A 200 with no usable series — the partial-publication shape, distinct
  /// from a thrown failure.
  bool emptySeries = false;

  /// An unnamed reach: the NWM metadata carries no river name, so the row's
  /// title falls back to the favourite's placeholder ("Station `id`") until the
  /// geocoded place replaces it.
  bool unnamedReach = false;
  final Duration? delay;
  int calls = 0;

  @override
  Future<ForecastResponse> loadCompleteReachData(String reachId) async {
    calls++;
    if (delay != null) await Future<void>.delayed(delay!);
    if (fail) throw Exception('simulated upstream failure');
    final now = DateTime.now().toUtc();
    return ForecastResponse(
      reach: ReachData(
        reachId: reachId,
        riverName: unnamedReach ? '' : 'White River',
        latitude: 40.2,
        longitude: -111.6,
        availableForecasts: const ['medium_range'],
        returnPeriods: const {2: 30.0, 5: 60.0, 10: 90.0, 25: 150.0},
        cachedAt: now,
      ),
      mediumRange: {
        'mean': ForecastSeries(
          units: 'ft³/s',
          data: emptySeries
              ? const []
              : [
                  for (var i = 1; i <= 8; i++)
                    ForecastPoint(
                        validTime: now.add(Duration(days: i)), flow: 640),
                ],
        ),
      },
      longRange: const {},
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Records every write, so the persisted digest label — which the Friday push
/// banner reads server-side — is assertable. Round 15 found the label write
/// regressed with zero coverage: every fixture's auth user was null, so
/// `_persistDigestLabels` early-returned in all 13 tests.
class _RecordingSettings implements IUserSettingsService {
  final List<Map<String, dynamic>> updates = [];

  /// Pre-seeded stored labels, as a user who opened the outlook on an earlier,
  /// geocode-successful day would have. The write is read-modify-write, so a
  /// bad merge shows up as this map being overwritten.
  Map<String, String> stored = {};

  @override
  Future<UserSettings?> getUserSettings(String userId) async => UserSettings(
        userId: userId,
        email: 'u@example.com',
        firstName: 'U',
        lastName: 'Ser',
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twentyFourHour,
        enableNotifications: true,
        favoriteReachIds: const [],
        favoriteLabels: Map<String, String>.from(stored),
        lastLoginDate: DateTime.utc(2026, 8, 23),
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026, 8, 23),
      );

  @override
  Future<void> updateUserSettings(
      String userId, Map<String, dynamic> u) async {
    updates.add(u);
    final labels = u['favoriteLabels'];
    if (labels is Map<String, String>) {
      stored = Map<String, String>.from(labels);
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubRepo implements IRiverDataRepository {
  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeGeocoder implements IGeocodingService {
  _FakeGeocoder({this.delay, this.fails = false});

  final Duration? delay;
  final bool fails;

  @override
  Future<Map<String, String?>> reverseGeocode(double lat, double lon) async =>
      {'city': 'Provo', 'state': 'UT', 'country': 'US'};

  /// Label derived from the coordinate, so a two-river test can tell whose
  /// label landed on whose row.
  @override
  Future<String?> placeLabel(double? lat, double? lon) async {
    if (delay != null) await Future<void>.delayed(delay!);
    if (fails || lat == null) return null;
    return lat > 41 ? 'Boise, ID' : 'Provo, UT';
  }
}

/// Counts how many times the page asked for the favourites list. `_load()`
/// reads it on every attempt, so this is the attempt counter — and it is read
/// *after* the `_outlookBuilt` guard, which is what lets it see the guard stuck.
class _FakeFavorites extends ChangeNotifier implements FavoritesProvider {
  _FakeFavorites({this.named = true, this.empty = false, this.two = false});

  /// Two rivers with distinct coordinates, for the label-identity test.
  final bool two;

  /// A named river renders its name; an unnamed one falls back to its geocoded
  /// place, which is how the place label becomes assertable on screen.
  final bool named;

  /// Mutable so a test can drain or fill the list mid-run — the page listens
  /// for exactly that.
  bool empty;
  int reads = 0;

  @override
  List<FavoriteRiver> get favorites {
    reads++;
    if (empty) return const [];
    return [
      FavoriteRiver(
        reachId: '9962444',
        riverName: named ? 'White River' : null,
        displayOrder: 0,
        latitude: 40.2,
        longitude: -111.6,
      ),
      if (two)
        const FavoriteRiver(
          reachId: '7000001',
          displayOrder: 1,
          latitude: 43.6,
          longitude: -116.2,
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeAuth extends ChangeNotifier implements AuthProvider {
  _FakeAuth({this.signedIn = false});

  final bool signedIn;

  @override
  AuthUser? get currentUser => signedIn
      ? AuthUser(uid: 'u1', email: 'u@example.com', isEmailVerified: true)
      : null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

late _FakeFavorites _favorites;
late _Forecast _forecast;
late _RecordingSettings _settings;

void _register({
  bool failUpstream = false,
  Duration? loadDelay,
  Duration? geocodeDelay,
  bool geocodeFails = false,
}) {
  final sl = GetIt.instance;
  sl.registerSingleton<IRiverDataRepository>(_StubRepo());
  sl.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
  _forecast = _Forecast(fail: failUpstream, delay: loadDelay);
  sl.registerSingleton<IForecastService>(_forecast);
  _settings = _RecordingSettings();
  sl.registerSingleton<IUserSettingsService>(_settings);
  sl.registerSingleton<IGeocodingService>(
      _FakeGeocoder(delay: geocodeDelay, fails: geocodeFails));
}

Widget _wrap(Widget w,
    {bool named = true,
    bool empty = false,
    bool two = false,
    bool signedIn = false}) {
  _favorites = _FakeFavorites(named: named, empty: empty, two: two);
  return CupertinoApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<FavoritesProvider>.value(value: _favorites),
        ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuth(signedIn: signedIn)),
      ],
      child: w,
    ),
  );
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  tearDown(() => GetIt.instance.reset());

  group('an upstream outage is visible and recoverable', () {
    // REGRESSION: every favourite failing produced an empty row list, which
    // rendered "No forecast is available for your rivers right now." — a card
    // with no Retry, reached by the most ordinary failure there is. Review
    // round 11 reproduced exactly this.
    testWidgets('a total failure shows an error, not "no forecast available"',
        (t) async {
      _register(failUpstream: true);

      await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
      await _settle(t);

      expect(find.textContaining('Could not load'), findsOneWidget,
          reason: 'an outage must say so; "no forecast is available" tells the '
              'user their rivers are quiet when the truth is the server is '
              'down, and offers nothing to do about it');
      expect(find.textContaining('No forecast is available'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });

    // The map sheet names what failed; this surface used to emit one generic
    // apology regardless.
    testWidgets('the error names the river that failed', (t) async {
      _register(failUpstream: true);

      await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
      await _settle(t);

      expect(find.textContaining('White River'), findsOneWidget,
          reason: 'guard 6 requires the terminal state to name what failed');
    });

    // REGRESSION: `_outlookBuilt = true` was set before the await and never
    // reset on failure, so _load()'s guard early-returned forever — the page
    // could never rebuild, by Retry or by a favourites change.
    testWidgets('Retry actually re-attempts the load', (t) async {
      _register(failUpstream: true);

      await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
      await _settle(t);
      final before = _favorites.reads;

      expect(find.text('Retry'), findsOneWidget,
          reason: 'a terminal state with no way out is a dead end');

      await t.tap(find.text('Retry'));
      await _settle(t);

      expect(_favorites.reads, greaterThan(before),
          reason: 'if _outlookBuilt survives the failure the guard at the top '
              'of _load() early-returns and nothing is ever retried');
    });

    // The same guard from the other side: a notification tap opens this page
    // before favourites have loaded, so the provider notifying late is the path
    // that made the stuck-forever bug user-visible.
    testWidgets('a later favourites notification also re-attempts', (t) async {
      _register(failUpstream: true);

      await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
      await _settle(t);
      final before = _favorites.reads;

      _favorites.notifyListeners();
      await _settle(t);

      expect(_favorites.reads, greaterThan(before),
          reason: '_onFavoritesChanged is gated on _outlookBuilt too');
    });
  });

  // REGRESSION, and the reason the first version of this file was rejected:
  // `_service` was a `late final` whose initializer — four GetIt lookups —
  // ran on first touch, which was inside `_load()`'s try. A missing
  // registration therefore rendered "Could not load this week's outlook." with
  // a Retry that could never succeed, laundering a wiring bug into a data
  // failure. The NWM forecast page keeps its resolution outside the try for
  // exactly this reason; this pins the same rule here.
  testWidgets('a missing registration surfaces as a wiring error, not a load '
      'failure', (t) async {
    _register();
    GetIt.instance.unregister<IGeocodingService>();

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await _settle(t);

    expect(t.takeException(), isNotNull,
        reason: 'an unresolvable dependency must surface where it happened');
    expect(find.textContaining('Could not load'), findsNothing,
        reason: 'a DI misconfiguration is not a data-load failure, and telling '
            'the user to Retry it is a lie — the retry cannot succeed');
  });

  // REGRESSION (round 14, F35): the whole empty-favourites path was untested —
  // every fixture had one river. Deleting the fallback timer left an account
  // with zero favourites on a spinner forever, with 980 tests green.
  group('an account with no favourites', () {
    testWidgets('reaches the empty state, not an endless spinner', (t) async {
      _register();

      await t.pumpWidget(_wrap(const WeeklyOutlookPage(), empty: true));
      // Inside the grace period the spinner is correct — favourites may still
      // be loading from Firestore.
      await t.pump(const Duration(seconds: 1));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

      // Past it, the page must commit to the answer it has.
      await t.pump(const Duration(seconds: 9));
      await t.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Add favorite rivers'), findsOneWidget,
          reason: 'without the fallback timer this account spins forever');
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });

    // REGRESSION: `_emptyStateFallback ??= Timer(...)` — once the first timer
    // had fired, a LATER load with an empty list scheduled nothing and left
    // `_loading` true forever. Round 13 fixed it to cancel-and-reschedule and
    // round 14 found the fix unguarded. The sequence: empty → favourites appear
    // but fail → favourites drain → Retry.
    testWidgets('the empty state is reachable a second time', (t) async {
      _register(failUpstream: true);

      await t.pumpWidget(_wrap(const WeeklyOutlookPage(), empty: true));
      await t.pump(const Duration(seconds: 9));
      await t.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Add favorite rivers'), findsOneWidget,
          reason: 'precondition: the first timer has fired');

      // Favourites arrive; the upstream is down; the outage card appears.
      _favorites.empty = false;
      _favorites.notifyListeners();
      await _settle(t);
      expect(find.text('Retry'), findsOneWidget,
          reason: 'precondition: a failure with Retry on screen');

      // Favourites drain again, and the user taps Retry.
      _favorites.empty = true;
      await t.tap(find.text('Retry'));
      await t.pump(const Duration(seconds: 9));
      await t.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Add favorite rivers'), findsOneWidget,
          reason: 'with ??= the fired timer is never replaced, nothing ever '
              'resolves _loading, and this is a permanent spinner');
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });
  });

  // REGRESSION (round 12): the success `setState` set `_rows` and `_loading`
  // but never cleared `_error`. `loadViewStateFor` makes error win over
  // content, so after an outage the very path _onFavoritesChanged exists for
  // rebuilt successfully and the page still showed the outage card with the
  // loaded rows hidden behind it — permanently, since only Retry cleared it.
  testWidgets('a successful reload after a failure clears the error',
      (t) async {
    _register(failUpstream: true);

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await _settle(t);
    expect(find.textContaining('Could not load'), findsOneWidget);

    // Upstream comes back, and favourites notify — the recovery path.
    _forecast.fail = false;
    _favorites.notifyListeners();
    await _settle(t);

    expect(find.textContaining('Could not load'), findsNothing,
        reason: 'the reload succeeded; a stale error must not survive it');
    expect(find.text('White River'), findsWidgets,
        reason: 'and the rows it loaded must actually be visible');
  });

  testWidgets('a successful load shows the outlook and no error', (t) async {
    _register();

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await _settle(t);

    expect(find.textContaining('Could not load'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('White River'), findsWidgets);
  });

  // REGRESSION: `_fillPlaceLabels` and `OutlookRow.withLocation` — the entire
  // mechanism that preserves the place label now that the service no longer
  // resolves it — could both be deleted with the suite green. An unnamed river
  // titles itself with its place, so the label is visible on screen.
  testWidgets('the place label arrives after the page has rendered', (t) async {
    _register(geocodeDelay: const Duration(milliseconds: 400));

    await t.pumpWidget(_wrap(const WeeklyOutlookPage(), named: false));
    await t.pump();
    await t.pump(const Duration(milliseconds: 30));

    expect(find.text('Provo, UT'), findsNothing,
        reason: 'the geocode is still outstanding — if the label is already '
            'here the page waited on it, the defect this phase removed');
    expect(find.textContaining('Could not load'), findsNothing,
        reason: 'and the page rendered anyway');

    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 50));

    expect(find.text('Provo, UT'), findsOneWidget,
        reason: 'the label must still arrive; deleting _fillPlaceLabels or '
            'withLocation loses it silently');
  });

  // REGRESSION (round 15, F40 — a live data regression with the screen
  // correct): `_recordOutlookOpen` persisted `row.title` from the list built
  // BEFORE the geocodes resolved. `withLocation` returns new objects into
  // `_rows`, so that list never acquires a label — the user doc the Friday push
  // banner reads got "Station 9962444" written over a previously-correct
  // "Provo, UT", and nothing on screen ever disagreed.
  group('the persisted digest label', () {
    testWidgets('is the resolved place, not the placeholder', (t) async {
      _register();
      // Unnamed favourite AND unnamed reach: the row's title is the
      // "Station 9962444" placeholder until the geocode lands.
      _forecast.unnamedReach = true;

      await t.pumpWidget(
          _wrap(const WeeklyOutlookPage(), named: false, signedIn: true));
      await _settle(t);
      // The screen has the label…
      expect(find.text('Provo, UT'), findsOneWidget);

      // …and so must the write the digest banner reads.
      expect(_settings.stored['9962444'], 'Provo, UT',
          reason: 'persisting the pre-geocode list writes the placeholder '
              'over a correct stored label — the screen is right and the '
              'write is wrong, so nothing visible ever catches it');
    });

    testWidgets('a placeholder is never written over a stored label',
        (t) async {
      _register(geocodeDelay: const Duration(seconds: 30));
      _forecast.unnamedReach = true;

      await t.pumpWidget(
          _wrap(const WeeklyOutlookPage(), named: false, signedIn: true));
      await _settle(t);

      expect(
          _settings.updates.any((u) => u.containsKey('favoriteLabels')), isFalse,
          reason: 'no geocode has resolved; the only honest write is none');
      expect(
          _settings.updates.any(
              (u) => u.containsKey('weeklyDigestsSinceOpen')),
          isTrue,
          reason: 'but the back-off counter reset must not wait on geocoding');

      // Drain the pending geocodes so the test ends clean.
      await t.pump(const Duration(seconds: 31));
      await t.pump(const Duration(milliseconds: 100));
    });

    // REGRESSION (round 16, F47): the read-modify-write merge was deletable
    // with the suite green — every earlier test only asserted the row's OWN
    // label. With the merge gone, persisting one river's label DELETES the
    // stored labels of every river that did not load this week, and Friday's
    // banner regresses to raw station ids for all of them.
    testWidgets('persisting one label does not delete the others', (t) async {
      _register();
      _forecast.unnamedReach = true;
      _settings.stored = {'8888888': 'Elsewhere, OR'};

      await t.pumpWidget(
          _wrap(const WeeklyOutlookPage(), named: false, signedIn: true));
      await _settle(t);

      expect(_settings.stored['9962444'], 'Provo, UT',
          reason: 'this week\'s label is written');
      expect(_settings.stored['8888888'], 'Elsewhere, OR',
          reason: 'a river that did not load this week keeps its stored label '
              '— without the read-modify-write merge it is silently deleted');
    });

    // REGRESSION (round 16, F49): the isTotalFailure return skipped
    // _recordOutlookOpen, so a user who opened the outlook during an outage
    // kept escalating toward digest suppression. Opening is engagement
    // regardless of what loaded.
    testWidgets('an outage still resets the digest back-off counter',
        (t) async {
      _register(failUpstream: true);

      await t.pumpWidget(_wrap(const WeeklyOutlookPage(), signedIn: true));
      await _settle(t);

      expect(find.text('Retry'), findsOneWidget,
          reason: 'precondition: this is the outage path');
      expect(
          _settings.updates
              .any((u) => u.containsKey('weeklyDigestsSinceOpen')),
          isTrue,
          reason: 'the user opened the page; the server must not count this '
              'week as ignored');
    });

    // REGRESSION (round 16, F48): these lookups sat inside caught bodies,
    // where a missing IUserSettingsService registration degraded to a debug
    // log — the exact laundering guard 8 forbids, one round after the same
    // class was fixed for the geocoder.
    testWidgets('a missing settings service is a wiring bug at mount',
        (t) async {
      _register();
      GetIt.instance.unregister<IUserSettingsService>();

      await t.pumpWidget(_wrap(const WeeklyOutlookPage(), signedIn: true));
      final thrown = t.takeException();
      await _settle(t);

      expect(thrown, isNotNull,
          reason: 'resolved lazily inside a try, this silently stopped both '
              'the counter reset and the label persist');
    });

    // A geocode that yields nothing leaves the row titled by its placeholder.
    // On an earlier open the geocode worked and "Provo, UT" was stored; this
    // open must not regress that label to "Station 9962444".
    testWidgets('a failed geocode leaves the stored label alone', (t) async {
      _register(geocodeFails: true);
      _forecast.unnamedReach = true;
      _settings.stored = {'9962444': 'Provo, UT'};

      await t.pumpWidget(
          _wrap(const WeeklyOutlookPage(), named: false, signedIn: true));
      await _settle(t);

      expect(_settings.stored['9962444'], 'Provo, UT',
          reason: 'a placeholder title means "nothing resolved this time" — '
              'writing it over a real label makes Friday\'s banner worse than '
              'last week\'s');
    });
  });

  // REGRESSION (round 15, F42): the identity match in _fillPlaceLabels could
  // be mutated to `if (true)` — every geocode result stamped onto every row —
  // with the suite green, because every fixture had exactly one favourite.
  testWidgets('each river gets ITS label, not the last one to resolve',
      (t) async {
    _register();

    await t.pumpWidget(_wrap(const WeeklyOutlookPage(), named: false, two: true));
    await _settle(t);

    expect(find.text('Provo, UT'), findsOneWidget,
        reason: 'the 40.2°N river geocodes to Provo');
    expect(find.text('Boise, ID'), findsOneWidget,
        reason: 'the 43.6°N river geocodes to Boise — one of each, not two of '
            'whichever resolved last');
  });

  // REGRESSION (round 15, F46): every favourite answering 200 with no usable
  // series landed on "No forecast is available…" with no way out — the literal
  // dead end guard 6 exists to eliminate, reachable without any throw. And
  // Retry from that state must reset _outlookBuilt, or _load() early-returns
  // into a permanent spinner.
  testWidgets('the no-forecast state has a Retry that actually rebuilds',
      (t) async {
    _register();
    _forecast.emptySeries = true;

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await _settle(t);

    expect(find.textContaining('No forecast is available'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget,
        reason: 'a state the user may sit in for minutes needs a way out');

    _forecast.emptySeries = false;
    await t.tap(find.text('Retry'));
    await _settle(t);

    expect(find.text('White River'), findsWidgets,
        reason: 'without resetting _outlookBuilt, Retry early-returns at the '
            'top of _load() and this is a spinner forever');
  });

  // Same class as the sheet's and both forecast-page branches' dispose tests,
  // swept here rather than waiting for it to be reported. This page fires one
  // unawaited geocode per row, each ending in setState.
  testWidgets('popping while the geocodes are outstanding is safe', (t) async {
    _register(geocodeDelay: const Duration(seconds: 5));

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await _settle(t);

    await t.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await t.pump(const Duration(seconds: 6));
    await t.pump(const Duration(milliseconds: 50));

    expect(t.takeException(), isNull);
  });

  // REGRESSION (round 13): every dispose test popped while a load was
  // SUCCEEDING, so the `mounted` check on the failure path was unfalsifiable —
  // on all four surfaces at once.
  testWidgets('popping while a FAILING load is outstanding is safe', (t) async {
    _register(failUpstream: true, loadDelay: const Duration(seconds: 5));

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await t.pump(const Duration(milliseconds: 50));

    await t.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await t.pump(const Duration(seconds: 6));
    await t.pump(const Duration(milliseconds: 50));

    expect(t.takeException(), isNull,
        reason: 'the outage setState lands on a defunct State without the '
            'mounted check');
  });

  testWidgets('popping while the loads are outstanding is safe', (t) async {
    _register(loadDelay: const Duration(seconds: 5));

    await t.pumpWidget(_wrap(const WeeklyOutlookPage()));
    await t.pump(const Duration(milliseconds: 50));

    await t.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await t.pump(const Duration(seconds: 6));
    await t.pump(const Duration(milliseconds: 50));

    expect(t.takeException(), isNull);
  });
}
