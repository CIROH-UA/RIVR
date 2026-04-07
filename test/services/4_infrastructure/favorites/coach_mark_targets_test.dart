// test/services/4_infrastructure/favorites/coach_mark_targets_test.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import 'package:rivr/services/4_infrastructure/favorites/coach_mark_targets.dart';

void main() {
  group('CoachMarkTargets', () {
    group('buildFavoritesTourTargets (Phase A)', () {
      late List<TargetFocus> targets;

      setUp(() {
        targets = CoachMarkTargets.buildFavoritesTourTargets(
          firstCardKey: GlobalKey(),
          settingsButtonKey: GlobalKey(),
        );
      });

      test('returns exactly 3 targets', () {
        expect(targets.length, 3);
      });

      test('targets have correct identifiers', () {
        expect(targets[0].identify, 'pull_to_refresh');
        expect(targets[1].identify, 'swipe_left');
        expect(targets[2].identify, 'settings_menu');
      });

      test('targets have correct shapes', () {
        expect(targets[0].shape, ShapeLightFocus.RRect);
        expect(targets[1].shape, ShapeLightFocus.RRect);
        expect(targets[2].shape, ShapeLightFocus.Circle);
      });

      test('each target has content', () {
        for (final target in targets) {
          expect(target.contents, isNotEmpty);
          expect(target.contents!.first.builder, isNotNull);
        }
      });

      test('all content aligns to bottom', () {
        expect(targets[0].contents!.first.align, ContentAlign.bottom);
      });

      test('swipe_left and settings content aligns to bottom', () {
        expect(targets[1].contents!.first.align, ContentAlign.bottom);
        expect(targets[2].contents!.first.align, ContentAlign.bottom);
      });

      test('all targets disable overlay and target tap', () {
        for (final target in targets) {
          expect(target.enableOverlayTab, isFalse);
          expect(target.enableTargetTab, isFalse);
        }
      });
    });

    group('buildSearchTipTargets (Phase B)', () {
      late List<TargetFocus> targets;

      setUp(() {
        targets = CoachMarkTargets.buildSearchTipTargets(
          searchIconKey: GlobalKey(),
        );
      });

      test('returns exactly 1 target', () {
        expect(targets.length, 1);
      });

      test('target has correct identifier', () {
        expect(targets[0].identify, 'search_icon');
      });

      test('target has circle shape', () {
        expect(targets[0].shape, ShapeLightFocus.Circle);
      });

      test('target has content', () {
        expect(targets[0].contents, isNotEmpty);
        expect(targets[0].contents!.first.builder, isNotNull);
      });

      test('target disables overlay and target tap', () {
        expect(targets[0].enableOverlayTab, isFalse);
        expect(targets[0].enableTargetTab, isFalse);
      });
    });
  });
}
