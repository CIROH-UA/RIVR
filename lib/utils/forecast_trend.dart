// lib/utils/forecast_trend.dart

/// Direction a river's flow is heading across a forecast window — the "↗ rising"
/// / "→ steady" / "↘ falling" chip on the weekly outlook.
enum FlowTrend {
  rising,
  falling,
  steady;

  bool get isRising => this == FlowTrend.rising;
  bool get isFalling => this == FlowTrend.falling;
  bool get isSteady => this == FlowTrend.steady;
}

/// Flows within ±5% of the current reading read as steady noise; beyond that is
/// a real trend. Kept identical to the forecast detail page's stat-card trend so
/// the two never disagree (see [computeFlowTrend]).
const double _trendThreshold = 0.05;

/// Classify the forward-looking trend of an ordered (earliest-first, current
/// reading FIRST) flow series — the same rule the forecast detail page's "Trend"
/// stat uses, so the weekly outlook and the detail page always agree:
///
///   - **Rising** when a genuine crest lies ahead — the peak (max upcoming) is
///     more than 5% above the current reading.
///   - **Falling** when the flow eases — the end of the window is more than 5%
///     below the current reading (and no crest ahead).
///   - **Steady** otherwise.
///
/// Because it's peak-anchored, a river that rises to a midweek crest then
/// recedes still reads as Rising (the crest is the story), matching the detail
/// page's "Rising · peaks in N days". Fewer than two points is [FlowTrend.steady].
FlowTrend computeFlowTrend(List<double> flows) {
  if (flows.length < 2) return FlowTrend.steady;

  final current = flows.first;
  final last = flows.last;
  var peak = flows.first;
  for (final v in flows) {
    if (v > peak) peak = v;
  }

  if (current <= 0) return peak > 0 ? FlowTrend.rising : FlowTrend.steady;

  if (peak > current * (1 + _trendThreshold)) return FlowTrend.rising;
  if (last < current * (1 - _trendThreshold)) return FlowTrend.falling;
  return FlowTrend.steady;
}
