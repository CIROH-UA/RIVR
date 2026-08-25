// lib/services/4_infrastructure/river_data/store_subscription_service.dart
//
// ADR 0011 Phase 5: the read path. Favourited reaches are served from the
// cloud store instead of upstream.
//
// **This is delivery, not fetching.** The app subscribes to its favourites'
// documents with a Firestore snapshot listener and pushes whatever arrives into
// the repository via `ingest`. Everything downstream is unchanged: the entry
// lands in the shared cache carrying the server's own freshness window, so
// `RiverDataRepository.read` finds it FRESH and makes no network call. Guard 1
// falls out of the existing freshness logic rather than needing a new branch.
//
// Three properties come free from Firestore's local persistence, which is on by
// default on iOS and Android:
//   - a cold start renders from disk before any network round-trip (guard 3)
//   - with the network off, favourites still render (guard 4)
//   - a server write reaches an open app without the app asking (guard 5)
//
// **The app has no listeners today.** Lifecycle is new ground and a real leak
// and billing risk — an orphaned listener keeps billing reads forever — so
// every subscription is tracked and cancelled, and `dispose` is not optional.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// The Firestore collection the ADR 0011 store writes to.
///
/// Must match `STORE_COLLECTION` in functions/src/store-keys.ts and the rule in
/// firestore.rules. A mismatch is denied by the rules, silently, forever.
const String kStoreCollection = 'river_data';

/// Products the store actually holds, per source.
///
/// A subset of each source's `supportedProducts`: the server only writes what
/// it can fetch on a publish cycle. Subscribing to a product the store never
/// writes costs a listener that can never fire.
const Map<ForecastSource, List<ForecastProduct>> kStoredProducts = {
  ForecastSource.nwm: [
    ForecastProduct.analysisAssimilation,
    ForecastProduct.shortRange,
    ForecastProduct.mediumRange,
    ForecastProduct.longRange,
  ],
  ForecastSource.geoglows: [
    ForecastProduct.geoglowsForecast,
  ],
};

/// Firestore's ceiling for `whereIn`. Document ids are queried in batches.
const int kWhereInBatchSize = 30;

/// Subscribes to the store for a set of reaches and feeds the repository.
class StoreSubscriptionService {
  StoreSubscriptionService({
    required IRiverDataRepository repository,
    FirebaseFirestore? firestore,
  })  : _repository = repository,
        _db = firestore ?? FirebaseFirestore.instance;

  static const String _tag = 'STORE_SUB';

  final IRiverDataRepository _repository;
  final FirebaseFirestore _db;

  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _subs = [];

  /// Document ids currently subscribed, so an unchanged favourite set is a
  /// no-op rather than a teardown and re-attach (which would re-bill every
  /// document read).
  Set<String> _watched = <String>{};

  bool _disposed = false;

  /// Documents ingested since construction. Exposed for the guards.
  int ingested = 0;

  /// Documents rejected as unreadable. Exposed for the guards.
  int rejected = 0;

  /// Whether anything is currently subscribed.
  bool get isSubscribed => _subs.isNotEmpty;

  /// The document ids currently watched.
  Set<String> get watchedIds => Set.unmodifiable(_watched);

  /// Every document id the store could hold for [reaches].
  static Set<String> documentIdsFor(Iterable<RiverDataKey> reaches) {
    final ids = <String>{};
    for (final r in reaches) {
      for (final p in kStoredProducts[r.source] ?? const <ForecastProduct>[]) {
        ids.add(
          RiverDataKey(source: r.source, reachId: r.reachId, product: p)
              .storageKey,
        );
      }
    }
    return ids;
  }

  /// Point the subscription at exactly [reaches].
  ///
  /// Safe to call whenever favourites change. An unchanged set does nothing —
  /// re-attaching would re-read every document and bill for it.
  ///
  /// [reaches] carries source + reachId; the product on each key is ignored,
  /// because the service subscribes to every product the store holds.
  Future<void> syncFavourites(Iterable<RiverDataKey> reaches) async {
    if (_disposed) return;

    final wanted = documentIdsFor(reaches);
    if (_setEquals(wanted, _watched)) return;

    await _cancelAll();
    _watched = wanted;

    if (wanted.isEmpty) {
      AppLogger.info(_tag, 'no favourites; nothing subscribed');
      return;
    }

    final ids = wanted.toList();
    for (var i = 0; i < ids.length; i += kWhereInBatchSize) {
      final batch = ids.sublist(
        i,
        i + kWhereInBatchSize > ids.length ? ids.length : i + kWhereInBatchSize,
      );
      _subs.add(
        _db
            .collection(kStoreCollection)
            .where(FieldPath.documentId, whereIn: batch)
            .snapshots()
            .listen(
              _onSnapshot,
              // A permission error or a missing index must degrade to the live
              // path, not surface to the user (guard 8). The repository still
              // fetches upstream on a cache miss.
              onError: (Object e, StackTrace s) => AppLogger.error(
                _tag,
                'store listener failed; falling back to the live path',
                e,
              ),
            ),
      );
    }
    AppLogger.info(
      _tag,
      'subscribed to ${wanted.length} documents in ${_subs.length} listener(s)',
    );
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;
      final entry = decodeDocument(change.doc.id, change.doc.data());
      if (entry == null) {
        rejected++;
        continue;
      }
      ingested++;
      // Fire and forget: ingest only writes the shared cache, and awaiting it
      // inside a snapshot callback would serialise delivery behind disk I/O.
      unawaited(
        _repository.ingest(entry).catchError(
          (Object e) => AppLogger.error(_tag, 'ingest failed for ${change.doc.id}', e),
        ),
      );
    }
  }

  /// Turn a stored document into an entry, or null when it cannot be trusted.
  ///
  /// Returns null rather than throwing for every failure mode. A bad document
  /// must cost that one product its store delivery and nothing else — the
  /// repository then falls through to the live path, which is guard 8.
  static RiverDataEntry? decodeDocument(
    String documentId,
    Map<String, dynamic>? data,
  ) {
    if (data == null) return null;
    try {
      // Guard 10 / ADR decision 14: an unrecognised schema is DISCARDED, never
      // parsed. A future server writing v2 must not be decoded by a v1 client
      // guessing at the shape.
      final schema = data['schema'];
      if (schema is! int || schema != RiverDataEntry.schemaVersion) {
        AppLogger.warning(
          _tag,
          'discarding $documentId: schema $schema != ${RiverDataEntry.schemaVersion}',
        );
        return null;
      }
      final entry = RiverDataEntry.fromJson(data);

      // The document id IS the cache key. If they disagree the server and
      // client have drifted, and ingesting would file the payload under the
      // wrong reach — worse than not ingesting at all.
      if (entry.key.storageKey != documentId) {
        AppLogger.warning(
          _tag,
          'discarding $documentId: contents say ${entry.key.storageKey}',
        );
        return null;
      }
      return entry;
    } catch (e) {
      AppLogger.warning(_tag, 'discarding unreadable document $documentId: $e');
      return null;
    }
  }

  Future<void> _cancelAll() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Detach every listener (guard 6). Idempotent.
  Future<void> dispose() async {
    _disposed = true;
    await _cancelAll();
    _watched = <String>{};
    AppLogger.info(_tag, 'disposed; all listeners detached');
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
