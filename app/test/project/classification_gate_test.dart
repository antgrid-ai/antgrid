// Structural classification gate.
//
// The receive-side twin of the re-drive registry: a new agent->app message
// type that isn't registered with the classifier is silently DROPPED by
// MessageRouter before any service sees it. The cure the reconciliation-
// checkpoint plan calls for is to make registration ENFORCED, not remembered.
//
// The one place you MUST touch to receive a new inbound type is the
// `parseAbMessage` switch in `models/ab_message.dart` — a type the app can't
// parse can't be handled at all. So this test treats that switch as the source
// of truth: it scrapes every `case '<type>':` the parser recognizes and asserts
// each one is EITHER classified as a real tier (status/heavy) OR explicitly
// listed in `kUnroutedInboundTypes` with a documented reason. Adding a parser
// case without doing one of those fails this test.
//
// Unlike `classification_completeness_test.dart` (which enumerates a REMEMBERED
// list of service-handled types), this gate derives its type set from the
// actual parser source, so there is no list to forget to update.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_message_classification.dart';

/// Extracts the `case '<type>':` string literals inside the `parseAbMessage`
/// switch. Scoped to that function body so unrelated `case` statements (were
/// any added elsewhere in the file) can't leak in. Throws (rather than using
/// `expect`) so it is safe to call from `setUpAll`.
Set<String> _parserInboundTypes() {
  // flutter test runs with the package root (app/) as the working directory.
  final file = File('lib/models/ab_message.dart');
  if (!file.existsSync()) {
    throw StateError(
      'Expected to read the parser source at ${file.absolute.path}; run this '
      'test from the app/ package root (flutter test does this by default).',
    );
  }
  final source = file.readAsStringSync();

  const startMarker = 'Object? parseAbMessage(';
  const endMarker = '// --- Outbound message builder ---';
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker);
  if (start < 0 || end <= start) {
    throw StateError(
      'Could not locate the parseAbMessage function body between its signature '
      'and the outbound-builder marker — the scrape markers in this test have '
      'drifted from ab_message.dart.',
    );
  }
  final body = source.substring(start, end);

  final caseRe = RegExp(r"""case ['"]([^'"]+)['"]:""");
  return caseRe.allMatches(body).map((m) => m.group(1)!).toSet();
}

void main() {
  group('inbound-type classification gate', () {
    late final Set<String> parserTypes;

    setUpAll(() {
      parserTypes = _parserInboundTypes();
    });

    test('the parser source scrape found the inbound cases', () {
      // A guard against a silent scrape failure (marker drift, moved file)
      // that would otherwise make the gate below vacuously pass.
      expect(
        parserTypes.length,
        greaterThan(20),
        reason:
            'Only found ${parserTypes.length} parser cases — the scrape likely '
            'broke. Fix _parserInboundTypes before trusting this gate.',
      );
      expect(parserTypes, contains('agent:status'));
      expect(parserTypes, contains('terminal:output'));
    });

    test('every parseable inbound type is classified or explicitly unrouted', () {
      final offenders = <String>[];
      for (final type in parserTypes) {
        final classified = classifyAbMessageByType(type) != MessageTier.ignore;
        final unrouted = kUnroutedInboundTypes.contains(type);
        if (!classified && !unrouted) offenders.add(type);
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These inbound types have a parseAbMessage case but classify as '
            'MessageTier.ignore, so MessageRouter drops them before any service '
            'sees them: $offenders. Add each to _statusTypes / _heavyTypes in '
            'project_message_classification.dart, or — if it is genuinely not '
            'routed through control-channel classification — add it to '
            'kUnroutedInboundTypes with a reason.',
      );
    });

    test('kUnroutedInboundTypes has no stale entries', () {
      final stale = kUnroutedInboundTypes
          .where((t) => !parserTypes.contains(t))
          .toList();
      expect(
        stale,
        isEmpty,
        reason:
            'These kUnroutedInboundTypes entries no longer have a parseAbMessage '
            'case and should be removed: $stale.',
      );
    });

    test('kUnroutedInboundTypes does not contradict the classifier', () {
      // An "unrouted" type must actually classify as ignore; otherwise the two
      // sources disagree about whether the frame reaches a reducer.
      for (final t in kUnroutedInboundTypes) {
        expect(
          classifyAbMessageByType(t),
          MessageTier.ignore,
          reason:
              '"$t" is declared unrouted but the classifier routes it — one of '
              'the two is wrong.',
        );
      }
    });
  });
}
