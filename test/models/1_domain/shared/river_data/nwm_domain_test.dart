// test/models/1_domain/shared/river_data/nwm_domain_test.dart
//
// ADR 0011 Phase 9. Pure boundary logic behind a freshness window, which is
// exactly the shape of thing that gets an off-by-one and is never noticed:
// a misclassified reach does not crash, it just expires on the wrong schedule.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/river_data/nwm_domain.dart';
import 'package:rivr/services/4_infrastructure/river_data/hold_policy.dart';

void main() {
  group('nwmDomainOf', () {
    test('the White River reach used for device testing is CONUS', () {
      expect(nwmDomainOf('23021904'), NwmDomain.conus);
    });

    test('the measured Oahu reach is an island reach', () {
      // 800000010 — lat 21.495, lon -158.113, and NWPS reports only
      // analysis_assimilation and short_range for it.
      expect(nwmDomainOf('800000010'), NwmDomain.island);
    });

    test('both band edges are INCLUSIVE', () {
      expect(nwmDomainOf('$islandComidMin'), NwmDomain.island);
      expect(nwmDomainOf('$islandComidMax'), NwmDomain.island);
      expect(nwmDomainOf('${islandComidMin - 1}'), NwmDomain.conus);
      expect(nwmDomainOf('${islandComidMax + 1}'), NwmDomain.conus);
    });

    test('an unparseable id falls back to CONUS, the SAFE direction', () {
      // CONUS has the shortest windows, so a misclassification here costs an
      // extra refetch. Defaulting the other way would hold an island window
      // over a CONUS reach and show someone a six-hour-old river.
      for (final id in ['', 'abc', '760337-geoglows', '12.5']) {
        expect(nwmDomainOf(id), NwmDomain.conus, reason: 'id "$id"');
      }
    });

    test('a GEOGLOWS-style numeric id is not accidentally an island', () {
      // GEOGLOWS river ids are 9 digits and could collide with the band by
      // coincidence. They never reach this function — NwmDataSource is only
      // asked about NWM reaches — but the value is worth stating: this band
      // is an NHDPlus COMID range, not a general-purpose test.
      expect(nwmDomainOf('760337'), NwmDomain.conus);
    });
  });

  test('the island tables cannot reach a GEOGLOWS product', () {
    // A near-miss found while verifying the deploy on 2026-08-30. GEOGLOWS
    // river ids are also 9 digits and nothing stops one landing inside the
    // NWM island COMID band — `nwmDomainOf` reads the number, not the
    // network. None of the reaches in the store today collide, but that is
    // luck rather than design.
    //
    // What makes it safe is that the island cap tables name ONLY
    // `shortRange`, which GEOGLOWS does not have. Adding `geoglowsForecast`
    // to either would silently give an island-band GEOGLOWS reach an NWM
    // island cap, so this fails first.
    for (final table in [islandMaxHold, islandMaxRunAge]) {
      for (final product in table.keys) {
        expect(
          product.id.toLowerCase().contains('geoglows'),
          isFalse,
          reason: '$product is a GEOGLOWS product with an NWM island cap',
        );
      }
    }
  });

  test('the island cycle is the FASTER of the two island domains', () {
    // Hawaii publishes 12-hourly and Puerto Rico 6-hourly, and one COMID band
    // covers both. Choosing 12 would hold a Puerto Rico forecast for six hours
    // after a newer run existed. This test exists so that trade is a decision
    // rather than a number someone tunes upward for efficiency.
    expect(islandShortRangeCycleHours, 6);
    expect(
      24 % islandShortRangeCycleHours,
      0,
      reason: 'PublishSchedule.nextCycle requires a divisor of 24',
    );
  });
}
