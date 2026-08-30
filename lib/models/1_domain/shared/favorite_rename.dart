// lib/models/1_domain/shared/favorite_rename.dart
//
// What a favourite's rename can be undone TO, or null when there is nothing
// to undo.
//
// **Pure and separate on purpose.** This lived inline in
// `_showRenameDialog`, where the only way to test it was a widget harness for
// a page that builds a scrolling list of video-playing cards — so it was
// guarded at source level instead, and a real defect walked straight through.
//
// The defect, found on a device 2026-08-30 immediately after the GEOGLOWS
// restore shipped: the button appeared even when the custom name was ALREADY
// the default. Restoring "Pitumarca, Peru" to "Pitumarca, Peru" — a control
// that does nothing, offered as though it did something. The gate asked only
// "is there a default, and is there a custom name", never "are they
// different".
//
// It was never GEOGLOWS-specific. An NWM reach renamed to its own river name
// showed the same dead button, from the same expression, since long before
// the GEOGLOWS work.

/// The name to offer as "Restore to ...", or null for no button.
///
/// [customName] is what the user has called this river, null when they never
/// renamed it. [riverName] is the network's own name — NWM publishes one,
/// GEOGLOWS does not. [placeLabel] is the reverse-geocoded place a GEOGLOWS
/// card shows instead, resolved asynchronously and often still null.
///
/// Returns null — meaning NO button — when:
/// - there is no custom name, so there is nothing to undo;
/// - there is no default to go back to, so the button would restore nothing;
/// - the custom name already EQUALS the default, so the button would do
///   nothing. That is the case this function was extracted for.
///
/// Comparison is on trimmed values because the save path trims, so
/// `"Provo River "` and `"Provo River"` are the same name in practice and
/// offering to "restore" between them is the same dead control.
///
/// Case is NOT ignored: `"provo river"` and `"Provo River"` are genuinely
/// different names, and restoring between them changes what the user sees.
String? restoreTargetFor({
  required String? customName,
  required String? riverName,
  required String? placeLabel,
}) {
  final custom = customName?.trim();
  if (custom == null || custom.isEmpty) return null;

  final fromNetwork = riverName?.trim();
  final target = (fromNetwork != null && fromNetwork.isNotEmpty)
      ? fromNetwork
      : placeLabel?.trim();

  if (target == null || target.isEmpty) return null;
  if (target == custom) return null;

  return target;
}
