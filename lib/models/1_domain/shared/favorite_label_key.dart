// lib/models/1_domain/shared/favorite_label_key.dart
//
// The key under which a favourite's display label is stored on the user
// document, so a Cloud Function can name a river the way the app does.
//
// **Keyed by SOURCE AND REACH, not reach alone.** `favoriteLabels` was
// originally keyed by `reachId` by itself, and the weekly-digest code recorded
// the consequence as an accepted limit: an NWM COMID and a GEOGLOWS LINKNO that
// happen to be numerically equal share one slot, so one river's label silently
// overwrites the other's. Both id spaces are plain integers with no
// coordination between them, so a collision is a matter of time rather than
// bad luck. Fixed 2026-08-30 rather than carried forward, because this is now
// what a flood notification puts in its title.
//
// **This is a cross-language contract.** The app writes these keys and
// `functions/src/notification-service.ts` and `weekly-digest.ts` read them, so
// the format must match `reachKey()` there exactly. A test pins both sides.

import 'package:rivr/models/1_domain/shared/forecast_source.dart';

/// The `favoriteLabels` key for one favourite.
///
/// Must match `reachKey(source, reachId)` in
/// `functions/src/notification-service.ts` — `<source>:<reachId>`.
String favoriteLabelKey(ForecastSource source, String reachId) =>
    '${source.id}:$reachId';

/// Read a label, tolerating entries written before the key carried a source.
///
/// Labels written before 2026-08-30 are keyed by the bare reach id. They are
/// not migrated: a user's next rename or Weekly Outlook visit writes the new
/// key, and until then the old value is still the right label for the common
/// case of a reach id that exists on only one network. Reading both means
/// nobody's label disappears on upgrade.
///
/// The server does the same, for the same reason.
String? labelFor(
  Map<String, String> labels,
  ForecastSource source,
  String reachId,
) {
  return labels[favoriteLabelKey(source, reachId)] ?? labels[reachId];
}
