// lib/utils/flow_format.dart

/// Canonical flow-value formatting for the whole app.
///
/// Two display forms, matching the two treatments the UI actually uses:
/// - [grouped]  — full integer with thousands separators ("30,508"), for the
///   prominent current-flow readouts (gauge, forecast-page header, peaks).
/// - [compact]  — abbreviated ("30.5K", "1.2M"), for dense / space-constrained
///   spots (chart axes, calendar cells, timeline chips, threshold labels).
///
/// Both take a value already converted to the user's display unit; formatting
/// is unit-agnostic (callers append the unit label). This replaces the seven
/// near-identical private `_formatFlow`/`_formatFlowValue` copies that had
/// drifted across the forecast widgets.
class FlowFormat {
  const FlowFormat._();

  /// Full integer, thousands-grouped. e.g. `30508.4 -> "30,508"`.
  static String grouped(double value) {
    final s = value.round().toString();
    final buf = StringBuffer();
    for (var k = 0; k < s.length; k++) {
      if (k > 0 && (s.length - k) % 3 == 0) buf.write(',');
      buf.write(s[k]);
    }
    return buf.toString();
  }

  /// Compact abbreviation. e.g. `1250000 -> "1.2M"`, `30500 -> "30.5K"`,
  /// `430 -> "430"`, `4.2 -> "4.2"`.
  static String compact(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    } else if (value >= 100) {
      return value.toStringAsFixed(0);
    } else {
      return value.toStringAsFixed(1);
    }
  }
}
