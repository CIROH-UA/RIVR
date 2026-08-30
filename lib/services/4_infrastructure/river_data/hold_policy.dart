// lib/services/4_infrastructure/river_data/hold_policy.dart
//
// ADR 0011 Phase 7, guards 3 and 4 — the two questions the client asks about
// a value's age.
//
//   maxHold     how long ago did we FETCH this?      (guard 3)
//   maxRunAge   how old is the WATER we fetched?     (guard 4)
//
// Both mirror the server. The second was added last and matters most: a store
// refreshing punctually while carrying yesterday's forecast passes the first
// and fails the second, and that is the shape of the incident this phase came
// from.
//
// **The problem this closes.** A stored document's `validUntil` is not fixed:
// when a refresher run finds that upstream has not published anything new, it
// extends the window rather than letting a still-correct value expire. That is
// right — the value really is the newest that exists — but it means
// `validUntil` alone can say "fresh" for a long time about a document nobody
// has refetched. `fetchedAt`, deliberately, is never moved by an extension, so
// it is the honest record of how long ago this water was actually pulled from
// upstream.
//
// The review of Phase 7 found the consequence: a store frozen past its cycle
// serves held documents as in-window for up to two days, and the device shows
// them with no indicator at all — the exact scenario guard 3 names, on the
// phase whose entire promise is that silence means current.
//
// **These numbers are the server's, not a second opinion.** They mirror
// `MAX_HOLD_MS` in `functions/src/store-window.ts` — the store's answer to
// "how long can upstream be quiet before silence stops meaning 'nothing
// changed' and starts meaning 'something is broken'". Past this point the
// SERVER stops extending the document and lets it expire; the client should
// stop vouching for it at the same instant, not at some number of its own.
//
// The server stops extending a document at this point and the client stops
// vouching for it at the same instant — literally the same, since
// `planWindowExtensions` clamps its last extension to `fetchedAt + maxHold`.
// It did not always: the extension used to promise a full refresh interval
// past the cap, so the client warned for up to that long about the newest data
// in existence. Fixed after the third review.
//
// Those shared constants are what make guard 4 true rather than asserted. An
// earlier version of this phase CLAIMED the two sides shared a number while
// `MAX_HOLD_MS` existed only in TypeScript — the only occurrence of the name
// anywhere in `lib/` was the comment saying it was shared. A drift test
// (`functions/src/hold-policy-drift.test.ts`) now reads this file off disk and
// fails if the two ever disagree, the same way the flood-category ladder is
// pinned across the two languages.

import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';

/// How long a product's value may be held on re-verification alone.
///
/// MUST equal `MAX_HOLD_MS` in `functions/src/store-window.ts`. Pinned by a
/// drift test that reads this file; changing one side alone fails CI.
const Map<ForecastProduct, Duration> maxHold = {
  ForecastProduct.analysisAssimilation: Duration(hours: 6),
  ForecastProduct.shortRange: Duration(hours: 6),
  ForecastProduct.mediumRange: Duration(hours: 18),
  ForecastProduct.longRange: Duration(hours: 36),
  ForecastProduct.geoglowsForecast: Duration(hours: 48),

  // The near-static products. No refresh cycle at all: a 30-day window,
  // rewritten only when missing or nearly expired, so a healthy document sits
  // untouched for around 23 days. Judging them by the short default reported a
  // perfectly healthy store as DOWN within a minute of the server-side check
  // reaching production on 2026-08-29.
  ForecastProduct.reachMetadata: Duration(days: 32),
  ForecastProduct.returnPeriods: Duration(days: 32),
};

/// The default for a product not named above.
///
/// Deliberately short: a product nobody has thought about should fail towards
/// "check again", never towards "hold forever".
const Duration defaultMaxHold = Duration(hours: 6);

/// How long [product] may be held without upstream confirming a new run.
Duration maxHoldFor(ForecastProduct product) =>
    maxHold[product] ?? defaultMaxHold;

/// How old the RUN ITSELF may be, per product.
///
/// **A different question from [maxHold], and the one that catches the
/// incident this whole phase came from.** `maxHold` asks how long ago we last
/// wrote; this asks how old the water is that we wrote. A store refreshing
/// perfectly on schedule can carry yesterday's forecast forever and look
/// flawless by the first measure — which is exactly what GEOGLOWS did every
/// day until 2026-08-29, while every freshness check the app had said fine.
///
/// The client had no notion of this at all until now. The server alarmed and
/// the phone stayed silent, which meant guard 4 — "the indicator is driven by
/// the same signal that alarms operationally" — was true only for the weaker
/// of the server's two signals, and false for the one that matters.
///
/// MUST equal `MAX_RUN_AGE_MS` in `functions/src/store-window.ts`. Pinned by
/// the same drift test. Products absent here are NOT judged: the near-static
/// products carry no run identity, and defaulting them is how the hold cap
/// reported a healthy store as down within a minute of reaching production.
const Map<ForecastProduct, Duration> maxRunAge = {
  ForecastProduct.analysisAssimilation: Duration(hours: 16),
  ForecastProduct.shortRange: Duration(hours: 16),
  ForecastProduct.mediumRange: Duration(hours: 24),
  ForecastProduct.longRange: Duration(hours: 36),
  ForecastProduct.geoglowsForecast: Duration(hours: 42),
};

/// How old [product]'s run may be, or null when it is not judged.
Duration? maxRunAgeFor(ForecastProduct product) => maxRunAge[product];

/// The instant a run identity refers to, or null when it carries none.
///
/// Mirrors `parseRunInstant` on the server, including the pipe-joined form and
/// its choice of the OLDEST segment: a payload spanning several runs is only
/// as fresh as the oldest water in it, and the server orders these the same
/// way.
DateTime? runInstant(String? runId) {
  if (runId == null || runId.isEmpty) return null;
  DateTime? oldest;
  for (final part in runId.split('|')) {
    final t = DateTime.tryParse(part.trim());
    if (t == null) continue;
    if (oldest == null || t.isBefore(oldest)) oldest = t;
  }
  return oldest?.toUtc();
}

/// Whether the run a value came from is older than its product allows.
///
/// False when the product is not judged, or the run cannot be read — never
/// guess. An unreadable run is not evidence of staleness.
bool runTooOld({
  required ForecastProduct product,
  required String? runId,
  required DateTime now,
}) {
  final cap = maxRunAgeFor(product);
  if (cap == null) return false;
  final at = runInstant(runId);
  if (at == null) return false;
  return now.toUtc().difference(at) > cap;
}

/// Whether a value fetched at [fetchedAt] has been held longer than its
/// product allows.
///
/// This is a stronger question than `FreshnessWindow.isFreshAt`, and the two
/// disagree exactly in the case that matters: a document whose window keeps
/// being extended reads as fresh indefinitely, while this goes true once the
/// water itself is older than the server would still stand behind.
bool heldTooLong({
  required ForecastProduct product,
  required DateTime fetchedAt,
  required DateTime now,
}) =>
    now.toUtc().difference(fetchedAt.toUtc()) > maxHoldFor(product);
