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

  test('checkout binding defaults to the main checkout for old sessions', () {
    final old = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    });
    expect(old.checkoutId, 'main');
    expect(old.checkoutKind, 'main');
    expect(old.checkoutState, 'ready');
  });

  test('checkout binding round-trips without exposing a checkout path', () {
    final entry = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
      'checkoutId': 'worktree-1',
      'checkoutKind': 'managed-worktree',
      'checkoutBranch': 'antgrid/session-a',
      'checkoutState': 'ready',
    });
    expect(entry.toJson()['checkoutBranch'], 'antgrid/session-a');
    expect(entry.toJson().containsKey('path'), isFalse);
    expect(SessionEntry.fromJson(entry.toJson()), entry);
  });

  group('deleting', () {
    Map<String, dynamic> base() => {
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    };

    // Absence has to be false in both directions: an older bridge omits it, and
    // so does every disk-only source. A wrong `true` would strand the row.
    test('is false when the bridge says nothing', () {
      expect(SessionEntry.fromJson(base()).deleting, isFalse);
    });

    test('round-trips true and is omitted when false', () {
      final flagged = SessionEntry.fromJson({...base(), 'deleting': true});
      expect(flagged.deleting, isTrue);
      expect(SessionEntry.fromJson(flagged.toJson()).deleting, isTrue);
      expect(
        SessionEntry.fromJson(base()).toJson().containsKey('deleting'),
        isFalse,
      );
    });

    test('copyWith flips only the flag', () {
      final entry = SessionEntry.fromJson({
        ...base(),
        'running': true,
        'workStatus': 'attention',
        'checkoutId': 'worktree-1',
        'checkoutKind': 'managed-worktree',
        'checkoutBranch': 'antgrid/session-a',
        'checkoutState': 'ready',
      });
      final flagged = entry.copyWith(deleting: true);
      expect(flagged.deleting, isTrue);
      expect(flagged.copyWith(deleting: false), entry);
    });

    // This is what makes the flag observable through SessionsState's equality
    // and the no-op dedup in _handleUpdated — without it the push is dropped.
    test('two entries differing only in the flag are not equal', () {
      final plain = SessionEntry.fromJson(base());
      final flagged = plain.copyWith(deleting: true);
      expect(flagged, isNot(plain));
      expect(flagged.hashCode, isNot(plain.hashCode));
    });
  });
}
