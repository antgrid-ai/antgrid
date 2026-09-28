// Proves, by reading the parser's own source, that no `AbMessage` case
// literal collides with a session-frame name — the same guarantee
// `bridge/tests/protocol.test.ts`'s disjointness test proves for the bridge's
// `AbMessageSchema`. Dart has no schema to introspect, so this reads
// `ab_message.dart` as text and collects every `case '<literal>':` instead.
import 'dart:io';

import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _caseLiterals(String source) {
  final pattern = RegExp(r"case '([^']+)':");
  return {for (final m in pattern.allMatches(source)) m.group(1)!};
}

void main() {
  final source = File('lib/models/ab_message.dart').readAsStringSync();
  final caseLiterals = _caseLiterals(source);

  test('the case-literal scan is not vacuous', () {
    expect(caseLiterals, isNotEmpty);
    expect(caseLiterals, contains('agent:hello'));
  });

  test('no AbMessage case literal is a session-frame type', () {
    expect(caseLiterals.intersection(kSessionFrameTypes), isEmpty);
  });

  test('the app parses no bare ping/pong AbMessage', () {
    // Liveness is `session:ping`/`session:pong`, which MachineSession handles
    // below the parser; a `case 'ping':` here would mean some code path still
    // expects the bare names to carry liveness.
    expect(caseLiterals.contains('ping'), isFalse);
    expect(caseLiterals.contains('pong'), isFalse);
  });

  test('parseAbMessage rejects every session-frame type', () {
    for (final type in kSessionFrameTypes) {
      expect(
        parseAbMessage({'type': type, 'id': 'x', 'timestamp': 0}),
        isNull,
        reason: type,
      );
    }
  });
}
