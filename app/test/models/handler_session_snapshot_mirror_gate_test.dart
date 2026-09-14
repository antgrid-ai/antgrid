// Structural mirror gate for the session-snapshot shape.
//
// Unlike an escalation row — parsed at five separate hand-written sites, one
// per surface it reaches — a `HandlerSessionSnapshot` has exactly one Dart
// parse site: `HandlerSessionState.fromWire`. `parseAbMessage`'s
// `handler:status` case (`ab_message.dart`) only sieves the `sessions` array
// down to plain maps and hands each one to `fromWire` unread, so `fromWire` is
// the whole boundary — the one place a field the bridge added can be silently
// left on the floor.
//
// A field dropped there costs nothing at either compiler and shows up only as
// a surface that renders stale truth forever — the app kept showing one goal
// line while the judge read a whole instruction list, and no test in either
// tree objected. So this test treats the bridge's wire schema as the source of
// truth, the way
// `handler_escalation_mirror_gate_test.dart` does for `OpenEscalationWire`: it
// scrapes the key names declared in `HandlerSessionSnapshot` out of
// `bridge/src/protocol.ts` and asserts each one is named in `fromWire`.
//
// It is a NAMING gate, not a semantic one — it proves `fromWire` does not
// silently drop a field, and says nothing about whether the value it produces
// is right. The per-field round-trip tests in `handler_state_test.dart` cover
// that half. It also does not re-check `HandlerSessionState`'s constructor or
// `copyWith`: the Dart compiler already ties `fromWire`'s returned object
// literal to the class's declared fields (an unread field cannot be passed to
// a parameter that doesn't exist), and `copyWith` silently resetting an
// already-parsed field is a different bug — dropped between two live objects,
// never touching the wire — covered by its own targeted test
// ("copyWith carries …") rather than by a schema scrape.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the bridge's wire schema lives, relative to the app package root that
/// `flutter test` runs from.
final _protocol = File('../bridge/src/protocol.ts');

/// The top-level key names declared inside
/// `const HandlerSessionSnapshot = z.object({…})`.
///
/// Depth-tracked rather than line-matched, because `instructions` nests a
/// second `z.object({…})` (`total`, `items`) whose keys are a different shape
/// entirely and must not leak into the top level. Throws (rather than using
/// `expect`) so it is safe to call from `setUpAll`.
Set<String> _wireSnapshotKeys(String source) {
  const marker = 'const HandlerSessionSnapshot = z.object({';
  final start = source.indexOf(marker);
  if (start < 0) {
    throw StateError(
      'Could not find "$marker" in ${_protocol.absolute.path} — the schema '
      'was renamed or moved, and this gate is scraping nothing.',
    );
  }
  final keys = <String>{};
  var closed = false;
  var depth = 0;
  for (final raw in const LineSplitter().convert(
    source.substring(start + marker.length),
  )) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (depth == 0) {
      final m = _keyLine.firstMatch(line);
      if (m != null) keys.add(m.group(1)!);
    }
    for (final c in line.split('')) {
      if (c == '{' || c == '(' || c == '[') depth++;
      if (c == '}' || c == ')' || c == ']') depth--;
    }
    // The object's own closing brace: anything past it belongs to whatever
    // the schema declares next.
    if (depth < 0) {
      closed = true;
      break;
    }
  }
  // Without this a scrape that ran off the end of the file — an unbalanced
  // bracket in a comment, a reformat — would return a PREFIX of the schema's
  // keys and gate happily against it, and the keys it lost would be the ones
  // appended most recently: exactly the fields a Dart mirror is behind on.
  if (!closed) {
    throw StateError(
      'Scraped ${keys.length} keys from HandlerSessionSnapshot but never '
      'reached its closing brace, so the tail of the schema went unchecked. '
      'Fix _wireSnapshotKeys before trusting this gate.',
    );
  }
  return keys;
}

/// The key names declared inside the nested `z.object({…})` that top-level
/// [field] holds, e.g. `total` and `items` for `instructions`.
Set<String> _nestedWireKeys(String source, String field) {
  final keys = <String>{};
  final start = source.indexOf('const HandlerSessionSnapshot = z.object({');
  final open = source.indexOf('$field: z.object({', start);
  if (start < 0 || open < 0) {
    throw StateError(
      'Could not find a nested "$field: z.object({" inside '
      'HandlerSessionSnapshot — the schema moved and this gate is scraping '
      'nothing.',
    );
  }
  var depth = 0;
  for (final raw in const LineSplitter().convert(
    source.substring(open + '$field: z.object({'.length),
  )) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (depth == 0) {
      final m = _keyLine.firstMatch(line);
      if (m != null) keys.add(m.group(1)!);
    }
    for (final c in line.split('')) {
      if (c == '{' || c == '(' || c == '[') depth++;
      if (c == '}' || c == ')' || c == ']') depth--;
    }
    if (depth < 0) break;
  }
  return keys;
}

final _keyLine = RegExp(r'^(\w+):');

/// The source of `HandlerSessionState.fromWire`, from its signature up to its
/// closing brace. Comments are stripped, so a field named only in prose cannot
/// satisfy the gate.
String _fromWireSource(String source) {
  const startMarker = '  static HandlerSessionState? fromWire(dynamic json) {';
  final start = source.indexOf(startMarker);
  if (start < 0) {
    throw StateError(
      'Could not find HandlerSessionState.fromWire at "$startMarker" — the '
      'scrape marker in this test has drifted from the source.',
    );
  }
  final lines = const LineSplitter().convert(source.substring(start));
  final body = StringBuffer();
  var closed = false;
  for (final line in lines) {
    if (line.trimRight() == '  }') {
      closed = true;
      break;
    }
    final comment = line.indexOf('//');
    body.writeln(comment < 0 ? line : line.substring(0, comment));
  }
  if (!closed) {
    throw StateError(
      'Found HandlerSessionState.fromWire but never its terminator "  }" — '
      'the scrape marker in this test has drifted from the source.',
    );
  }
  return body.toString();
}

void main() {
  // An app-only checkout has no bridge tree. Skipping loudly beats failing:
  // this gate is about drift between two trees, and only one of them is here.
  final missing = _protocol.existsSync()
      ? null
      : 'No bridge tree at ${_protocol.absolute.path} — the session-snapshot '
            'mirror gate needs both halves of the boundary it couples.';

  group('session snapshot shape mirror gate', skip: missing, () {
    late final Set<String> wireKeys;
    late final String fromWireSource;

    setUpAll(() {
      wireKeys = _wireSnapshotKeys(_protocol.readAsStringSync());
      fromWireSource = _fromWireSource(
        File('lib/models/handler_state.dart').readAsStringSync(),
      );
    });

    test('the wire scrape found the session snapshot keys', () {
      // A guard against a silent scrape failure (marker drift, a reformatted
      // schema) that would otherwise make the gate below vacuously pass.
      expect(
        wireKeys.length,
        greaterThan(8),
        reason:
            'Only found ${wireKeys.length} keys on HandlerSessionSnapshot — '
            'the scrape likely broke. Fix _wireSnapshotKeys before trusting '
            'this gate.',
      );
      expect(wireKeys, contains('terminalId'));
      expect(wireKeys, contains('backlog'));
      expect(wireKeys, contains('observability'));
      // Every sentinel above sits mid-schema, and the schema appends each new
      // field LAST — so a scrape that stopped early would drop exactly the
      // newest field, the only one a mirror is ever behind on, and still pass.
      // `_wireSnapshotKeys` throwing on a scrape that never reached the
      // schema's closing brace is what actually closes that; this is the
      // cheap tail sentinel beside it.
      expect(wireKeys, contains('instructions'));
      // The nested instructions shape must NOT have leaked into the top level.
      expect(wireKeys, isNot(contains('total')));
      expect(wireKeys, isNot(contains('items')));
    });

    test('fromWire names the keys nested inside a wire field', () {
      // The gate above walks only the top level, so the one hop this schema
      // takes below it — `instructions: { total, items }` — is invisible to
      // it: rename `items` on the bridge and every app silently falls back to
      // the goal-only shape with both trees green.
      final nested = _nestedWireKeys(
        _protocol.readAsStringSync(),
        'instructions',
      );
      expect(nested, {'total', 'items'});
      final offenders = <String>[
        for (final key in nested)
          if (!RegExp("'$key'").hasMatch(fromWireSource)) key,
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'HandlerSessionState.fromWire never reads the nested key(s) '
            '$offenders by name, so the bridge and the app disagree on the '
            'spelling inside `instructions` and every window parses empty.',
      );
    });

    test('fromWire names every wire field', () {
      final offenders = <String>[
        for (final key in wireKeys)
          if (!RegExp('\\b$key\\b').hasMatch(fromWireSource)) key,
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'HandlerSessionState.fromWire has drifted from '
            'HandlerSessionSnapshot, so the field(s) it omits are silently '
            'dropped off every status frame: $offenders. Read it there — even '
            'a bridge-only bound (the wire\'s 5/120 on `instructions`, say) '
            'must still be named, since this gate cannot tell a field that is '
            'read from one that is merely typed past.',
      );
    });
  });
}
