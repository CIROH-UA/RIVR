import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/services/0_config/shared/constants.dart';

// AppConstants is the single owner of flood colour (ADR 0007). Before this,
// three places each held their own copy and one of them switched on a
// vocabulary the classifier had stopped producing, so every category above
// Normal painted grey. These are the assertions that would have caught it.

void main() {
  group('the palette covers the ladder', () {
    test('one colour per rung, no more, no fewer', () {
      expect(
        AppConstants.floodCategoryColors.length,
        kFloodCategories.length,
        reason: 'a rung without a colour silently becomes grey',
      );
    });

    // The original bug in one assertion: every real category must resolve to
    // something other than the unknown colour.
    test('every ladder name resolves to a real colour', () {
      for (final name in kFloodCategories) {
        expect(
          AppConstants.getFlowCategoryColor(name),
          isNot(AppConstants.unknownCategoryColor),
          reason: '"$name" fell through to unknown',
        );
      }
    });

    test('names resolve regardless of case', () {
      for (final name in kFloodCategories) {
        expect(
          AppConstants.getFlowCategoryColor(name.toLowerCase()),
          AppConstants.getFlowCategoryColor(name),
        );
        expect(
          AppConstants.getFlowCategoryColor(name.toUpperCase()),
          AppConstants.getFlowCategoryColor(name),
        );
      }
    });

    test('every rung is visually distinct', () {
      final seen = <int>{};
      for (final c in AppConstants.floodCategoryColors) {
        expect(seen.add(c.toARGB32()), isTrue,
            reason: 'two rungs share a colour, making them indistinguishable');
      }
    });

    test('index lookup and name lookup agree', () {
      for (var i = 0; i < kFloodCategories.length; i++) {
        expect(
          AppConstants.floodColorForIndex(i),
          AppConstants.getFlowCategoryColor(kFloodCategories[i]),
        );
      }
    });
  });

  group('what is not on the ladder is unknown, not guessed', () {
    // The retired vocabulary. If any of these ever resolves to a real colour
    // again, something has reintroduced a parallel ladder.
    test('the retired Elevated/High/Flood Risk names are unknown', () {
      for (final dead in ['Elevated', 'High', 'Flood Risk']) {
        expect(
          AppConstants.getFlowCategoryColor(dead),
          AppConstants.unknownCategoryColor,
          reason: '"$dead" is not a category any classifier produces',
        );
      }
    });

    test('null, empty and nonsense are unknown', () {
      expect(AppConstants.getFlowCategoryColor(null),
          AppConstants.unknownCategoryColor);
      expect(AppConstants.getFlowCategoryColor(''),
          AppConstants.unknownCategoryColor);
      expect(AppConstants.getFlowCategoryColor('Unknown'),
          AppConstants.unknownCategoryColor);
    });

    test('an out-of-range index does not throw', () {
      expect(AppConstants.floodColorForIndex(-1),
          AppConstants.unknownCategoryColor);
      expect(AppConstants.floodColorForIndex(99),
          AppConstants.unknownCategoryColor);
      expect(AppConstants.floodColorForIndex(null),
          AppConstants.unknownCategoryColor);
    });
  });

  group('text on a filled swatch stays legible', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    // Action is #FFC400: white on it measures 1.6:1, far under AA. That is the
    // failure this pairing exists to prevent, and it is the same class of bug
    // as the old offline banner.
    //
    // 3.0 is the floor asserted here — WCAG's threshold for UI components and
    // large text. Two rungs land between 3.0 and 4.5 and are pinned below;
    // the rest clear 4.5 comfortably.
    test('every rung clears the UI-component floor with its paired ink', () {
      for (final name in kFloodCategories) {
        final bg = AppConstants.getFlowCategoryColor(name);
        final ink = AppConstants.getFlowCategoryOnColor(name);
        expect(contrast(bg, ink), greaterThanOrEqualTo(3.0),
            reason: '"$name" chip text is not legible');
      }
    });

    test('the warm rungs clear full AA once the ink is chosen properly', () {
      for (final name in ['Action', 'Moderate', 'Extreme']) {
        final bg = AppConstants.getFlowCategoryColor(name);
        final ink = AppConstants.getFlowCategoryOnColor(name);
        expect(contrast(bg, ink), greaterThanOrEqualTo(4.5),
            reason: '"$name" chip text is not legible');
      }
    });

    // Two rungs land between the 3.0 UI floor and full AA, and no choice of
    // ink fixes them — the colours themselves are mid-tone:
    //
    //   Normal #0A84FF  white 3.65  (dark 3.62 — nothing to gain)
    //   Major  #E53935  white 4.23  (dark 3.13)
    //
    // Both are accepted rather than fixed. Normal is the hex of iOS systemBlue,
    // the pairing Apple ships on every filled button; Major is the published
    // map red, already baked into the daily tileset. RIVR writes the category
    // out in words beside every swatch, so neither is carried by colour alone.
    //
    // Pinned to exact values so changing either forces a conscious decision
    // here rather than a quiet drift.
    test('the two known sub-AA rungs stay where they are', () {
      double ratioFor(String name) => contrast(
            AppConstants.getFlowCategoryColor(name),
            AppConstants.getFlowCategoryOnColor(name),
          );
      expect(ratioFor('Normal'), closeTo(3.65, 0.02));
      expect(ratioFor('Major'), closeTo(4.23, 0.02));
    });

    test('the warm rungs take dark ink, the cool ones white', () {
      for (final warm in ['Action', 'Moderate']) {
        expect(AppConstants.getFlowCategoryOnColor(warm),
            isNot(CupertinoColors.white),
            reason: '$warm needs dark ink');
      }
      for (final cool in ['Normal', 'Major', 'Extreme']) {
        expect(AppConstants.getFlowCategoryOnColor(cool),
            CupertinoColors.white);
      }
    });

  });

  group('icons follow the same ladder', () {
    test('every rung has a distinct icon', () {
      final seen = <IconData>{};
      for (final name in kFloodCategories) {
        final icon = AppConstants.getFlowCategoryIcon(name);
        expect(icon, isNot(CupertinoIcons.question_circle),
            reason: '"$name" fell through to the unknown icon');
        expect(seen.add(icon), isTrue, reason: 'two rungs share an icon');
      }
    });
  });
}
