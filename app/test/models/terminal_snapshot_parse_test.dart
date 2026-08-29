import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';

Map<String, dynamic> _snapshot([Map<String, dynamic> extra = const {}]) => {
  'type': 'terminal:snapshot',
  'id': 'x',
  'timestamp': 1,
  'terminalId': 't1',
  'scrollback': 'bytes',
  'seq': 12,
  ...extra,
};

void main() {
  test('composed: true parses through', () {
    final msg = parseAbMessage(_snapshot({'composed': true}));
    expect((msg as TerminalSnapshotMessage).composed, isTrue);
  });

  test('an absent composed reads as the legacy blob', () {
    final msg = parseAbMessage(_snapshot());
    expect(msg, isA<TerminalSnapshotMessage>());
    expect((msg as TerminalSnapshotMessage).composed, isFalse);
  });

  // A value the field cannot mean must degrade to the legacy branch — the one
  // that places its own erase — rather than reject the whole frame: a snapshot
  // dropped for an unreadable optional flag leaves the pane on its
  // pre-departure frame with nothing left to recover it.
  for (final bad in <Object?>['yes', 1, null, <String>[]]) {
    test('a non-bool composed ($bad) parses as false', () {
      final msg = parseAbMessage(_snapshot({'composed': bad}));
      expect(msg, isA<TerminalSnapshotMessage>());
      expect((msg as TerminalSnapshotMessage).composed, isFalse);
    });
  }
}
