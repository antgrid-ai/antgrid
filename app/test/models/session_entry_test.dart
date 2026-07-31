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

  test('agentSessionResumable defaults to true when absent', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    });
    expect(e.agentSessionResumable, isTrue);
  });

  test('parses and round-trips agentSessionResumable false', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
      'agentSessionResumable': false,
    });
    expect(e.agentSessionResumable, isFalse);
    expect(e.toJson()['agentSessionResumable'], isFalse);
    expect(SessionEntry.fromJson(e.toJson()), e);
  });

  test('agentSessionResumable participates in equality', () {
    const base = SessionEntry(
      id: 'a',
      name: 'n',
      createdAt: 1,
      lastUsedAt: 1,
      archived: false,
      running: false,
    );
    const gone = SessionEntry(
      id: 'a',
      name: 'n',
      createdAt: 1,
      lastUsedAt: 1,
      archived: false,
      running: false,
      agentSessionResumable: false,
    );
    expect(base, isNot(gone));
    expect(base.copyWith().agentSessionResumable, isTrue);
    expect(gone.copyWith().agentSessionResumable, isFalse);
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
