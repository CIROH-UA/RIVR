// lib/models/1_domain/shared/alert_frequency.dart
//
// How often a user is REMINDED while one of their rivers stays flooded.
//
// ADR 0011 decision 19. The stored values are a cross-language contract with
// `functions/src/alert-triggers.ts`: the app writes them into `alertFrequencies`
// on the user document and the server reads them back to decide whether a
// continuing event is worth another notification. A rename on either side that
// is not matched on the other silently reverts every user to the default, so
// the wire values are pinned by test.
//
// **This is not "how often we check".** The app used to offer 1-4 checks a day
// at fixed Mountain-Time slots; those functions are deleted. Alerts are now
// evaluated whenever the upstream model publishes, and the only thing a user
// still chooses is how often to be reminded about a river that is *still* high.
//
// **Nothing here can silence the first alert or an escalation** — except `off`,
// which silences the first alert but still cannot silence an escalation. That
// asymmetry is deliberate and has to be visible in the UI, because a setting
// called "Off" that still notifies would otherwise read as a bug.

/// A user's reminder preference for one river.
enum AlertFrequency {
  /// While it stays flooded, remind me every hour.
  hourly('hourly'),

  /// The default. Often enough to feel watched, rare enough to stay readable.
  sixHourly('6h'),

  /// Once a day while it lasts.
  daily('daily'),

  /// No reminders — only when it starts, worsens, or ends.
  changeOnly('change-only'),

  /// Silent, except when it gets worse. See the note at the top of this file.
  off('off');

  const AlertFrequency(this.wireValue);

  /// The exact string stored in Firestore and read by alert-triggers.ts.
  final String wireValue;

  /// The app-wide default when a user has expressed no preference for a river.
  static const AlertFrequency defaultFrequency = AlertFrequency.sixHourly;

  /// Parse a stored value, falling back to the default.
  ///
  /// Unrecognised values fall back rather than throwing: a preference written
  /// by a newer build must never stop this one from rendering a settings
  /// screen, and the fallback is the same one the server applies.
  static AlertFrequency fromWire(String? raw) {
    if (raw == null) return defaultFrequency;
    for (final f in AlertFrequency.values) {
      if (f.wireValue == raw) return f;
    }
    return defaultFrequency;
  }

  /// The row title in the picker.
  String get label => switch (this) {
    AlertFrequency.hourly => 'Every hour',
    AlertFrequency.sixHourly => 'Every 6 hours',
    AlertFrequency.daily => 'Once a day',
    AlertFrequency.changeOnly => 'Only when it changes',
    AlertFrequency.off => 'Off',
  };

  /// The one-line explanation under the title.
  ///
  /// Written as what the user will experience, not as what the system does.
  String get description => switch (this) {
    AlertFrequency.hourly => 'A reminder every hour while it stays high',
    AlertFrequency.sixHourly => 'A reminder every 6 hours while it stays high',
    AlertFrequency.daily => 'One reminder a day while it stays high',
    AlertFrequency.changeOnly =>
      'No reminders — only when it starts, worsens, or ends',
    AlertFrequency.off => 'Silent, except if this river gets worse',
  };

  /// Short form for the settings row, e.g. "Every 6 hours".
  String get shortLabel => label;
}
