// lib/models/1_domain/shared/flow_classification.dart
//
// The ONE flood-category ladder for the whole app. Every surface — gauge,
// favorites card, hourly timeline, map bottom sheet, forecast detail — must
// classify flow through this. Never reimplement the thresholds inline: doing
// so is how the app ended up showing "Action" on the gauge and "Elevated" on
// the hourly card for the same flow (see the data-consistency audit).
//
// Inputs must be in the SAME unit — convert the return periods to the flow's
// unit before calling (return periods are natively CMS; convert at the
// consume boundary).

/// Ordered flood categories, low → high. Index doubles as the gauge zone index.
const List<String> kFloodCategories = [
  'Normal',
  'Action',
  'Moderate',
  'Major',
  'Extreme',
];

class FlowClassification {
  const FlowClassification._();

  /// Category index 0..4 for [flow] against return-period [thresholds]
  /// (both in the same unit); -1 when it can't be determined.
  ///
  /// Uses the 2/5/10/25-yr recurrence thresholds — the app's canonical ladder.
  static int indexFor(double? flow, Map<int, double>? thresholds) {
    if (flow == null || thresholds == null) return -1;
    final t2 = thresholds[2];
    final t5 = thresholds[5];
    final t10 = thresholds[10];
    final t25 = thresholds[25];
    if (t2 == null || t5 == null || t10 == null || t25 == null) return -1;
    if (flow < t2) return 0;
    if (flow < t5) return 1;
    if (flow < t10) return 2;
    if (flow < t25) return 3;
    return 4;
  }

  /// Category name for [flow], or `'Unknown'` when thresholds are unavailable.
  static String category(double? flow, Map<int, double>? thresholds) {
    final i = indexFor(flow, thresholds);
    return i < 0 ? 'Unknown' : kFloodCategories[i];
  }
}
