// Structural mirror gate for the escalation shape.
//
// One escalation row is written out by hand SEVEN times — twice in TypeScript
// (`OpenEscalationSchema` for the record, `OpenEscalationWire` for the wire) and
// five times in Dart, each a separate field-by-field rebuild that silently drops
// anything the author forgot. Nothing in CI couples them, and the failure is
// invisible: the same row renders one way when it arrives live and another way
// when a status snapshot replays it, or a withdrawn card loses a field on its
// way through `withoutChoices()`.
//
// So this test treats the bridge's wire schema as the source of truth, the way
// `classification_gate_test.dart` treats the parser switch: it scrapes the key
// names declared in `OpenEscalationWire` out of `bridge/src/protocol.ts` and
// asserts each one is named in every Dart copy. There is no list here to forget
// to update — a field added to the wire fails this test until all five copies
// carry it, for this change and every one after it.
//
// It is a NAMING gate, not a semantic one: it proves no copy silently omits a
// field, and says nothing about whether the value each one carries is right.
// The per-field round-trip tests in `handler_state_test.dart`,
// `handler_messages_test.dart` and `handler_service_test.dart` cover that half.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the bridge's wire schema lives, relative to the app package root that
/// `flutter test` runs from.
final _protocol = File('../bridge/src/protocol.ts');

/// The top-level key names declared inside `OpenEscalationWire = z.object({…})`.
///
/// Depth-tracked rather than line-matched, because `askOptions` nests a second
/// `z.object({…})` whose own keys are a different shape entirely and must not
/// leak in. Throws (rather than using `expect`) so it is safe to call from
/// `setUpAll`.
Set<String> _wireEscalationKeys(String source) {
  const marker = 'const OpenEscalationWire = z.object({';
  final start = source.indexOf(marker);
  if (start < 0) {
    throw StateError(
      'Could not find "$marker" in ${_protocol.absolute.path} — the schema was '
      'renamed or moved, and this gate is scraping nothing.',
    );
  }
  final keys = <String>{};
  final keyLine = RegExp(r'^(\w+):');
  var depth = 0;
  for (final raw in const LineSplitter().convert(
    source.substring(start + marker.length),
  )) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (depth == 0) {
      final m = keyLine.firstMatch(line);
      if (m != null) keys.add(m.group(1)!);
    }
    for (final c in line.split('')) {
      if (c == '{' || c == '(' || c == '[') depth++;
      if (c == '}' || c == ')' || c == ']') depth--;
    }
    // The object's own closing brace: anything past it belongs to the next
    // declaration.
    if (depth < 0) break;
  }
  return keys;
}

/// The source of one hand copy, from [startMarker] up to the line that is
/// exactly [endLine]. Comments are stripped, so a field named only in prose
/// cannot satisfy the gate.
String _copySource(
  String source,
  String label,
  String startMarker,
  String endLine,
) {
  final start = source.indexOf(startMarker);
  if (start < 0) {
    throw StateError(
      'Could not find $label at "$startMarker" — the scrape markers in this '
      'test have drifted from the source.',
    );
  }
  final lines = const LineSplitter().convert(source.substring(start));
  final body = StringBuffer();
  var closed = false;
  for (final line in lines) {
    if (line.trimRight() == endLine) {
      closed = true;
      break;
    }
    final comment = line.indexOf('//');
    body.writeln(comment < 0 ? line : line.substring(0, comment));
  }
  if (!closed) {
    throw StateError(
      'Found $label but never its terminator "$endLine" — the scrape markers '
      'in this test have drifted from the source.',
    );
  }
  return body.toString();
}

void main() {
  // An app-only checkout has no bridge tree. Skipping loudly beats failing:
  // this gate is about drift between two trees, and only one of them is here.
  final missing = _protocol.existsSync()
      ? null
      : 'No bridge tree at ${_protocol.absolute.path} — the escalation mirror '
            'gate needs both halves of the boundary it couples.';

  group('escalation shape mirror gate', skip: missing, () {
    late final Set<String> wireKeys;
    late final Map<String, String> copies;
    // Fields a copy legitimately does not name, each with the reason it is
    // absent. Anything not listed here is drift.
    const exempt = <String, Set<String>>{
      // Withdrawing the card is the entire purpose of the method.
      'HandlerEscalation.withoutChoices': {'choices'},
      // The one-shot push carries the row's own timestamp in the envelope's
      // `timestamp`, minted in the same construction as `at` (see the
      // handler:escalation send in bridge/src/handler/engine.ts), and the app
      // reads it from there.
      'HandlerEscalationMessage': {'at'},
      "parseAbMessage case 'handler:escalation'": {'at'},
    };

    setUpAll(() {
      wireKeys = _wireEscalationKeys(_protocol.readAsStringSync());
      final state = File('lib/models/handler_state.dart').readAsStringSync();
      final message = File('lib/models/ab_message.dart').readAsStringSync();
      final service = File(
        'lib/services/handler_service.dart',
      ).readAsStringSync();
      copies = {
        'HandlerEscalation constructor': _copySource(
          state,
          'the HandlerEscalation constructor',
          '  const HandlerEscalation({',
          '  });',
        ),
        'HandlerEscalation.fromWire': _copySource(
          state,
          'HandlerEscalation.fromWire',
          '  static HandlerEscalation? fromWire(',
          '  }',
        ),
        'HandlerEscalation.withoutChoices': _copySource(
          state,
          'HandlerEscalation.withoutChoices',
          '  HandlerEscalation withoutChoices() => HandlerEscalation(',
          '  );',
        ),
        'HandlerEscalation.copyWith': _copySource(
          state,
          'HandlerEscalation.copyWith',
          '  HandlerEscalation copyWith({',
          '  );',
        ),
        'HandlerEscalationMessage': _copySource(
          message,
          'the HandlerEscalationMessage class',
          'class HandlerEscalationMessage {',
          '}',
        ),
        "parseAbMessage case 'handler:escalation'": _copySource(
          message,
          "parseAbMessage's handler:escalation case",
          "    case 'handler:escalation':",
          '      }',
        ),
        "HandlerService._onHeavyJson case 'handler:escalation'": _copySource(
          service,
          "_onHeavyJson's handler:escalation case",
          "      case 'handler:escalation':",
          '        break;',
        ),
      };
    });

    test('the wire scrape found the escalation keys', () {
      // A guard against a silent scrape failure (marker drift, a reformatted
      // schema) that would otherwise make the gate below vacuously pass.
      expect(
        wireKeys.length,
        greaterThan(8),
        reason:
            'Only found ${wireKeys.length} keys on OpenEscalationWire — the '
            'scrape likely broke. Fix _wireEscalationKeys before trusting '
            'this gate.',
      );
      expect(wireKeys, contains('escalationId'));
      expect(wireKeys, contains('choices'));
      expect(wireKeys, contains('nonBlocking'));
      expect(wireKeys, contains('askOptions'));
      // The nested askOption shape must NOT have leaked into the top level.
      expect(wireKeys, isNot(contains('cost')));
      expect(wireKeys, isNot(contains('recommended')));
    });

    test('every wire field is named in every Dart copy', () {
      final offenders = <String>[];
      for (final copy in copies.entries) {
        final skipped = exempt[copy.key] ?? const <String>{};
        for (final key in wireKeys) {
          if (skipped.contains(key)) continue;
          if (!RegExp('\\b$key\\b').hasMatch(copy.value)) {
            offenders.add('${copy.key} is missing "$key"');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These hand copies of the escalation shape have drifted from '
            'OpenEscalationWire, so the field they omit is silently dropped '
            'on whichever path they serve: $offenders. Add it to each one, '
            'or — if it genuinely does not belong there — add it to this '
            "test's `exempt` map with the reason.",
      );
    });

    test('no exemption outlives the field it excuses', () {
      // An exemption for a field the wire no longer declares is a hole left
      // open over a shape that moved on.
      final stale = <String>[];
      for (final entry in exempt.entries) {
        for (final key in entry.value) {
          if (!wireKeys.contains(key)) stale.add('${entry.key}: $key');
        }
      }
      expect(stale, isEmpty);
    });
  });
}
