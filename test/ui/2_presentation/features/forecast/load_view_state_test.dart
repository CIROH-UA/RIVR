// test/ui/2_presentation/features/forecast/load_view_state_test.dart
//
// The precedence rule, tested directly with both inputs set.
//
// This exists because the order-based version could not be honestly guarded.
// Two surfaces checked `_loading` before `_error`, so a load that failed
// without clearing the flag rendered a spinner forever and the failure was
// invisible. Reordering the `if`s fixed the symptom — but the both-set state is
// unreachable through either widget's own lifecycle (every catch clears the
// flag, and Retry clears the error), so a widget test could not drive it and
// the "guard" passed whichever order was in place. Review proved exactly that:
// swapping the order back left the whole suite green.
//
// Moving the decision into a function makes the state constructible.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/ui/2_presentation/features/forecast/load_view_state.dart';

void main() {
  group('error always wins', () {
    // THE case. Both set is what a stuck loading flag looks like, and it is the
    // only input combination the previous ordering got wrong.
    test('an error is shown even while loading is still true', () {
      expect(
        loadViewStateFor(hasError: true, isLoading: true),
        LoadViewState.error,
        reason: 'a failure must never be maskable by a flag left set — this is '
            'the exact combination that rendered an endless spinner',
      );
    });

    test('an error with loading finished still shows the error', () {
      expect(
        loadViewStateFor(hasError: true, isLoading: false),
        LoadViewState.error,
      );
    });
  });

  group('the ordinary paths', () {
    test('loading with no error shows the skeleton', () {
      expect(
        loadViewStateFor(hasError: false, isLoading: true),
        LoadViewState.loading,
      );
    });

    test('neither means content', () {
      expect(
        loadViewStateFor(hasError: false, isLoading: false),
        LoadViewState.content,
      );
    });
  });

  // Every input combination is covered above; this pins that no fifth outcome
  // can appear without a test failing.
  test('the truth table is total — four inputs, three outcomes', () {
    final seen = <LoadViewState>{};
    for (final e in [true, false]) {
      for (final l in [true, false]) {
        seen.add(loadViewStateFor(hasError: e, isLoading: l));
      }
    }
    expect(seen, {
      LoadViewState.error,
      LoadViewState.loading,
      LoadViewState.content,
    });
  });
}
