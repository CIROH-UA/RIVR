// test/docs/claude_md_constants_test.dart
//
// Item 13 of the remediation backlog: the audit found 52 stale and 29 wrong
// claims across these docs, out of ~190 checked. **The split had nothing to
// do with writing quality. Every claim resting on n <= 2 that could be
// checked came back wrong or stale, and every claim pinned by a test came
// back right, 21 for 21.**
//
// So this pins the numbers CLAUDE.md quotes about code constants. Checked
// 2026-11-09 before writing it, every one of them was already CORRECT, which
// makes this pure prevention rather than a correction. That is the point:
// the claims that stayed true are the ones something was checking.
//
// Companions: `claude_md_accuracy_test.dart` pins the PATHS it names,
// `claude_md_schedule_drift_test.dart` pins the cron SCHEDULES, and
// `functions/src/hold-policy-drift.test.ts` pins the client and server
// freshness tables against each other. Prose still needs a human; numbers no
// longer do.
//
// Deliberately NOT pinned here, and worth saying so: the flood tileset's
// zoom range, retention and tile-size percentages. Those describe a Mapbox
// artefact built by a script outside this repo, so there is no source of
// truth on disk to compare against and a test would only be restating the
// prose back to itself.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One claim: a number CLAUDE.md states, and where the truth lives.
class _Claim {
  const _Claim({
    required this.what,
    required this.docPattern,
    required this.sourcePath,
    required this.sourcePattern,
    this.sourceTable,
    this.why = '',
  });

  /// Human name, used in failure messages.
  final String what;

  /// Matches the claim in CLAUDE.md. Group 1 is the number.
  ///
  /// Held as a string, not a RegExp, so the claim table can stay `const`.
  final String docPattern;

  final String sourcePath;

  /// Matches the constant in the source. Group 1 is the number.
  final String sourcePattern;

  /// Narrow the search to one declaration, by name.
  ///
  /// Needed wherever the same key appears in more than one table, and the
  /// first version of this file got caught by exactly that:
  /// `hold_policy.dart` lists `geoglowsForecast` in BOTH `maxHold` (48h) and
  /// `maxRunAge` (42h), the unscoped pattern matched the first, and the guard
  /// reported CLAUDE.md as wrong when CLAUDE.md was right. A guard that
  /// reads the wrong number is worse than no guard: it teaches you to
  /// distrust the document.
  final String? sourceTable;

  /// What breaks if they disagree.
  final String why;
}

const _claims = <_Claim>[
  _Claim(
    what: 'EMPTY_SECTION_ATTEMPTS',
    docPattern: r'`EMPTY_SECTION_ATTEMPTS = (\d+)`',
    sourcePath: 'functions/src/store-upstream.ts',
    sourcePattern: r'EMPTY_SECTION_ATTEMPTS = (\d+)',
    why: 'the retry budget for a 200 whose section came back empty, which is '
        'the one exception to "the store never retries"',
  ),
  _Claim(
    what: 'WINDOW_PROBE_REACHES',
    docPattern: r'`WINDOW_PROBE_REACHES = (\d+)`',
    sourcePath: 'functions/src/store-run.ts',
    sourcePattern: r'WINDOW_PROBE_REACHES = (\d+)',
    why: 'how many empty reaches in a row stop a run paying for a shut '
        'upstream window',
  ),
  _Claim(
    what: 'the island COMID band, lower bound',
    docPattern: r'band (\d{9})-\d{9} are island reaches',
    sourcePath: 'lib/models/1_domain/shared/river_data/nwm_domain.dart',
    sourcePattern: r'islandComidMin = (\d+)',
    why: 'island reaches take a different publish cadence entirely; the band '
        'is how one is recognised',
  ),
  _Claim(
    what: 'the island COMID band, upper bound',
    docPattern: r'band \d{9}-(\d{9}) are island reaches',
    sourcePath: 'lib/models/1_domain/shared/river_data/nwm_domain.dart',
    sourcePattern: r'islandComidMax = (\d+)',
  ),
  _Claim(
    what: "the island short-range cycle",
    docPattern: r'take a (\d+)-hour short-range\s+window',
    sourcePath: 'lib/models/1_domain/shared/river_data/nwm_domain.dart',
    sourcePattern: r'islandShortRangeCycleHours = (\d+)',
    why: 'Hawaii and Puerto Rico publish short range every 6 hours, not '
        'hourly; getting this wrong expires island documents between runs',
  ),
  _Claim(
    what: "GEOGLOWS's run-age cap",
    docPattern: r'GEOGLOWS is (\d+)h because a stored run legitimately',
    sourcePath: 'lib/services/4_infrastructure/river_data/hold_policy.dart',
    sourcePattern: r'geoglowsForecast: Duration\(hours: (\d+)\)',
    sourceTable: 'maxRunAge',
    why: 'past this the app stops vouching for the value on screen',
  ),
];

/// The first capture group of [pattern] in [text], or null.
String? _numberIn(String text, String pattern) =>
    RegExp(pattern).firstMatch(text)?.group(1);

void main() {
  final claudeMd = File('CLAUDE.md').readAsStringSync();

  for (final claim in _claims) {
    test('CLAUDE.md states ${claim.what} correctly', () {
      final documented = _numberIn(claudeMd, claim.docPattern);
      expect(documented, isNotNull,
          reason: 'CLAUDE.md no longer states ${claim.what} in the shape '
              'this guard looks for (${claim.docPattern}). If the '
              'wording changed, update the pattern; if the claim was '
              'deleted, delete this entry with it. Do not leave a guard '
              'matching nothing, which is how a test stops testing.');

      var source = File(claim.sourcePath).readAsStringSync();
      if (claim.sourceTable != null) {
        final start = source.indexOf('${claim.sourceTable} = {');
        expect(start, greaterThan(-1),
            reason: '${claim.sourceTable} is gone from ${claim.sourcePath}');
        source = source.substring(start, source.indexOf('};', start));
      }
      final actual = _numberIn(source, claim.sourcePattern);
      expect(actual, isNotNull,
          reason: '${claim.sourcePath} no longer declares ${claim.what}');

      expect(documented, actual,
          reason: 'CLAUDE.md says ${claim.what} is $documented; '
              '${claim.sourcePath} says $actual. '
              '${claim.why.isEmpty ? '' : 'Why it matters: ${claim.why}.'}');
    });
  }

  test('the run-age caps CLAUDE.md lists are the real ones', () {
    // Stated as a run of four numbers, "caps of 16/16/24/36h", in the order
    // currentFlow / shortRange / mediumRange / longRange. A list like this is
    // the easiest kind of claim to leave behind when one entry moves.
    final documented = RegExp(r'against caps of (\d+)/(\d+)/(\d+)/(\d+)h')
        .firstMatch(claudeMd);
    expect(documented, isNotNull,
        reason: 'CLAUDE.md no longer lists the four caps in the shape this '
            'guard reads');

    final policy = File(
      'lib/services/4_infrastructure/river_data/hold_policy.dart',
    ).readAsStringSync();

    // Only the maxRunAge table, not islandMaxRunAge, which carries its own
    // numbers for the same products.
    final start = policy.indexOf('const Map<ForecastProduct, Duration> '
        'maxRunAge = {');
    expect(start, greaterThan(-1));
    final table = policy.substring(start, policy.indexOf('};', start));

    int hoursFor(String product) {
      final m = RegExp('$product: Duration\\(hours: (\\d+)\\)')
          .firstMatch(table);
      expect(m, isNotNull, reason: '$product missing from maxRunAge');
      return int.parse(m!.group(1)!);
    }

    expect(
      [
        int.parse(documented!.group(1)!),
        int.parse(documented.group(2)!),
        int.parse(documented.group(3)!),
        int.parse(documented.group(4)!),
      ],
      [
        hoursFor('currentFlow'),
        hoursFor('shortRange'),
        hoursFor('mediumRange'),
        hoursFor('longRange'),
      ],
      reason: 'the caps are listed in CLAUDE.md as currentFlow / shortRange '
          '/ mediumRange / longRange. Past these the app stops vouching for '
          'what is on screen, and the server stops extending the window at '
          'the same instant using the same numbers',
    );
  });

  test('the island caps CLAUDE.md states are the real ones', () {
    final hold = RegExp(r'a (\d+)-hour hold cap').firstMatch(claudeMd);
    final runAge = RegExp(r'a (\d+)-hour run-age cap').firstMatch(claudeMd);
    expect(hold, isNotNull);
    expect(runAge, isNotNull);

    final policy = File(
      'lib/services/4_infrastructure/river_data/hold_policy.dart',
    ).readAsStringSync();

    String islandHours(String table, String product) {
      final start = policy.indexOf(
          'const Map<ForecastProduct, Duration> $table = {');
      expect(start, greaterThan(-1), reason: '$table is gone');
      final body = policy.substring(start, policy.indexOf('};', start));
      final m = RegExp('$product: Duration\\(hours: (\\d+)\\)')
          .firstMatch(body);
      expect(m, isNotNull, reason: '$product missing from $table');
      return m!.group(1)!;
    }

    expect(hold!.group(1), islandHours('islandMaxHold', 'shortRange'));
    expect(runAge!.group(1), islandHours('islandMaxRunAge', 'shortRange'),
        reason: 'island short range publishes every 6 or 12 hours, so these '
            'are deliberately longer than the CONUS numbers');
  });
}
