// lib/services/4_infrastructure/cache/river_data_cache.dart

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
/// key at `<appCache>/rivr_river_data_cache/<storageKey>.json`.
///
/// The cache directory is injectable ([cacheDirProvider]) so tests can point at
/// a temp dir without the `path_provider` platform channel.
class RiverDataCache implements IRiverDataCache {
  RiverDataCache({Future<Directory> Function()? cacheDirProvider})
    : _cacheDirProvider = cacheDirProvider ?? _defaultCacheDir;

  static const String _cacheDirName = 'rivr_river_data_cache';
  static const String _tag = 'RIVER_DATA_CACHE';

  final Future<Directory> Function() _cacheDirProvider;
  Directory? _dir;

  final Map<String, RiverDataEntry> _memory = {};
  final Map<String, ValueNotifier<RiverDataEntry?>> _notifiers = {};

  static Future<Directory> _defaultCacheDir() async {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}/$_cacheDirName');
  }

  @override
  Future<void> initialize() async {
    try {
      final dir = await _cacheDirProvider();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
      AppLogger.info(_tag, 'Initialized at ${dir.path}');
    } catch (e) {
      AppLogger.error(_tag, 'Error initializing', e);
    }
  }

  @override
  bool get isReady => _dir != null;

  File _fileFor(RiverDataKey key) =>
      File('${_dir!.path}/${key.storageKey}.json');

  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async {
    final cached = _memory[key.storageKey];
    if (cached != null) return cached;

    if (_dir == null) return null;
    try {
      final file = _fileFor(key);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final entry = RiverDataEntry.fromJson(json);
      _memory[key.storageKey] = entry;
      _notifierFor(key).value = entry; // seed any observers with disk value
      return entry;
    } catch (e) {
      AppLogger.error(_tag, 'Error reading ${key.storageKey}', e);
      return null;
    }
  }

  @override
  Future<void> put(RiverDataEntry entry) async {
    _memory[entry.key.storageKey] = entry;
    _notifierFor(entry.key).value = entry;

    if (_dir == null) return; // memory still holds it; disk is best-effort
    try {
      await _fileFor(entry.key).writeAsString(jsonEncode(entry.toJson()));
    } catch (e) {
      AppLogger.error(_tag, 'Error writing ${entry.key.storageKey}', e);
    }
  }

  @override
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key) =>
      _notifierFor(key);

  ValueNotifier<RiverDataEntry?> _notifierFor(RiverDataKey key) =>
      _notifiers.putIfAbsent(
        key.storageKey,
        () => ValueNotifier<RiverDataEntry?>(_memory[key.storageKey]),
      );

  @override
  Future<void> evict(RiverDataKey key) async {
    _memory.remove(key.storageKey);
    _notifiers[key.storageKey]?.value = null;

    if (_dir == null) return;
    try {
      final file = _fileFor(key);
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLogger.error(_tag, 'Error evicting ${key.storageKey}', e);
    }
  }

  @override
  Future<void> clear() async {
    _memory.clear();
    for (final notifier in _notifiers.values) {
      notifier.value = null;
    }

    if (_dir == null) return;
    try {
      if (await _dir!.exists()) {
        await _dir!.delete(recursive: true);
        await _dir!.create(recursive: true);
      }
    } catch (e) {
      AppLogger.error(_tag, 'Error clearing cache', e);
    }
  }
}
