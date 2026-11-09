// test/docs/claude_md_schedule_drift_test.dart
//
// Item 13 of the remediation backlog, and the one durable half of it.
//
// A 2026-11-09 audit checked ~190 claims in this repo's docs: 115 held, 52
// were stale and 29 were wrong. The split had nothing to do with writing
// quality. **Every claim resting on n <= 2 that could be checked came back
// wrong or stale, and every claim pinned by a test came back right, 21 for
// 21.** So the fix for a class of claims is a test, not a careful re-read.
//
// This pins the cloud-store cadence table in CLAUDE.md to the crons in
// `functions/src/index.ts`. That table had already drifted: it announced
// `storeRefreshHourly` at `:20` after the schedule moved to `:05` on
// 2026-11-03, which is the same drift `health-schedule-drift.test.ts` was
// written for, sitting in the most-read document in the repo instead of in
// the endpoint.
//
// Narrow on purpose. It cannot tell whether a paragraph still describes the
// system; it checks the falsifiable half, which is the half that rots
// silently. `claude_md_accuracy_test.dart` does the same for paths.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The cron expression and timezone declared for an exported function.
///
/// Anchored on `export const <name> = functions`, never on a bare search for
/// the name: the name also appears in the prose being checked, and matching
/// that would let this compare the documentation with itself.
({String cron, String zone}) scheduleOf(String source, String name) {
  final start = source.indexOf('export const $name = functions');
  expect(start, greaterThan(-1),
      reason: '$name is gone or renamed, but CLAUDE.md still documents it');
  final afterIndex = source.indexOf('\nexport ', start + 1);
  final body =
      source.substring(start, afterIndex == -1 ? source.length : afterIndex);

  final cron = RegExp(r'\.pubsub\.schedule\("([^"]+)"\)').firstMatch(body);
  final zone = RegExp(r'\.timeZone\("([^"]+)"\)').firstMatch(body);
  expect(cron, isNotNull, reason: '$name declares no pubsub schedule');
  expect(zone, isNotNull, reason: '$name declares no timeZone');
  return (cron: cron!.group(1)!, zone: zone!.group(1)!);
}

/// `"30 11 * * *"` -> minute 30, hour 11. Hour is null when it runs hourly.
({int minute, int? hour}) cronFields(String cron) {
  final parts = cron.trim().split(RegExp(r'\s+'));
  expect(parts, hasLength(5), reason: 'not a 5-field cron: $cron');
  final minute = int.tryParse(parts[0]);
  expect(minute, isNotNull, reason: 'non-literal minute in $cron');
  return (minute: minute!, hour: int.tryParse(parts[1]));
}

void main() {
  final claudeMd = File('CLAUDE.md').readAsStringSync();
  final index = File('functions/src/index.ts').readAsStringSync();

  /// The row of CLAUDE.md's function table that names [fn].
  String row(String fn) {
    final match = claudeMd
        .split('\n')
        .where((l) => l.startsWith('| `$fn`'))
        .toList();
    expect(match, hasLength(1),
        reason: 'expected exactly one cadence row for $fn in CLAUDE.md');
    return match.single;
  }

  test('the refresh minute CLAUDE.md documents is the real one', () {
    final minute = cronFields(scheduleOf(index, 'storeRefreshHourly').cron)
        .minute;
    final pad = minute.toString().padLeft(2, '0');

    expect(row('storeRefreshHourly'), contains(':$pad'),
        reason: 'the cron runs at :$pad. This row said :20 for six days '
            'after the schedule moved, which is exactly the drift this '
            'file exists to stop');
  });

  test('every daily store function\'s documented time is its real one', () {
    for (final fn in const [
      'storeGeoglowsDaily',
      'storeStaticDaily',
      'storeGcDaily',
    ]) {
      final s = scheduleOf(index, fn);
      final f = cronFields(s.cron);
      expect(s.zone, 'UTC',
          reason: 'CLAUDE.md states these in UTC; a timezone change would '
              'silently shift every hour an operator reads');
      expect(f.hour, isNotNull, reason: '$fn is not hourly');
      final stamp = '${f.hour.toString().padLeft(2, '0')}:'
          '${f.minute.toString().padLeft(2, '0')}';
      expect(row(fn), contains(stamp),
          reason: '$fn runs at $stamp UTC and its row does not say so');
    }
  });

  test('the heartbeat interval CLAUDE.md documents is the real one', () {
    final cron = scheduleOf(index, 'storeHeartbeat').cron;
    final hourField = cron.trim().split(RegExp(r'\s+'))[1];
    final every = RegExp(r'^\*/(\d+)$').firstMatch(hourField);
    expect(every, isNotNull, reason: 'expected an every-N-hours cron: $cron');

    expect(row('storeHeartbeat'), contains('${every!.group(1)}-hourly'),
        reason: 'the row claims an interval; it has to be the cron\'s');
  });

  test('the table names no function that no longer exists', () {
    // The first drift of this kind: four deleted conditions functions were
    // still advertised, both here and by the health endpoint.
    final named = claudeMd
        .split('\n')
        .map((l) => RegExp(r'^\| `(store[A-Z]\w+)`').firstMatch(l))
        .whereType<RegExpMatch>()
        .map((m) => m.group(1)!)
        .toSet();

    expect(named, isNotEmpty,
        reason: 'the table was found empty, so this guard cannot work');
    for (final fn in named) {
      expect(index.contains('export const $fn ='), isTrue,
          reason: 'CLAUDE.md documents $fn, which index.ts no longer exports');
    }
  });
}
