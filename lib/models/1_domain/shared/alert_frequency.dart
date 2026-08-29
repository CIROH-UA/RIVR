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

  /// The effective default for a river the user has not set individually.
  ///
  /// **Mirrors `defaultFrequencyFor` in notification-service.ts** and must stay
  /// mirrored: the server applies its own rule regardless of what this screen
  /// shows, so a divergence means the settings screen states a frequency the
  /// user will not actually receive. Review found exactly that — every row read
  /// "Every 6 hours" while the server used "daily" for the default-configured
  /// user, because this rule did not exist on the app side at all.
  ///
  /// [legacyFrequency] is the old global 1-4 setting, which no longer decides
  /// WHEN anything is checked — only how often a user is reminded by default.
  static AlertFrequency defaultFor(int legacyFrequency) =>
      legacyFrequency == 1 ? AlertFrequency.daily : AlertFrequency.sixHourly;

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
    AlertFrequency.hourly => 'A reminder every hour while it stays flooded',
    AlertFrequency.sixHourly => 'A reminder every 6 hours while it stays flooded',
    AlertFrequency.daily => 'One reminder a day while it stays flooded',
    AlertFrequency.changeOnly =>
      'No reminders — only when it starts, worsens, or ends',
    AlertFrequency.off =>
      'No alerts for this river — unless it rises to a worse flood level',
  };

  /// Short form for the settings row.
  ///
  /// Genuinely shorter than [label], not an alias for it. `CupertinoListTile`
  /// lays `additionalInfo` out unconstrained and puts the title in an
  /// `Expanded`, so a long value eats the river's name: on an iPhone SE,
  /// "Only when it changes" left the name about one character and an ellipsis.
  String get shortLabel => switch (this) {
    AlertFrequency.hourly => 'Hourly',
    AlertFrequency.sixHourly => '6 hours',
    AlertFrequency.daily => 'Daily',
    AlertFrequency.changeOnly => 'Changes only',
    AlertFrequency.off => 'Off',
  };
}
