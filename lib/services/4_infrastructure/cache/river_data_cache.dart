// lib/services/4_infrastructure/cache/river_data_cache.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Two-tier implementation of [IRiverDataCache]: an in-memory map for instant
/// fan-out plus one JSON file per key on disk to survive restarts. One file per
/// key at `<appCache>/rivr_river_data_cache/<storageKey>.v<schema>.json`.
///
/// ## Retention (ADR 0011 Phase 2)
///
/// Before this phase nothing pruned the store — `evict()`/`clear()` existed and
/// nothing called them, so browsing left one file set per reach forever.
///
/// - **Retention is keyed on run supersession, not wall-clock.** An entry is
///   replaced when a newer fetch for its key lands (same filename, overwritten)
///   and is otherwise kept regardless of age — an old entry whose upstream run
///   has not advanced is still the current data. There is deliberately no
///   time-based deletion.
/// - **Bounded by an LRU cap on non-pinned reaches.** [maxNonPinnedReaches]
///   counts *reaches* (all products of a reach live and die together), ordered
///   by last access — memory-tracked, falling back to file mtime across
///   restarts. Enforced after every write.
/// - **Pinned reaches (favourites) are never evicted by the cap.** The
///   favourites provider pushes the pinned set via [setPinnedReaches] whenever
///   membership changes.
/// - **Unrecognised schema versions are discarded, not parsed.** The version is
///   part of the filename, so the once-per-upgrade sweep in [initialize] is a
///   directory listing that deletes foreign files — including pre-Phase-2
///   entries, which carried no version at all.
///
/// The cache directory is injectable ([cacheDirProvider]) so tests can point at
/// a temp dir without the `path_provider` platform channel.
class RiverDataCache implements IRiverDataCache {
  RiverDataCache({
    Future<Directory> Function()? cacheDirProvider,
    this.maxNonPinnedReaches = 50,
  }) : _cacheDirProvider = cacheDirProvider ?? _defaultCacheDir;

  static const String _cacheDirName = 'rivr_river_data_cache';
  static const String _tag = 'RIVER_DATA_CACHE';

  /// Filename suffix carrying the schema version, e.g. `.v1.json`.
  static const String _fileSuffix = '.v${RiverDataEntry.schemaVersion}.json';

  /// Where the pinned set is persisted. Deliberately NOT entry-versioned: the
  /// format is a bare JSON list of reach ids and survives entry-schema bumps —
  /// the sweep skips it by name. (Round 2 caught the previous name embedding
  /// the ENTRY version, so the very upgrade the file claimed to survive
  /// deleted it.) `pins.json` does not end with the entry suffix, so the
  /// group parser rejects it at its FIRST check — round 7 instrumented both
  /// branches to settle which line does the work. The parser's later `__`
  /// check is structural (it locates the group separator for the substring)
  /// and additionally rejects any suffix-carrying name with no group, a case
  /// no current filename produces — defensive, labelled per the ADR.
  static const String _pinsFileName = 'pins.json';

  /// How many non-pinned reaches the store may hold before the least-recently
  /// used are evicted. Reaches, not files: a reach's products are one unit.
  final int maxNonPinnedReaches;

  final Future<Directory> Function() _cacheDirProvider;
  Directory? _dir;

  final Map<String, RiverDataEntry> _memory = {};
  final Map<String, _CacheNotifier> _notifiers = {};

  /// Observer-map entries, for the bounded-cache guard. Round 3 found the
  /// files bounded and this map growing one entry per browsed key forever.
  @visibleForTesting
  int get notifierCountForTesting => _notifiers.length;

  /// Recency-map entries — round 4 found this sibling of the notifier map
  /// with the same growth shape, fixed and unguarded.
  @visibleForTesting
  int get lastAccessCountForTesting => _lastAccess.length;

  /// The pins currently in force. Test-only.
  @visibleForTesting
  Set<String> get pinnedReachesForTesting => _pinnedReaches;

  /// The pins filename, pinned by a test to stay entry-version-free.
  @visibleForTesting
  static String get pinsFileNameForTesting => _pinsFileName;

  /// Reach ids that must never be cap-evicted (the user's favourites).
  ///
  /// PERSISTED, not memory-only. Review round 1 proved the memory-only version
  /// evicted a favourite on every cold start: pins arrive only after the
  /// Firestore favourites load, and the first `put` — a map tap, a
  /// notification, a background refresh — enforced the cap against an
  /// all-unpinned world and deleted last session's favourite from disk.
  Set<String> _pinnedReaches = const {};

  /// Whether [setPinnedReaches] has been called this session. Until it has,
  /// [_init] seeds the set from the persisted file, so the cap never runs
  /// against an emptier pin set than the last session declared.
  bool _pinsDeclaredThisSession = false;

  /// Last access per reach group (`source__reachId`), the LRU order. Updated on
  /// every get/put; groups unseen since launch fall back to file mtime.
  final Map<String, DateTime> _lastAccess = {};

  /// Stat syscalls issued by the cap's mtime fallback — each disk group should
  /// cost exactly one for the whole session. Test-only observability.
  @visibleForTesting
  int statCallsForTesting = 0;

  /// Cached so init runs at most once even under concurrent first calls.
  Future<void>? _initFuture;

  /// Serialises clear() and the pin persist against each other. Without it, a
  /// fire-and-forget sign-out clear() could race the next account's
  /// setPinnedReaches: the recursive directory delete swallowed the new pins
  /// file, silently re-opening the cold-start eviction gap the pins file
  /// exists to close. Round 2 probed exactly that interleaving.
  Future<void> _serialDiskOp = Future<void>.value();

  Future<void> _serialised(Future<void> Function() op) {
    final next = _serialDiskOp.then((_) => op());
    // Defensive, and labelled as such: every op in the chain catches its own
    // I/O errors, so no test can drive a throw here. If one ever escaped, an
    // unprotected chain would silently skip every later disk write for the
    // session — this repo's least favourite failure shape.
    _serialDiskOp = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  static Future<Directory> _defaultCacheDir() async {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}/$_cacheDirName');
  }

  @override
  Future<void> initialize() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final dir = await _cacheDirProvider();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
      await _discardUnrecognisedSchemas(dir);
      await _loadPersistedPins(dir);
      AppLogger.info(_tag, 'Initialized at ${dir.path}');
    } catch (e) {
      // Disk unavailable (e.g. in tests) — the cache still works in memory.
      AppLogger.error(_tag, 'Error initializing', e);
    }
  }

  /// Delete every file whose name does not carry the current schema suffix —
  /// entries written by other app versions, including pre-versioning ones.
  /// Parsing them instead is how an upgrade feeds an old shape to a new codec.
  Future<void> _discardUnrecognisedSchemas(Directory dir) async {
    var discarded = 0;
    await for (final f in dir.list()) {
      if (f is! File) continue;
      if (f.uri.pathSegments.last == _pinsFileName) continue;
      if (f.path.endsWith(_fileSuffix)) continue;
      try {
        await f.delete();
        discarded++;
      } catch (e) {
        AppLogger.error(_tag, 'Error discarding ${f.path}', e);
      }
    }
    if (discarded > 0) {
      AppLogger.info(_tag, 'Discarded $discarded unrecognised-schema entries');
    }
  }

  @override
  bool get isReady => _dir != null;

  Future<void> _ensureInitialized() => initialize();

  File _fileFor(RiverDataKey key) =>
      File('${_dir!.path}/${key.storageKey}$_fileSuffix');

  /// `source__reachId` — the unit retention operates on.
  static String _groupOf(RiverDataKey key) => '${key.source.id}__${key.reachId}';

  static String? _groupOfFileName(String name) {
    if (!name.endsWith(_fileSuffix)) return null;
    final storageKey = name.substring(0, name.length - _fileSuffix.length);
    final lastSep = storageKey.lastIndexOf('__');
    if (lastSep <= 0) return null;
    return storageKey.substring(0, lastSep);
  }

  void _touch(RiverDataKey key) {
    _lastAccess[_groupOf(key)] = DateTime.now().toUtc();
  }

  @override
  void setPinnedReaches(Set<String> reachIds) {
    _pinnedReaches = Set.unmodifiable(reachIds);
    _pinsDeclaredThisSession = true;
    unawaited(_persistPins());
  }

  Future<void> _persistPins() => _serialised(() async {
        await _ensureInitialized();
        if (_dir == null) return;
        try {
          // Temp + rename: writeAsString is not atomic, and a truncated pins
          // file degrades silently to "no pins" for exactly one cold start —
          // the file's whole reason to exist. Rename within a directory is
          // atomic on the platforms Flutter targets. Defensive and labelled
          // per the ADR: no test can drive a mid-write truncation.
          final tmp = File('${_dir!.path}/$_pinsFileName.tmp');
          await tmp.writeAsString(jsonEncode(_pinnedReaches.toList()));
          await tmp.rename('${_dir!.path}/$_pinsFileName');
        } catch (e) {
          AppLogger.error(_tag, 'Error persisting pins', e);
        }
      });

  /// Seed pins from the previous session, unless this session has already
  /// declared its own (the declaration is fresher than any file).
  Future<void> _loadPersistedPins(Directory dir) async {
    try {
      final f = File('${dir.path}/$_pinsFileName');
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      // ONE declared-check, after the await, where it decides — an earlier
      // fast-path copy of it made both undetectably deletable (the redundant
      // pair again).
      if (_pinsDeclaredThisSession) return;
      if (raw is List) {
        _pinnedReaches = Set.unmodifiable(raw.cast<String>());
      }
    } catch (e) {
      AppLogger.error(_tag, 'Error loading persisted pins', e);
    }
  }

  bool _isPinned(String group) {
    final sep = group.indexOf('__');
    final reachId = sep < 0 ? group : group.substring(sep + 2);
    return _pinnedReaches.contains(reachId);
  }

  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async {
    final cached = _memory[key.storageKey];
    if (cached != null) {
      _touch(key);
      return cached;
    }

    await _ensureInitialized();
    if (_dir == null) return null;
    try {
      final file = _fileFor(key);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Belt to the filename's braces: a file that carries the right suffix
      // but the wrong (or no) embedded version is still discarded, not parsed.
      if (json['schema'] != RiverDataEntry.schemaVersion) {
        AppLogger.warning(_tag, 'Discarding ${key.storageKey}: schema mismatch');
        await file.delete();
        return null;
      }
      final entry = RiverDataEntry.fromJson(json);
      _memory[key.storageKey] = entry;
      _touch(key);
      _notifierFor(key).value = entry; // seed any observers with disk value
      return entry;
    } catch (e) {
      AppLogger.error(_tag, 'Error reading ${key.storageKey}', e);
      // A file that cannot be parsed — a truncated write, a corrupt entry —
      // must not persist: left in place it counts against the cap and is
      // re-read (and re-fails) until something overwrites it.
      try {
        await _fileFor(key).delete();
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> put(RiverDataEntry entry) async {
    _memory[entry.key.storageKey] = entry;
    _touch(entry.key);
    _notifierFor(entry.key).value = entry;

    // The disk write joins the serial chain: outside it, a fire-and-forget
    // clear() (sign-out) racing this write left the entry's file deleted while
    // memory kept it — an in-memory ghost gone at the next restart (round 3).
    await _serialised(() async {
      await _ensureInitialized();
      if (_dir != null) {
        try {
          await _fileFor(entry.key).writeAsString(jsonEncode(entry.toJson()));
        } catch (e) {
          AppLogger.error(_tag, 'Error writing ${entry.key.storageKey}', e);
        }
      }
      // Memory-only mode is capped too — review round 1 found an early return
      // skipping this, leaving the one thing this phase bounds unbounded
      // whenever the disk is unavailable.
      await _enforceCap();
    });
  }

  /// Evict least-recently-used non-pinned reaches beyond [maxNonPinnedReaches].
  /// Pinned reaches are excluded from both the count and the eviction — a cap
  /// exceeded entirely by favourites evicts nothing.
  Future<void> _enforceCap() async {
    final groups = <String, DateTime>{};

    for (final storageKey in _memory.keys) {
      final lastSep = storageKey.lastIndexOf('__');
      if (lastSep <= 0) continue;
      final group = storageKey.substring(0, lastSep);
      groups[group] = _lastAccess[group] ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }

    // One directory listing, reused for both the recency fallback and the
    // eviction below (review round 2 measured _evictGroup
    // re-listing per group at O(groups × files) — 322 ms for one worst-case
    // put on a desktop SSD; device flash is slower).
    final filesByGroup = <String, List<File>>{};
    if (_dir != null) {
      try {
        await for (final f in _dir!.list()) {
          if (f is! File) continue;
          final group = _groupOfFileName(f.uri.pathSegments.last);
          if (group == null) continue;
          filesByGroup.putIfAbsent(group, () => []).add(f);
          if (groups.containsKey(group)) continue;
          // Unseen since launch: file mtime stands in for last access. The
          // stat itself is memoised via _lastAccess — round 2 caught the
          // previous version freezing only the VALUE while re-statting every
          // file on every put, the exact cost its comment claimed eliminated.
          var known = _lastAccess[group];
          if (known == null) {
            statCallsForTesting++;
            try {
              known = (await f.stat()).modified.toUtc();
            } catch (_) {
              known = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            }
            _lastAccess[group] = known;
          }
          groups[group] = known;
        }
      } catch (e) {
        AppLogger.error(_tag, 'Error listing cache for cap', e);
      }
    }

    final evictable = groups.keys.where((g) => !_isPinned(g)).toList()
      ..sort((a, b) => groups[a]!.compareTo(groups[b]!));
    final excess = evictable.length - maxNonPinnedReaches;
    if (excess <= 0) return;

    for (final group in evictable.take(excess)) {
      await _evictGroup(group, files: filesByGroup[group]);
    }
  }

  /// Remove every product of a reach group from memory, disk, and observers.
  /// [files] is the group's file list from the caller's directory scan; when
  /// absent (memory-only mode) there is nothing on disk to delete.
  Future<void> _evictGroup(String group, {List<File>? files}) async {
    final prefix = '${group}__';

    for (final storageKey
        in _memory.keys.where((k) => k.startsWith(prefix)).toList()) {
      _memory.remove(storageKey);
      _releaseNotifier(storageKey);
    }
    // Disk-only keys of this group have notifier entries too, if anything
    // ever looked at them this session.
    for (final storageKey
        in _notifiers.keys.where((k) => k.startsWith(prefix)).toList()) {
      _releaseNotifier(storageKey);
    }
    _lastAccess.remove(group);

    for (final f in files ?? const <File>[]) {
      try {
        await f.delete();
      } catch (e) {
        AppLogger.error(_tag, 'Error evicting ${f.path}', e);
      }
    }
  }

  @override
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key) =>
      _notifierFor(key);

  _CacheNotifier _notifierFor(RiverDataKey key) => _notifiers.putIfAbsent(
        key.storageKey,
        () => _CacheNotifier(_memory[key.storageKey]),
      );

  /// Null the notifier and, when nothing is listening, drop the map entry.
  ///
  /// A WATCHED key keeps its notifier — removing it would hand the next
  /// `listenable()` caller a different object while the old widget holds a
  /// dead one. An unwatched key's notifier is pure bookkeeping, and keeping it
  /// grew the map by one entry per browsed key forever (round 3: files bounded
  /// at the cap, 59 notifiers alive).
  void _releaseNotifier(String storageKey) {
    final n = _notifiers[storageKey];
    if (n == null) return;
    n.value = null;
    if (!n.hasActiveListeners) _notifiers.remove(storageKey);
  }

  @override
  Future<void> evict(RiverDataKey key) async {
    _memory.remove(key.storageKey);
    _releaseNotifier(key.storageKey);
    // The recency entry goes when the group's last product does — round 5
    // found this the one path that never dropped it (same growth shape as the
    // notifier map, one path over). ADR 0011 Phase 5 created the first caller:
    // StoreReadCoordinator evicts a favourite's entries when the kill switch
    // turns off, so this path now runs in production and the guard is load-
    // bearing rather than pre-emptive.
    final group = _groupOf(key);
    if (!_memory.keys.any((k) => k.startsWith('${group}__'))) {
      _lastAccess.remove(group);
    }

    await _ensureInitialized();
    if (_dir == null) return;
    try {
      final file = _fileFor(key);
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLogger.error(_tag, 'Error evicting ${key.storageKey}', e);
    }
  }

  @override
  Future<void> clear() {
    _memory.clear();
    _lastAccess.clear();
    // Pins go too — they belong to the account being cleared, and the disk
    // copy vanishes with the directory below. The empty set counts as this
    // session's DECLARATION: without that, a clear() that is the session's
    // first cache op triggers init, whose persisted-pin load resurrected the
    // previous account's pins after this line zeroed them (round 3, F3 —
    // reachable through the auth-state listener on a revoked-token cold start).
    _pinnedReaches = const {};
    _pinsDeclaredThisSession = true;
    for (final storageKey in _notifiers.keys.toList()) {
      _releaseNotifier(storageKey);
    }

    return _serialised(() async {
      await _ensureInitialized();
      if (_dir == null) return;
      try {
        if (await _dir!.exists()) {
          await _dir!.delete(recursive: true);
          await _dir!.create(recursive: true);
        }
      } catch (e) {
        AppLogger.error(_tag, 'Error clearing cache', e);
      }
    });
  }
}

/// [ValueNotifier] that exposes whether anything is subscribed, so the cache
/// can drop observer bookkeeping for keys nobody watches (`hasListeners` is
/// protected on the base class).
class _CacheNotifier extends ValueNotifier<RiverDataEntry?> {
  _CacheNotifier(super.value);

  bool get hasActiveListeners => hasListeners;
}
