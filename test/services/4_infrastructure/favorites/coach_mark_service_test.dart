// test/services/4_infrastructure/favorites/coach_mark_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/services/4_infrastructure/favorites/coach_mark_service.dart';

void main() {
  group('CoachMarkService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    group('favorites tour (Phase A)', () {
      test('returns false when tour has not been seen', () async {
        expect(await CoachMarkService.hasSeenFavoritesTour(), isFalse);
      });

      test('returns true after completing tour', () async {
        await CoachMarkService.completeFavoritesTour();
        expect(await CoachMarkService.hasSeenFavoritesTour(), isTrue);
      });

      test('persists across multiple reads', () async {
        await CoachMarkService.completeFavoritesTour();
        expect(await CoachMarkService.hasSeenFavoritesTour(), isTrue);
        expect(await CoachMarkService.hasSeenFavoritesTour(), isTrue);
      });
    });

    group('search tip (Phase B)', () {
      test('returns false when tip has not been seen', () async {
        expect(await CoachMarkService.hasSeenSearchTip(), isFalse);
      });

      test('returns true after completing tip', () async {
        await CoachMarkService.completeSearchTip();
        expect(await CoachMarkService.hasSeenSearchTip(), isTrue);
      });

      test('persists across multiple reads', () async {
        await CoachMarkService.completeSearchTip();
        expect(await CoachMarkService.hasSeenSearchTip(), isTrue);
        expect(await CoachMarkService.hasSeenSearchTip(), isTrue);
      });
    });

    group('independence', () {
      test('completing favorites tour does not affect search tip', () async {
        await CoachMarkService.completeFavoritesTour();
        expect(await CoachMarkService.hasSeenFavoritesTour(), isTrue);
        expect(await CoachMarkService.hasSeenSearchTip(), isFalse);
      });

      test('completing search tip does not affect favorites tour', () async {
        await CoachMarkService.completeSearchTip();
        expect(await CoachMarkService.hasSeenSearchTip(), isTrue);
        expect(await CoachMarkService.hasSeenFavoritesTour(), isFalse);
      });

      test('both can be completed independently', () async {
        await CoachMarkService.completeFavoritesTour();
        await CoachMarkService.completeSearchTip();
        expect(await CoachMarkService.hasSeenFavoritesTour(), isTrue);
        expect(await CoachMarkService.hasSeenSearchTip(), isTrue);
      });
    });
  });
}
