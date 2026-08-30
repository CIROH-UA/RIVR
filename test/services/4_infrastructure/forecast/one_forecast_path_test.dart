// test/services/4_infrastructure/forecast/one_forecast_path_test.dart
//
// ADR 0011 Phase 9, guard 1: "nothing in the tree describes or implements the
// old data path, and someone joining would not find a second way to fetch a
// river."
//
// The guard was written as a manual `grep -rn "loadCompleteReachData" lib/`
// returning nothing. That is the right idea and the wrong check, and Phase 9
// proved it: the grep still returns two hits, and both are comments explaining
// that the method was DELETED. A check that cannot tell a caller from an
// epitaph forces you to choose between deleting useful history and leaving the
// guard permanently red.
//
// So the rule here is "no CALLER", not "no mention". History stays; a second
// way to fetch a river does not.
//
// This runs in CI, unlike a grep somebody is supposed to remember.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Every Dart line in `lib/` that is not a `//` comment.
  ///
  /// Doc comments (`///`) are stripped too — that is where the deleted
  /// methods are legitimately named, and it is the whole reason this test
  /// exists rather than a grep.
  List<({String path, int line, String text})> codeLines() {
    final out = <({String path, int line, String text})>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t.startsWith('//')) continue;
        out.add((path: f.path, line: i + 1, text: lines[i]));
      }
    }
    return out;
  }

  // The phased loader and the bundle. Each of these was a way to fetch a
  // river that bypassed the repository; between them they are the "second
  // path" the phase exists to remove.
  const deleted = [
    'loadCompleteReachData',
    'loadOverviewData',
    'loadSupplementaryData',
    'loadReachDetailsData',
  ];

  test('no code in lib/ calls any deleted ForecastService loader', () {
    final code = codeLines();
    expect(code, isNotEmpty,
        reason: 'the scan found no Dart at all — a guard that reads nothing '
            'passes forever');

    final offenders = <String>[];
    for (final entry in code) {
      for (final name in deleted) {
        // `name(` — a call or a declaration, not a mention in prose.
        if (entry.text.contains('$name(')) {
          offenders.add('${entry.path}:${entry.line} -> $name');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'the old phased-load path is back: ${offenders.join(', ')}. '
            'Every river read goes through IRiverDataRepository.');
  });

  test('ForecastService still exposes only the one survivor', () {
    // The positive half. "No callers of the old methods" would also pass if
    // someone added a NEW bypass under a different name, so pin the surface
    // rather than only the absences.
    //
    // ForecastService survives solely to back NwmDataSource's reachMetadata
    // product — the cheapest "who is this reach" fetch, with its cache in
    // front. If it grows a second public method, the 1,000-line loader is
    // growing back and this is where that gets noticed.
    final src = File(
      'lib/services/4_infrastructure/forecast/forecast_service.dart',
    ).readAsLinesSync().where((l) => !l.trim().startsWith('//')).join('\n');

    final publicMethods = RegExp(r'^  (?:Future<[^>]+>|void|[A-Z]\w*) (\w+)\(',
            multiLine: true)
        .allMatches(src)
        .map((m) => m.group(1)!)
        .where((n) => !n.startsWith('_'))
        .toSet();

    expect(publicMethods, {'loadBasicReachInfo'},
        reason: 'ForecastService is meant to be one method backing '
            'reachMetadata. Anything else is a second way to fetch a river.');
  });
}
