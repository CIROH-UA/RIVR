// test/services/4_infrastructure/river_data/hold_policy_test.dart
//
// ADR 0011 Phase 7. `hold_policy.dart` is pure, decides whether the app warns
// its users, and had NO direct test — it was exercised only through the
// repository, which meant its edge cases were reached incidentally or not at
// all. Found by auditing what today's changes actually pinned rather than
// which files tests happened to mention.
//
// The cross-language drift test (`functions/src/hold-policy-drift.test.ts`)
// guards the NUMBERS against the server. This guards the BEHAVIOUR.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/services/4_infrastructure/river_data/hold_policy.dart';

void main() {
  // Every existing case in this file was written against CONUS cadences, so
  // it keeps a CONUS reach. The island cases are a separate group below.
  const conusReach = '23021904';
  const islandReach = '800000010';

  final now = DateTime.utc(2026, 8, 30, 12, 0);

  group('maxHoldFor', () {
    test('every product the store writes has a cap', () {
      for (final p in [
        ForecastProduct.currentFlow,
        ForecastProduct.shortRange,
        ForecastProduct.mediumRange,
        ForecastProduct.longRange,
        ForecastProduct.geoglowsForecast,
        ForecastProduct.reachMetadata,
        ForecastProduct.returnPeriods,
      ]) {
        expect(maxHoldFor(p, reachId: conusReach).inMinutes, greaterThan(0),
            reason: '$p has none');
      }
    });

    test('an unnamed product falls back to the SHORT default', () {
      // Failing towards "check again" is the safe direction; failing towards
      // "hold forever" is how a stale value becomes invisible.
      expect(maxHoldFor(ForecastProduct.reachSummary, reachId: conusReach),
          defaultMaxHold);
      expect(defaultMaxHold, const Duration(hours: 6));
    });

    // The near-static products hold a 30-day window and are rewritten only
    // when missing or nearly expired, so an untouched 23-day-old document is
    // healthy. Judging them by the short default is what took storeHealth to
    // 503 on a healthy store within a minute of deploying.
    test('the near-static products are not judged by the hourly default', () {
      for (final p in [
        ForecastProduct.reachMetadata,
        ForecastProduct.returnPeriods,
      ]) {
        expect(maxHoldFor(p, reachId: conusReach).inDays, greaterThan(30),
            reason: '$p');
      }
    });
  });

  group('heldTooLong', () {
    test('inside the cap is fine, past it is not', () {
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: now.subtract(const Duration(hours: 5)),
          now: now, reachId: conusReach),
        isFalse,
      );
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: now.subtract(const Duration(hours: 7)),
          now: now, reachId: conusReach),
        isTrue,
      );
    });

    test('a fetch time in the future is never "too long ago"', () {
      // Clock skew between the server that stamped it and the device reading
      // it must not read as staleness.
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: now.add(const Duration(hours: 2)),
          now: now, reachId: conusReach),
        isFalse,
      );
    });

    test('local-time input gives the same answer as UTC', () {
      // A device in a non-UTC zone must not decide freshness by its offset.
      //
      // Honest note: this documents the behaviour, it does not PIN the
      // `.toUtc()` calls in the implementation. Mutation-checked — removing
      // them keeps every test green, because Dart's `DateTime.difference` is
      // absolute and ignores the flag. They are belt-and-braces, and a future
      // reader should not take them for load-bearing.
      final localNow = now.toLocal();
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: now.subtract(const Duration(hours: 1)),
          now: localNow, reachId: conusReach),
        isFalse,
      );
    });
  });

  group('runInstant', () {
    test('null, empty and unreadable all yield null', () {
      // Never guess. An unreadable run is not evidence of staleness.
      expect(runInstant(null), isNull);
      expect(runInstant(''), isNull);
      expect(runInstant('not-a-date'), isNull);
      expect(runInstant('|'), isNull);
    });

    test('a plain ISO instant is read as itself', () {
      expect(runInstant('2026-08-29T06:00:00Z'),
          DateTime.utc(2026, 8, 29, 6));
    });

    // Mirrors `parseRunInstant` on the server, including this choice. A
    // payload spanning several runs is only as fresh as its OLDEST water, the
    // probe sorts these oldest-first so an inconsistent series stays visible,
    // and the server's `isRunNewer` orders them by the same leading segment.
    test('a pipe-joined run yields its OLDEST segment', () {
      expect(
        runInstant('2026-08-29T18:00:00Z|2026-08-28T06:00:00Z'),
        DateTime.utc(2026, 8, 28, 6),
      );
    });

    test('unreadable segments are skipped, not fatal', () {
      expect(
        runInstant('garbage|2026-08-29T06:00:00Z'),
        DateTime.utc(2026, 8, 29, 6),
      );
    });

    test('the result is UTC even when the input carries an offset', () {
      final r = runInstant('2026-08-29T06:00:00+02:00');
      expect(r!.isUtc, isTrue);
      expect(r, DateTime.utc(2026, 8, 29, 4));
    });
  });

  group('runTooOld', () {
    test('a product with no run-age cap is never judged', () {
      // These carry no run identity at all; defaulting them is how the hold
      // cap called a healthy store down.
      expect(
        runTooOld(
          product: ForecastProduct.reachMetadata,
          runId: DateTime.utc(2020).toIso8601String(),
          now: now, reachId: conusReach),
        isFalse,
      );
    });

    test('an absent or unreadable run is never treated as stale', () {
      expect(
        runTooOld(
          product: ForecastProduct.shortRange,
          runId: null,
          now: now,
          reachId: conusReach,
        ),
        isFalse,
      );
      expect(
        runTooOld(
            product: ForecastProduct.shortRange,
            runId: 'nope',
            now: now,
            reachId: conusReach),
        isFalse,
      );
    });

    test('inside the cap is fine, past it is not', () {
      // shortRange's run-age cap is 16h.
      expect(
        runTooOld(
          product: ForecastProduct.shortRange,
          runId: now.subtract(const Duration(hours: 11)).toIso8601String(),
          now: now, reachId: conusReach),
        isFalse,
        reason: '11h is the worst run age measured across 163 real probe '
            'samples; alarming here alarms on ordinary days',
      );
      expect(
        runTooOld(
          product: ForecastProduct.shortRange,
          runId: now.subtract(const Duration(hours: 17)).toIso8601String(),
          now: now, reachId: conusReach),
        isTrue,
      );
    });

    // THE incident, at the level of the policy that decides it.
    test('GEOGLOWS: 35.5h is normal, 49.5h is the 2026-08-29 failure', () {
      DateTime ago(double h) =>
          now.subtract(Duration(minutes: (h * 60).round()));

      expect(
        runTooOld(
          product: ForecastProduct.geoglowsForecast,
          runId: ago(35.5).toIso8601String(),
          now: now, reachId: conusReach),
        isFalse,
        reason: 'a stored run legitimately reaches 35.5h before our 11:30 '
            'fetch replaces it — measured in production',
      );
      expect(
        runTooOld(
          product: ForecastProduct.geoglowsForecast,
          runId: ago(49.5).toIso8601String(),
          now: now, reachId: conusReach),
        isTrue,
        reason: '49.5h is what the old 01:30 schedule produced, holding '
            "yesterday's run all day",
      );
    });

    test('a future run is never stale', () {
      expect(
        runTooOld(
          product: ForecastProduct.shortRange,
          runId: now.add(const Duration(hours: 3)).toIso8601String(),
          now: now, reachId: conusReach),
        isFalse,
      );
    });
  });

  // ── Phase 9: the caps were CONUS-shaped and would have failed islands ─────
  group('Hawaii and Puerto Rico reaches get their own caps', () {
    test('a 12-hour-old island short range is still HELD, CONUS is not', () {
      // The concrete failure. Hawaii short range publishes at t00z and t12z
      // only (measured 2026-08-30), so a document fetched 12 hours ago is the
      // newest that exists. The CONUS cap of 6 hours would have expired it and
      // sent every device with a Hawaii favourite back upstream for half of
      // every cycle — breaking guard 1's "renders with zero upstream calls".
      final at = DateTime.utc(2026, 8, 30, 12, 0);
      final fetched = at.subtract(const Duration(hours: 12));
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: fetched,
          now: at,
          reachId: islandReach,
        ),
        isFalse,
      );
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: fetched,
          now: at,
          reachId: conusReach,
        ),
        isTrue,
        reason: 'a CONUS reach silent for 12 hours really is broken; the two '
            'domains must not share one answer',
      );
    });

    test('the island cap still ENDS — 25 hours is too long', () {
      // Not "hold forever". Two missed Hawaii cycles is a real outage.
      final at = DateTime.utc(2026, 8, 30, 12, 0);
      expect(
        heldTooLong(
          product: ForecastProduct.shortRange,
          fetchedAt: at.subtract(const Duration(hours: 25)),
          now: at,
          reachId: islandReach,
        ),
        isTrue,
      );
    });

    test('15.3h of run age is normal on an island, alarming on CONUS', () {
      // The exact measurement: NWPS reach 800000010 reported its short-range
      // run as 00:00Z at 15:16Z on 2026-08-30, still current. The CONUS cap of
      // 16 hours was one missed publication from alarming on a healthy river.
      final at = DateTime.utc(2026, 8, 30, 15, 16);
      final run = DateTime.utc(2026, 8, 30, 0, 0).toIso8601String();
      expect(
        runTooOld(
          product: ForecastProduct.shortRange,
          runId: run,
          now: at,
          reachId: islandReach,
        ),
        isFalse,
      );
      expect(
        runTooOld(
          product: ForecastProduct.shortRange,
          runId: run,
          now: at.add(const Duration(hours: 1)),
          reachId: conusReach,
        ),
        isTrue,
        reason: 'the same run one hour later trips the CONUS cap — which is '
            'why the island reach needed its own',
      );
    });

    test('the misnamed current-flow product takes short range\'s caps', () {
      // `analysisAssimilation` fetches `short_range`. Giving it the CONUS cap
      // because of its name left island current-flow documents expiring
      // between runs while carrying 12-hourly Hawaii data.
      for (final reach in [islandReach, conusReach]) {
        expect(
          maxHoldFor(ForecastProduct.currentFlow, reachId: reach),
          maxHoldFor(ForecastProduct.shortRange, reachId: reach),
          reason: 'both carry the same series; their caps cannot differ',
        );
        expect(
          maxRunAgeFor(ForecastProduct.currentFlow, reachId: reach),
          maxRunAgeFor(ForecastProduct.shortRange, reachId: reach),
        );
      }
    });

    test('the forecast products are unchanged by domain', () {
      // Analysis assimilation publishes hourly in every domain, and the
      // islands have no medium or long range at all. Widening the whole table
      // would be the obvious wrong fix.
      for (final p in [
        // analysisAssimilation is deliberately NOT here: it fetches the short
        // range series, so it takes short range's island caps. Listing it as
        // "unchanged" is the mistake this file made first time round.
        ForecastProduct.mediumRange,
        ForecastProduct.longRange,
        ForecastProduct.reachMetadata,
        ForecastProduct.returnPeriods,
      ]) {
        expect(
          maxHoldFor(p, reachId: islandReach),
          maxHoldFor(p, reachId: conusReach),
          reason: '$p must not have picked up an island cap',
        );
      }
    });
  });
}
