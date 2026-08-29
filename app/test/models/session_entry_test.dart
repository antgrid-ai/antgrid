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

  group('setup', () {
    Map<String, dynamic> base() => {
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    };

    // The absent case carries the whole compatibility claim: every shared
    // session, every bridge predating the feature, and every disk-only source
    // say nothing about setup, and all three must decode to the entry this
    // build already produced.
    test('an entry with no setup key is the entry that has none', () {
      final e = SessionEntry.fromJson(base());
      expect(e.setup, isNull);
      expect(e.toJson().containsKey('setup'), isFalse);
      expect(
        e,
        const SessionEntry(
          id: 'a',
          name: 'n',
          createdAt: 1,
          lastUsedAt: 1,
          archived: false,
          running: false,
        ),
      );
    });

    test('a setup that is not an object decodes to null, never throws', () {
      expect(SessionEntry.fromJson({...base(), 'setup': null}).setup, isNull);
      expect(
        SessionEntry.fromJson({...base(), 'setup': 'running'}).setup,
        isNull,
      );
    });

    test('a running run decodes every field and round-trips', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'checkoutId': 'worktree-1',
        'checkoutKind': 'managed-worktree',
        'setup': {
          'state': 'running',
          'stepIndex': 1,
          'stepCount': 4,
          'stepName': 'Install dependencies',
          'terminalId': 'worktree-1:setup',
          'pendingStart': true,
          'startedAt': 1700,
        },
      });
      final s = e.setup!;
      expect(s.state, 'running');
      expect(s.stepIndex, 1);
      expect(s.stepCount, 4);
      expect(s.stepName, 'Install dependencies');
      // Verbatim, including the `:setup` suffix: the bridge resolves this id
      // through an identity mapping, so a bare "setup" reaches no terminal.
      expect(s.terminalId, 'worktree-1:setup');
      expect(s.pendingStart, isTrue);
      expect(s.startedAt, 1700);
      expect(s.exitCode, isNull);
      expect(s.finishedAt, isNull);
      expect(SessionEntry.fromJson(e.toJson()), e);
    });

    test('a failed run carries its exit code and one-line reason', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'setup': {
          'state': 'failed',
          'stepIndex': 2,
          'stepCount': 4,
          'stepName': 'Generate Prisma client',
          'exitCode': 7,
          'message': 'Generate Prisma client exited 7',
          'startedAt': 1700,
          'finishedAt': 1900,
        },
      });
      final s = e.setup!;
      expect(s.exitCode, 7);
      expect(s.message, 'Generate Prisma client exited 7');
      expect(s.finishedAt, 1900);
      expect(s.pendingStart, isFalse);
      expect(SessionEntry.fromJson(e.toJson()), e);
    });

    // The bridge owns this vocabulary and may widen it. An unknown value is
    // carried through for the render site to degrade — dropping it here would
    // make "a state this build can't name" indistinguishable from "no setup".
    test('a state this build cannot name survives the decode', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'setup': {'state': 'restoring', 'startedAt': 1},
      });
      expect(e.setup?.state, 'restoring');
      expect(e.toJson()['setup'], containsPair('state', 'restoring'));
    });

    // Absence has to be false: the flag says an agent start is WAITING, and a
    // wrong `true` would leave a surface explaining a queue that isn't there.
    test(
      'pendingStart and the counters default when the bridge omits them',
      () {
        final s = SessionEntry.fromJson({
          ...base(),
          'setup': {'state': 'done', 'startedAt': 5},
        }).setup!;
        expect(s.pendingStart, isFalse);
        expect(s.stepIndex, 0);
        expect(s.stepCount, 0);
      },
    );

    // Without this the transition is invisible to SessionsState's equality and
    // the no-op dedup in _handleUpdated drops every progress push.
    test('two entries differing only in setup are not equal', () {
      final plain = SessionEntry.fromJson(base());
      final preparing = SessionEntry.fromJson({
        ...base(),
        'setup': {'state': 'running', 'startedAt': 1},
      });
      final later = SessionEntry.fromJson({
        ...base(),
        'setup': {
          'state': 'running',
          'stepIndex': 1,
          'stepCount': 4,
          'startedAt': 1,
        },
      });
      expect(preparing, isNot(plain));
      expect(preparing.hashCode, isNot(plain.hashCode));
      expect(later, isNot(preparing));
      expect(later.hashCode, isNot(preparing.hashCode));
    });

    test('copyWith carries the run forward and replaces it', () {
      final entry = SessionEntry.fromJson({
        ...base(),
        'setup': {'state': 'running', 'stepCount': 2, 'startedAt': 1},
      });
      expect(entry.copyWith(running: true).setup, entry.setup);
      const done = SessionSetup(
        state: 'done',
        stepIndex: 1,
        stepCount: 2,
        startedAt: 1,
        finishedAt: 9,
      );
      expect(entry.copyWith(setup: done).setup, done);
    });
  });

  test('parses and round-trips forkedFromSessionId', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
      'forkedFromSessionId': 'source-1',
    });
    expect(e.forkedFromSessionId, 'source-1');
    expect(e.toJson()['forkedFromSessionId'], 'source-1');
    expect(e.copyWith(running: true).forkedFromSessionId, 'source-1');
  });

  test('a session that is not a fork carries no provenance', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    });
    expect(e.forkedFromSessionId, isNull);
    expect(e.toJson().containsKey('forkedFromSessionId'), isFalse);
  });
}
