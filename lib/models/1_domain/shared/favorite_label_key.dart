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

// A Dart reader was written here and deleted: the app never READS these
// labels. It renders from the favourite's own `customName`, which is the
// source of truth on device; `favoriteLabels` exists solely so the SERVER can
// name a river the way the app does. The reader was dead code whose doc
// comment described a fallback the app does not perform — and would have read
// as live to the next person. The server's own `labelFor` in
// notification-service.ts does that job, and is tested there.

/// The `favoriteLabels` map to write for a rename, or null when there is
/// nothing to write.
///
/// Pure, so the decision is testable without a widget, a signed-in user or
/// Firestore. The rename sync had no test at all when it shipped — the headline
/// behaviour of the whole change — which is what pulling it out of the page
/// fixes.
///
/// Returns null rather than an unchanged map for the two cases that must NOT
/// produce a write: a blank label, and a label already stored. A no-op write
/// here would cost a Firestore round trip on every rename dialog dismissal.
///
/// The merge is deliberate: labels for rivers not being renamed must survive,
/// including entries under the pre-2026-08-30 bare-reachId key, which the
/// server still reads.
Map<String, String>? labelsAfterRename({
  required Map<String, String> existing,
  required ForecastSource source,
  required String reachId,
  required String label,
}) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return null;

  final key = favoriteLabelKey(source, reachId);
  if (existing[key] == trimmed) return null;

  return {...existing, key: trimmed};
}
