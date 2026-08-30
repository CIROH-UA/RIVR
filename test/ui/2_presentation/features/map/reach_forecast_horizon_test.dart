// test/ui/2_presentation/features/map/reach_forecast_horizon_test.dart
//
// ADR 0011 Phase 9. The reach sheet tells someone how far ahead the colour on
// the map is looking, and it is not the same answer everywhere: GEOGLOWS
// publishes 15 days, NOAA 5 across CONUS, and only 48 hours for Hawaii and
// Puerto Rico.
//
// **This logic had no test at all.** The two tests that mentioned a forecast
// horizon passed the finished string in as a parameter, so the widget that
// DISPLAYS it was covered and the code that CHOOSES it never was. Found by
// auditing Phase 9's own change rather than by review — the same shape as
// every other defect in this ADR, which is that the wiring is untested while
// the function is green.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart';

void main() {
  String horizon(ForecastSource source, String reachId) =>
      ReachDetailsBottomSheet.forecastHorizonFor(
        source: source,
        reachId: reachId,
      );

  test('GEOGLOWS looks 15 days ahead, whatever the reach id', () {
    // Including an id that falls inside the NWM island COMID band: the band
    // is an NHDPlus range and says nothing about a GEOGLOWS river.
    expect(horizon(ForecastSource.geoglows, '760337'), 'Next 15 days');
    expect(horizon(ForecastSource.geoglows, '800000010'), 'Next 15 days');
  });

  test('a CONUS reach looks 5 days ahead', () {
    expect(horizon(ForecastSource.nwm, '23021904'), 'Next 5 days');
  });

  test('Hawaii and Puerto Rico get 48 hours, because that is all NOAA has', () {
    // 800000010 is the Oahu reach whose NWPS response was measured on
    // 2026-08-30: it serves analysis_assimilation and short_range only, with
    // a 48-hour short-range horizon.
    expect(horizon(ForecastSource.nwm, '800000010'), 'Next 48 hours');
  });

  test('the band edges are the shared ones, not a second copy', () {
    // The regression this file exists for. This logic used to carry its own
    // literals for 800000000/921999999 while a comment elsewhere claimed the
    // definition was shared. If someone reintroduces a local copy and the
    // shared constants later move, this fails.
    expect(horizon(ForecastSource.nwm, '799999999'), 'Next 5 days');
    expect(horizon(ForecastSource.nwm, '800000000'), 'Next 48 hours');
    expect(horizon(ForecastSource.nwm, '921999999'), 'Next 48 hours');
    expect(horizon(ForecastSource.nwm, '922000000'), 'Next 5 days');
  });

  test('an unreadable reach id gets the CONUS answer, not a crash', () {
    expect(horizon(ForecastSource.nwm, ''), 'Next 5 days');
    expect(horizon(ForecastSource.nwm, 'not-a-number'), 'Next 5 days');
  });
}
