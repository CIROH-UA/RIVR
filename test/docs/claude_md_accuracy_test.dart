// test/docs/claude_md_accuracy_test.dart
//
// ADR 0011 Phase 9, guard 5: "CLAUDE.md read as if new would build the current
// architecture." Every stale-doc incident in this project began with a
// document that was true when it was written.
//
// **This is a narrow guard and says so.** It cannot tell whether a paragraph
// still DESCRIBES the system correctly — no test can. What it checks is the
// falsifiable half: that the paths and file names CLAUDE.md points at still
// exist. That is the half that rots silently, and it is what caught two
// entries on 2026-08-30, when `AuthGuard` and `BaseUseCase` were still listed
// in the architecture tree after both files had been dead long enough to have
// no references left anywhere in the codebase.
//
// Prose drift still needs a human. Path drift no longer does.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final claudeMd = File('CLAUDE.md').readAsStringSync();

  test('every lib/ path CLAUDE.md names actually exists', () {
    final referenced = RegExp(r'\b(lib/[A-Za-z0-9_/\.]+\.dart)\b')
        .allMatches(claudeMd)
        .map((m) => m.group(1)!)
        .toSet();

    expect(referenced, isNotEmpty,
        reason: 'the extraction itself broke; a guard that matches nothing '
            'passes forever and protects nothing');

    // config.dart and firebase_options.dart are gitignored secrets: present on
    // a developer machine, absent in CI. Named in CLAUDE.md precisely BECAUSE
    // they must be created by hand, so their absence is documentation working.
    const createdByHand = {
      'lib/services/0_config/shared/config.dart',
      'lib/firebase_options.dart',
    };

    final missing = referenced
        .where((p) => !createdByHand.contains(p))
        .where((p) => !File(p).existsSync())
        .toList()
      ..sort();

    expect(missing, isEmpty,
        reason: 'CLAUDE.md points at files that do not exist: '
            '${missing.join(', ')}. Someone reading it as their introduction '
            'to this codebase would go looking for them.');
  });

  test('every server path CLAUDE.md names actually exists', () {
    final referenced = RegExp(r'\b(functions(?:_geoglows)?/[A-Za-z0-9_/\.]+'
            r'\.(?:ts|py|json))\b')
        .allMatches(claudeMd)
        .map((m) => m.group(1)!)
        .toSet();

    expect(referenced, isNotEmpty);
    const createdByHand = {'functions/.env', 'functions_geoglows/.env'};
    final missing = referenced
        .where((p) => !createdByHand.contains(p))
        .where((p) => !File(p).existsSync())
        .toList()
      ..sort();
    expect(missing, isEmpty,
        reason: 'CLAUDE.md points at server files that do not exist: '
            '${missing.join(', ')}');
  });

  test('the deleted data path is not presented as a current pattern', () {
    // The worst kind of stale doc, and it survived until Phase 9: CLAUDE.md's
    // "Key Patterns" list described the phased loader —
    // `loadOverviewData -> loadSupplementaryData -> loadCompleteReachData` —
    // as how this app loads data, months after ADR 0011 Phase 3 deleted all
    // three and routed every surface through IRiverDataRepository. Someone
    // reading the file as their introduction would have built the thing the
    // phase exists to remove.
    //
    // Narrow on purpose: the method NAMES may legitimately appear in
    // CLAUDE.md as history ("was deleted in Phase 3"), and a test cannot
    // reliably tell history from instruction. What it CAN pin is the heading
    // that presented it as current.
    expect(claudeMd.contains('Phased data loading'), isFalse,
        reason: 'the phased loader is deleted; presenting it as a key pattern '
            'is how a new contributor rebuilds the old data path');
    expect(claudeMd.contains('IRiverDataRepository'), isTrue,
        reason: 'the one data path must be the one the document teaches');
  });

  test('the architecture tree names no deleted class', () {
    // The specific rot this caught. The tree annotates directories with the
    // classes they hold — `routing/ -- AppRouter, AuthGuard, routes` — and
    // those annotations are invisible to a path check, because the directory
    // still exists.
    //
    // Deliberately a SMALL list rather than a parse of the whole tree: naming
    // the classes that were actually wrong keeps this honest about its scope.
    // A general version would have to know which annotations are class names
    // and which are prose, and would quietly stop working.
    for (final gone in [
      'AuthGuard',
      'BaseUseCase',
      'GeoglowsForecastProvider',
      'FlowCategoryPulseAnimator',
      'ForecastCategoryGrid',
      'FlowValuesUsageGuide',
      'ImageCategoryGrid',
    ]) {
      expect(claudeMd.contains(gone), isFalse,
          reason: '$gone was deleted in Phase 9 but CLAUDE.md still names it');
    }
  });
}
