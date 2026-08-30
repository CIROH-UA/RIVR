// lib/models/1_domain/shared/location_denial.dart
//
// Why the map could not find the user, and what to tell them about it.
//
// **This exists because the recentre button was a silent dead end.** With
// location refused, tapping it did nothing at all: no message, no prompt, no
// route to Settings. The service logged an error and returned. The streams
// button beside it has shown a "No Streams Visible" dialog for the same
// situation since long before — so the pattern existed in the same file and
// this one did not use it. Found by Jerson asking "what happens if location is
// not granted?", not by a test.
//
// Pure and separate so the MESSAGE is testable. The permission check itself
// talks to Geolocator's statics and a live Mapbox map, which is exactly the
// excuse that let a dead button survive unnoticed.

/// Why no position was available.
enum LocationDenial {
  /// Location services are switched off for the whole device.
  serviceDisabled,

  /// This app was refused, but may ask again.
  denied,

  /// Refused permanently — iOS will not show the prompt again, so only
  /// Settings can change it.
  deniedForever,

  /// Permission is fine; the device simply has no fix yet (indoors, no
  /// signal, or the 10-second limit elapsed).
  noFix,
}

/// What to show the user for a given [denial].
///
/// [openSettings] is false for [LocationDenial.noFix] — there is nothing to
/// change there, and offering Settings for a problem Settings cannot fix
/// sends people on an errand and teaches them the button lies.
///
/// It is also false for [LocationDenial.denied] on purpose: that state can
/// still be resolved by the system prompt, which the next tap triggers. Only
/// [LocationDenial.deniedForever] and [LocationDenial.serviceDisabled] truly
/// require Settings.
({String title, String body, bool openSettings}) locationDenialMessage(
  LocationDenial denial,
) {
  switch (denial) {
    case LocationDenial.serviceDisabled:
      return (
        title: 'Location Services Are Off',
        body: 'Turn on Location Services to centre the map on where you are.',
        openSettings: true,
      );
    case LocationDenial.deniedForever:
      return (
        title: 'Location Access Needed',
        body: 'RIVR needs location access to centre the map on you. '
            'You can turn it on in Settings.',
        openSettings: true,
      );
    case LocationDenial.denied:
      return (
        title: 'Location Access Needed',
        body: 'RIVR needs location access to centre the map on you.',
        openSettings: false,
      );
    case LocationDenial.noFix:
      return (
        title: 'Can\'t Find Your Location',
        body: 'Your device could not get a location right now. '
            'This is usually better outdoors or with a clearer view of the sky.',
        openSettings: false,
      );
  }
}
