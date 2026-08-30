// test/services/4_infrastructure/map/location_camera_test.dart
//
// Where the map puts the camera when it goes to the user, and what it draws
// when it gets there.
//
// **Source-level guards, and they say so.** `MapControlsService` talks to a
// live `MapboxMap` through a platform channel; there is no fake for it and no
// map test harness in this repo. What these pin is the two numbers and the
// two flags that carry the decision — which is what would be quietly changed
// back, and which no other test touches.
//
// The zoom is not a taste question, which is why it is pinned:
// `byu-hydroinformatics.nwm-channels-v3` is tiled **z0-12**, confirmed from
// its Mapbox metadata. Above 12 there is no more stream data at all — Mapbox
// stretches the z12 tile, so lines thicken and no new stream appears. Zoom 14
// showed ~1.6 km of ground on a Pro Max against ~6.4 km at zoom 12, so it
// discarded three quarters of the visible area and bought nothing. Reported
// by Jerson 2026-08-30: "streams are not visible at that level usually."

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source with `//` and `///` comment lines removed.
///
/// Every claim below appears in prose in the same files — a guard a comment
/// can satisfy is not a guard, learned repeatedly on 2026-08-30.
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  const controls = 'lib/services/4_infrastructure/map/map_controls_service.dart';
  const page = 'lib/ui/2_presentation/features/map/pages/map_page.dart';

  group('the camera stops where the stream data stops', () {
    test('the location zoom is 12, the tileset maximum', () {
      final src = _code(controls);

      expect(src.contains('_defaultZoom = 12.0'), isTrue,
          reason: 'the stream tileset is z0-12; a higher zoom stretches the '
              'z12 tile and shows no additional stream, while cutting the '
              'visible area');
      expect(src.contains('_defaultZoom = 14.0'), isFalse,
          reason: 'zoom 14 is the value this replaced');
    });

    test('the zoom is not above the tileset maximum', () {
      // Stated as a bound rather than an equality, so an edit to 13 or 15 —
      // both still overzoomed — fails for the right reason.
      final src = _code(controls);
      final m = RegExp(r'_defaultZoom = (\d+(?:\.\d+)?)').firstMatch(src);
      expect(m, isNotNull, reason: '_defaultZoom is gone or renamed');

      expect(double.parse(m!.group(1)!), lessThanOrEqualTo(12.0),
          reason: 'nwm-channels-v3 is tiled to z12; anything beyond it is '
              'stretched pixels');
    });
  });

  group('the map says where the user is, and how sure it is', () {
    test('the location puck is enabled with its accuracy ring', () {
      final src = _code(controls);

      expect(src.contains('enabled: true'), isTrue,
          reason: 'LocationComponentSettings.enabled defaults to FALSE, which '
              'is why the map drew no marker at all — it flew to the user and '
              'left the centre of the screen as the only clue');
      expect(src.contains('showAccuracyRing: true'), isTrue,
          reason: 'the ring IS the feature: without it a vague fix looks '
              'exactly like a precise one, and the map implies a precision it '
              'does not have');
    });

    test('the puck is re-applied on every style load, not just the first', () {
      // Changing the basemap rebuilds the style and takes the location
      // component with it, so a puck enabled once vanishes the first time
      // someone switches to satellite.
      final src = _code(page);
      final styleHook = RegExp(
        r'_loadLayersAfterStyleReady\(\) async \{[\s\S]{0,1200}?enableLocationPuck\(\)',
      );

      expect(styleHook.hasMatch(src), isTrue,
          reason: 'the puck must be re-enabled where the style is (re)loaded');
    });
  });

  group('the camera moves on the first open only', () {
    test('centring is gated on a flag', () {
      final src = _code(page);

      expect(src.contains('_hasCenteredOnUser'), isTrue,
          reason: 'recentring on every open takes the user away from wherever '
              'they panned to, which the puck now makes unnecessary');
    });

    test('the flag is STATIC, or "first open" means nothing', () {
      // _MapPageState is recreated every time the map tab is opened, so an
      // instance field would be false again on the second open and the camera
      // would jump — exactly the behaviour being removed. This is the whole
      // correctness of the feature.
      final src = _code(page);

      expect(src.contains('static bool _hasCenteredOnUser'), isTrue,
          reason: 'an instance field resets on every open, so the gate would '
              'never gate anything');
    });

    test('the location is still requested every open', () {
      // Only the camera move is first-open-only. The puck needs a fix to
      // draw, and initializeLocation is what prompts for permission — so
      // gating the REQUEST would leave later opens with no blue dot.
      final src = _code(page);

      expect(src.contains('initializeLocation()'), isTrue);
      final gateBeforeRequest = RegExp(
        r'if \(!_hasCenteredOnUser\)[\s\S]{0,200}?initializeLocation\(\)',
      );
      expect(gateBeforeRequest.hasMatch(src), isFalse,
          reason: 'the flag must gate the camera move, not the location '
              'request — otherwise the puck has nothing to draw on a second '
              'open');
    });
  });
}
