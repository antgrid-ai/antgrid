import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_entry.dart';

void main() {
  test('defaults mode to terminal when absent', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    });
    expect(e.mode, 'terminal');
  });

  test('parses and round-trips chat mode', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': true,
      'mode': 'chat',
    });
    expect(e.mode, 'chat');
    expect(e.toJson()['mode'], 'chat');
  });

  test('parses and round-trips agentSessionId', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': true,
      'mode': 'chat',
      'agentSessionId': 'thread-123',
    });
    expect(e.agentSessionId, 'thread-123');
    expect(e.toJson()['agentSessionId'], 'thread-123');
  });

  test('agentSessionId defaults to null when absent (disk-only sources)', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    });
    expect(e.agentSessionId, isNull);
    expect(e.toJson().containsKey('agentSessionId'), isFalse);
  });
}
