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
    expect(e.approvalPolicy, 'default');
  });

  test('parses and round-trips bypass approval policy', () {
    final e = SessionEntry.fromJson({
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': true,
      'approvalPolicy': 'bypass',
    });
    expect(e.approvalPolicy, 'bypass');
    expect(e.toJson()['approvalPolicy'], 'bypass');
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

  group('membership', () {
    Map<String, dynamic> base() => {
      'id': 'a',
      'name': 'n',
      'createdAt': 1,
      'lastUsedAt': 1,
      'archived': false,
      'running': false,
    };

    Map<String, dynamic> ref() => {
      'machineId': 'machine-1',
      'projectId': 'proj-1',
      'sessionId': 'sess-1',
      'machineLabel': 'Studio',
      'projectLabel': 'antgrid',
      'sessionName': 'Trace the leak',
    };

    // The absent case carries the whole compatibility claim: an ordinary
    // session, every bridge predating the feature and every disk-only source
    // say nothing about membership, and all three must decode to the entry this
    // build already produced.
    test('a session that is nobody\'s member parses exactly as before', () {
      final e = SessionEntry.fromJson(base());
      expect(e.members, isEmpty);
      expect(e.memberOf, isNull);
      expect(e.toJson().containsKey('members'), isFalse);
      expect(e.toJson().containsKey('memberOf'), isFalse);
    });

    test('a lead row parses its members and round-trips them', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {...ref(), 'role': 'peer', 'joinedAt': 100, 'state': 'active'},
          {
            ...ref(),
            'sessionId': 'sess-2',
            'role': 'peer',
            'joinedAt': 200,
            'state': 'released-delete-refused',
            'releasedAt': 300,
            'releaseReason': 'WORKTREE_DIRTY',
          },
        ],
      });
      expect(e.members, hasLength(2));
      expect(e.members.first.ref.key, 'machine-1/proj-1/sess-1');
      expect(e.members.first.ref.machineLabel, 'Studio');
      expect(e.members.first.isActive, isTrue);
      expect(e.members.last.isActive, isFalse);
      expect(e.members.last.releaseReason, 'WORKTREE_DIRTY');
      expect(SessionEntry.fromJson(e.toJson()), e);
    });

    test('a peer row parses its lead and round-trips it', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'memberOf': {
          ...ref(),
          'role': 'lead',
          'joinedAt': 100,
          'state': 'active',
        },
      });
      expect(e.memberOf!.ref.sessionName, 'Trace the leak');
      expect(e.memberOf!.role, 'lead');
      expect(e.memberOf!.isOrphaned, isFalse);
      expect(e.members, isEmpty);
      expect(SessionEntry.fromJson(e.toJson()), e);
    });

    test('an orphaned lead is carried, not dropped', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'memberOf': {
          ...ref(),
          'joinedAt': 100,
          'state': 'orphaned',
          'orphanedAt': 400,
        },
      });
      expect(e.memberOf!.isOrphaned, isTrue);
      expect(e.memberOf!.orphanedAt, 400);
      expect(SessionEntry.fromJson(e.toJson()), e);
    });

    // One member the app cannot address must cost its own entry and nothing
    // else — the row is a machine the user is working on.
    test('a malformed member is skipped and the rest of the row survives', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'name': 'kept',
        'members': [
          'not a map',
          {'projectId': 'proj-1', 'sessionId': 'sess-1', 'joinedAt': 1},
          {...ref(), 'joinedAt': 100},
        ],
      });
      expect(e.name, 'kept');
      expect(e.members, hasLength(1));
      expect(e.members.single.ref.sessionId, 'sess-1');
    });

    test('a memberOf with no addressable ref decodes as no membership', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'memberOf': {'machineId': 'machine-1', 'joinedAt': 1},
      });
      expect(e.memberOf, isNull);
    });

    // The bridge owns both vocabularies and may widen them; a member in a state
    // this build cannot name is still a member.
    test('an unrecognised role or state falls back to the default', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {...ref(), 'role': 'captain', 'joinedAt': 1, 'state': 'suspended'},
        ],
        'memberOf': {...ref(), 'joinedAt': 1, 'state': 'estranged'},
      });
      expect(e.members.single.role, 'peer');
      expect(e.members.single.state, 'active');
      expect(e.memberOf!.state, 'active');
      expect(e.memberOf!.isOrphaned, isFalse);
    });

    // This is what makes a membership change observable through SessionsState's
    // equality and the no-op dedup in _handleUpdated — without it the push is
    // dropped and the row never gains its member.
    test('two rows differing only in membership are not equal', () {
      final plain = SessionEntry.fromJson(base());
      final led = SessionEntry.fromJson({
        ...base(),
        'members': [
          {...ref(), 'joinedAt': 1},
        ],
      });
      final peer = SessionEntry.fromJson({
        ...base(),
        'memberOf': {...ref(), 'joinedAt': 1},
      });
      expect(led, isNot(plain));
      expect(led.hashCode, isNot(plain.hashCode));
      expect(peer, isNot(plain));
      expect(peer.hashCode, isNot(plain.hashCode));
    });

    test('copyWith carries both halves forward and replaces them', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {...ref(), 'joinedAt': 1},
        ],
      });
      expect(e.copyWith(running: true).members, e.members);
      const other = SessionMemberOf(
        ref: SessionMemberRef(
          machineId: 'machine-2',
          projectId: 'proj-2',
          sessionId: 'sess-9',
        ),
        joinedAt: 5,
      );
      expect(e.copyWith(memberOf: other).memberOf, other);
    });

    // The card is the one thing on a membership the lead's agent is TOLD, so
    // the nesting has to survive the trip in both directions — the bridge
    // schema nests it and this mirror flattens it.
    test('a Capability Card on a member round-trips the wire shape', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {
            ...ref(),
            'joinedAt': 1,
            'card': {
              'os': {'name': 'linux', 'version': '6.8', 'arch': 'x64'},
              'repo': {
                'label': 'app',
                'remote': 'github.com/acme/app',
                'branch': 'feature/leak',
              },
            },
          },
        ],
      });
      final card = e.members.single.ref.card!;
      expect(card.osName, 'linux');
      expect(card.osVersion, '6.8');
      expect(card.osArch, 'x64');
      expect(card.repoLabel, 'app');
      expect(card.repoRemote, 'github.com/acme/app');
      expect(card.repoBranch, 'feature/leak');

      final again = SessionEntry.fromJson(e.toJson());
      expect(again.members.single.ref.card, card);
      expect(again, e);
    });

    // A machine that answered nothing must still be a member: refusing one over
    // a blank field would cost the human the machine rather than the field.
    test('a member with no card decodes as no card and serialises none', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {...ref(), 'joinedAt': 1},
          {...ref(), 'sessionId': 'sess-2', 'joinedAt': 1, 'card': {}},
          {
            ...ref(),
            'sessionId': 'sess-3',
            'joinedAt': 1,
            'card': {'os': null, 'repo': null},
          },
        ],
      });
      expect(e.members, hasLength(3));
      for (final m in e.members) {
        expect(m.ref.card, isNull);
        expect(m.toJson().containsKey('card'), isFalse);
      }
    });

    // The least load-bearing thing on a membership must never take the machine
    // down with it.
    test('a malformed card costs itself and not the member', () {
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {...ref(), 'joinedAt': 1, 'card': 'linux'},
          {
            ...ref(),
            'sessionId': 'sess-2',
            'joinedAt': 1,
            'card': {
              'os': 7,
              'repo': {'branch': 12, 'remote': 'a/b'},
            },
          },
        ],
      });
      expect(e.members, hasLength(2));
      expect(e.members.first.ref.card, isNull);
      expect(e.members.last.ref.card!.repoBranch, isNull);
      expect(e.members.last.ref.card!.repoRemote, 'a/b');
    });

    // The lead bridge refuses the whole record above its bounds, so a branch
    // name longer than one loses its tail here rather than the membership.
    test('an over-long card value is clamped, not refused', () {
      final long = 'b' * 400;
      final e = SessionEntry.fromJson({
        ...base(),
        'members': [
          {
            ...ref(),
            'joinedAt': 1,
            'card': {
              'repo': {'branch': long},
            },
          },
        ],
      });
      expect(e.members.single.ref.card!.repoBranch, long.substring(0, 250));
    });

    // Equality is what makes a card change observable through SessionsState.
    test('two members differing only in their card are not equal', () {
      SessionEntry withBranch(String branch) => SessionEntry.fromJson({
        ...base(),
        'members': [
          {
            ...ref(),
            'joinedAt': 1,
            'card': {
              'repo': {'branch': branch},
            },
          },
        ],
      });
      expect(withBranch('main'), isNot(withBranch('feature/leak')));
      expect(
        withBranch('main').hashCode,
        isNot(withBranch('feature/leak').hashCode),
      );
    });
  });
}
