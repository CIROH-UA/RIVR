// test/services/4_infrastructure/favorites/coach_mark_service_test.dart
//
// The favourites list used to run a four-panel `tutorial_coach_mark` tour the
// moment a user saved their first river: a 90%-black overlay explaining
// pull-to-refresh, swipe actions and the settings menu, then a search tip
// chained onto the end — with `hideSkip: true`, so there was no way out.
//
// It is replaced by a single hint that demonstrates the ONE thing that is not
// discoverable: that actions live behind a card. These guards pin WHEN it
// runs, which is the part Jerson asked for — not on the first arrival.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/services/4_infrastructure/favorites/coach_mark_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('visit counting', () {
    test('counts each arrival at the favourites list', () async {
      expect(await CoachMarkService.visitCount(), 0);
      expect(await CoachMarkService.recordVisit(), 1);
      expect(await CoachMarkService.recordVisit(), 2);
      expect(await CoachMarkService.visitCount(), 2);
    });

    test('the count survives a restart', () async {
      await CoachMarkService.recordVisit();
      SharedPreferences.setMockInitialValues(
          {'flutter.favorites_visit_count': 1});
      expect(await CoachMarkService.recordVisit(), 2);
    });
  });

  group('when the hint runs', () {
    test('NOT on the first arrival', () async {
      expect(
        CoachMarkService.shouldShowOnVisit(
            visit: 1, alreadySeen: false, hasAnyFavourite: true),
        isFalse,
        reason: 'the first arrival is when someone has just saved a river '
            'and wants to look at it — interrupting there is what made the '
            'old tour invasive',
      );
    });

    test('on the second arrival', () async {
      expect(
        CoachMarkService.shouldShowOnVisit(
            visit: 2, alreadySeen: false, hasAnyFavourite: true),
        isTrue,
      );
    });

    test('never once it has been seen', () async {
      expect(
        CoachMarkService.shouldShowOnVisit(
            visit: 7, alreadySeen: true, hasAnyFavourite: true),
        isFalse,
      );
    });

    test('never with an empty list — there is no card to demonstrate on',
        () async {
      expect(
        CoachMarkService.shouldShowOnVisit(
            visit: 2, alreadySeen: false, hasAnyFavourite: false),
        isFalse,
      );
    });

    test('a later arrival still qualifies if earlier ones were skipped',
        () async {
      // Someone whose list was empty on visits 2 and 3 must still get the
      // hint once they finally have a river.
      expect(
        CoachMarkService.shouldShowOnVisit(
            visit: 5, alreadySeen: false, hasAnyFavourite: true),
        isTrue,
      );
    });
  });

  group('seen flag', () {
    test('false until completed, true after, and it persists', () async {
      expect(await CoachMarkService.hasSeenSwipeHint(), isFalse);
      await CoachMarkService.completeSwipeHint();
      expect(await CoachMarkService.hasSeenSwipeHint(), isTrue);
      expect(await CoachMarkService.hasSeenSwipeHint(), isTrue);
    });
  });

  test('the trigger visit is the second, stated once', () {
    expect(CoachMarkService.showOnVisit, 2);
  });
}
