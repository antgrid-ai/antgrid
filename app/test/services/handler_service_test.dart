import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/handler_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _newSession(FakeAgentTransport t) async {
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'p',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await t.dispose(),
  );
}

Map<String, dynamic> _sessionJson({
  required String terminalId,
  required int pendingEscalations,
  String state = 'watching',
  String goal = 'summary',
  List<Map<String, dynamic>> backlog = const [],
  List<Map<String, dynamic>> escalations = const [],
  String? judgeTool,
  String? judgeModel,
  Object? askAnswer,
}) => {
  'terminalId': terminalId,
  'state': state,
  'pendingEscalations': pendingEscalations,
  'armedAt': 0,
  'goal': goal,
  'backlog': backlog,
  'escalations': escalations,
  'judgeTool': ?judgeTool,
  'judgeModel': ?judgeModel,
  'askAnswer': ?askAnswer,
};

Map<String, dynamic> _sessionEntryJson(String id, {String mode = 'terminal'}) =>
    {
      'id': id,
      'name': id,
      'createdAt': 0,
      'lastUsedAt': 0,
      'archived': false,
      'running': true,
      'mode': mode,
    };

Map<String, dynamic> _snapshotJson({
  String snapshotId = 's1',
  String state = 'available',
}) => {
  'projectId': 'p',
  'snapshotId': snapshotId,
  'terminalId': 't1',
  'at': 5,
  'action': 'force_push',
  'trigger': 'git push --force origin feat/x',
  'summary': 'pre-push SHA abc1234 recorded',
  'state': state,
};

Map<String, dynamic> _wrapUpJson({String wrapUpId = 'w1', int at = 9}) => {
  'wrapUpId': wrapUpId,
  'terminalId': 't1',
  'at': at,
  'goal': 'ship the parser',
  'outcomes': [
    {
      'status': 'done',
      'total': 2,
      'items': ['item a', 'item b'],
    },
  ],
  'blockedTotal': 0,
  'blockedReasons': <String>[],
};

Map<String, dynamic> _escalationJson(
  String escalationId, {
  String? kind,
  List<Map<String, dynamic>>? choices,
  String urgency = 'normal',
  int at = 1,
  bool? nonBlocking,
  List<String>? unblocked,
  List<Map<String, dynamic>>? askOptions,
}) => {
  'escalationId': escalationId,
  'question': 'q',
  'reasoning': 'r',
  'draftReply': 'd',
  'urgency': urgency,
  'at': at,
  'kind': ?kind,
  'choices': ?choices,
  'nonBlocking': ?nonBlocking,
  'unblocked': ?unblocked,
  'askOptions': ?askOptions,
};

const _askOptionsJson = [
  {
    'choiceId': 'keep',
    'label': 'Keep the current schema and note the gap',
    'cost': 'Leaves the migration for later',
  },
  {
    'choiceId': 'migrate',
    'label': 'Write the migration now',
    'cost': 'Another twenty minutes before the tests run',
    'recommended': true,
  },
];

const _choicesJson = [
  {'choiceId': 'approve', 'label': 'Approve', 'text': 'd'},
  {
    'choiceId': 'reject',
    'label': 'Reject',
    'text': 'Do not proceed. Wait for my instructions.',
  },
];

void main() {
  test('a live urgent escalation outranks the ones already listed', () async {
    // The push is what raises the toast, and the status frame that re-sorts
    // arrives milliseconds later — but the user taps in between, and an
    // appended row sat at the bottom of the very list the toast sent them to.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 2,
          state: 'needs_you',
          escalations: [
            _escalationJson('waiting-1', at: 1),
            _escalationJson('waiting-2', at: 2),
          ],
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    t.emit('handler:escalation', {
      'projectId': 'p',
      'escalationId': 'blocking',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'high',
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.escalations.map((e) => e.escalationId), [
      'blocking',
      'waiting-1',
      'waiting-2',
    ]);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('a replayed set comes back banded, not merely in age order', () async {
    // Reconnect replays every unanswered escalation at once. Age order alone
    // put the blocking one last on a list the user opened to unblock it.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 3,
          state: 'needs_you',
          escalations: [
            _escalationJson('waiting', at: 1),
            _escalationJson('blocking', at: 3, urgency: 'high'),
            _escalationJson('waiting-later', at: 2),
          ],
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.escalations.map((e) => e.escalationId), [
      'blocking',
      'waiting',
      'waiting-later',
    ]);

    await svc.dispose();
    await session.close();
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  test(
    'status snapshot replaces sessions and rebuilds escalations from replay',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {}); // unpause the heavy gate

      t.emit('handler:escalation', {
        'projectId': 'p',
        'escalationId': 'e1',
        'terminalId': 't1',
        'question': 'q',
        'reasoning': 'r',
        'draftReply': 'd',
        'urgency': 'normal',
        'at': 1,
      });
      // The snapshot replays the still-unanswered escalation — the flat list
      // is rebuilt from it, so the heavy push and the replay never duplicate.
      t.emit('handler:status', {
        'projectId': 'p',
        'sessions': [
          _sessionJson(
            terminalId: 't1',
            pendingEscalations: 1,
            escalations: [_escalationJson('e1')],
          ),
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.escalations.map((e) => e.escalationId), ['e1']);
      expect(svc.currentState.sessions.keys, ['t1']);
      expect(svc.currentState.pendingEscalations, 1);

      // A second snapshot replaces `sessions` wholesale — t1 is gone, t2 is
      // new — and replays nothing, so the stale escalation row goes with it.
      t.emit('handler:status', {
        'projectId': 'p',
        'sessions': [_sessionJson(terminalId: 't2', pendingEscalations: 0)],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.sessions.keys, ['t2']);
      expect(svc.currentState.escalations, isEmpty);
      expect(svc.currentState.pendingEscalations, 0);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test(
    'status carries per-session judge overrides; arm sends them on the wire',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', {
        'projectId': 'p',
        'defaultTool': 'claude-code',
        'sessions': [
          _sessionJson(
            terminalId: 't1',
            pendingEscalations: 0,
            judgeTool: 'codex',
            judgeModel: 'gpt-5.3-codex',
          ),
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.defaultTool, 'claude-code');
      expect(svc.currentState.sessions['t1']!.judgeTool, 'codex');
      expect(svc.currentState.sessions['t1']!.judgeModel, 'gpt-5.3-codex');

      // Overrides cleared server-side → the next snapshot clears them here too.
      t.emit('handler:status', {
        'projectId': 'p',
        'defaultTool': 'claude-code',
        'sessions': [_sessionJson(terminalId: 't1', pendingEscalations: 0)],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.sessions['t1']!.judgeTool, isNull);
      expect(svc.currentState.sessions['t1']!.judgeModel, isNull);

      svc.arm(
        terminalId: 't1',
        judgeTool: 'opencode',
        judgeModel: 'm1',
      );
      final cfg = t.sent.lastWhere((m) => m['type'] == 'handler:configure');
      expect(cfg['judgeTool'], 'opencode');
      expect(cfg['judgeModel'], 'm1');

      // Arming without touching the judge controls omits the override keys, so
      // the bridge leaves the session's stored judge record alone (no
      // clobber-to-default).
      svc.arm(terminalId: 't1');
      final plain = t.sent.lastWhere((m) => m['type'] == 'handler:configure');
      expect(plain.containsKey('judgeTool'), isFalse);
      expect(plain.containsKey('judgeModel'), isFalse);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test('status carries the session goal and backlog', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 0,
          goal: 'get the tests passing',
          backlog: [
            {
              'id': 'i1',
              'text': 'run the tests',
              'status': 'done',
              'createdAt': 1,
            },
            {
              'id': 'i2',
              'text': 'open a PR',
              'status': 'queued',
              'createdAt': 2,
            },
          ],
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    final s = svc.currentState.sessions['t1']!;
    expect(s.goal, 'get the tests passing');
    expect(s.backlogTotal, 2);
    expect(s.backlogDone, 1);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('escalation floorRule is preserved into HandlerEscalation', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'high',
      'floorRule': 'no destructive git ops',
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      svc.currentState.escalations.single.floorRule,
      'no destructive git ops',
    );

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('judge pick survives disarm via the cache', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    // Status snapshot with an armed session carrying a judge…
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 0,
          judgeTool: 'codex',
          judgeModel: 'm',
        ),
      ],
    });
    // …then one without it (disarmed).
    t.emit('handler:status', {'projectId': 'p', 'sessions': []});
    await Future<void>.delayed(Duration.zero);

    final judge = svc.lastKnownSettings('t1');
    expect(judge?.tool, 'codex');
    expect(judge?.model, 'm');

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('arm() optimistically updates the judge cache before the snapshot '
      'round-trips', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    // Armed session whose snapshot carries judge 'codex'…
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 0,
          judgeTool: 'codex',
          judgeModel: 'm',
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.lastKnownSettings('t1')?.tool, 'codex');

    // …then a re-arm switching to 'opencode'. No new snapshot yet: reopening a
    // picker in this window must seed the NEW pick — a stale seed committed by
    // a touched arm would silently revert the choice.
    svc.arm(
      terminalId: 't1',
      judgeTool: 'opencode',
      judgeModel: '',
    );

    final judge = svc.lastKnownSettings('t1');
    expect(judge?.tool, 'opencode');
    // Explicit '' clears the model, mirroring the bridge's applyJudgeChoice.
    expect(judge?.model, isNull);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('a same-terminal re-arm that clears the judge does not leave the old '
      'pick cached', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    // Armed with an explicit judge…
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 0,
          judgeTool: 'codex',
          judgeModel: 'm',
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.lastKnownSettings('t1')?.tool, 'codex');

    // …then re-armed with the judge cleared back to default. The session
    // stays armed (still present in the snapshot) with null judge fields —
    // this must NOT read back as the stale 'codex' pick, or a picker would
    // silently re-seed and re-arm it on next open.
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [_sessionJson(terminalId: 't1', pendingEscalations: 0)],
    });
    await Future<void>.delayed(Duration.zero);

    final judge = svc.lastKnownSettings('t1');
    expect(judge?.tool, isNull);
    expect(judge?.model, isNull);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('handler:activity prepends newest-first', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:activity', {
      'projectId': 'p',
      'recordId': 'r1',
      'at': 10,
      'terminalId': 't1',
      'decision': 'continue',
      'reason': 'first',
    });
    t.emit('handler:activity', {
      'projectId': 'p',
      'recordId': 'r2',
      'at': 20,
      'terminalId': 't1',
      'decision': 'handle',
      'reason': 'second',
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.activity.map((a) => a.recordId), ['r2', 'r1']);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test(
    'reply routes a chat slot to agent:prompt, not terminal:input',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {}); // unpause the heavy gate

      // The transport is chosen from the sibling SessionsService, not passed in
      // by the caller — so the slot has to actually be known as chat mode.
      t.emit('session:list:result', {
        'projectId': 'p',
        'sessions': [_sessionEntryJson('chat-1', mode: 'chat')],
      });
      t.emit('handler:escalation', {
        'projectId': 'p',
        'terminalId': 'chat-1',
        ..._escalationJson('e1'),
      });
      await Future<void>.delayed(Duration.zero);

      final e = svc.currentState.escalations.single;
      svc.reply(e, 'looks good');

      final sent = t.sent.lastWhere((m) => m['type'] == 'agent:prompt');
      expect(sent['sessionId'], 'chat-1');
      expect(sent['text'], 'looks good');
      expect(sent['requestId'], allOf(isA<String>(), isNotEmpty));
      expect(t.sent.any((m) => m['type'] == 'terminal:input'), isFalse);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test('reply routes a terminal slot to terminal:input, flattened', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('session:list:result', {
      'projectId': 'p',
      'sessions': [_sessionEntryJson('t1')],
    });
    t.emit('handler:escalation', {
      'projectId': 'p',
      'terminalId': 't1',
      ..._escalationJson('e1'),
    });
    await Future<void>.delayed(Duration.zero);

    svc.reply(svc.currentState.escalations.single, 'yes\nand also this');

    final sent = t.sent.lastWhere((m) => m['type'] == 'terminal:input');
    expect(sent['terminalId'], 't1');
    // Each embedded newline would submit as its own PTY line, so the first line
    // answers the prompt and the rest fire at whatever appears next.
    expect(sent['data'], 'yes and also this\r');
    expect(t.sent.any((m) => m['type'] == 'agent:prompt'), isFalse);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('answering a free-text row leaves its sibling prompt pending', () async {
    // The optimistic clear mirrors the bridge's rule (onUserReply keeps every
    // `resolve_in_session` row), so a wholesale local clear would blank the pill
    // over a still-blocked agent until the next status frame put it back.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('session:list:result', {
      'projectId': 'p',
      'sessions': [_sessionEntryJson('chat-1', mode: 'chat')],
    });
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 'chat-1',
          pendingEscalations: 2,
          state: 'needs_you',
          escalations: [
            _escalationJson('e1'),
            _escalationJson('e2', kind: 'resolve_in_session'),
          ],
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    svc.reply(
      svc.currentState.escalations.firstWhere((e) => e.escalationId == 'e1'),
      'looks good',
    );

    final answered = svc.currentState.sessions['chat-1']!;
    expect(answered.pendingEscalations, 1);
    expect(answered.escalations.single.escalationId, 'e2');
    expect(answered.runState, HandlerRunState.needsYou);
    expect(svc.currentState.escalations.map((e) => e.escalationId), ['e2']);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('escalation kind is parsed off the wire and defaults to null', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'terminalId': 'chat-1',
      ..._escalationJson('e1', kind: 'resolve_in_session'),
    });
    t.emit('handler:escalation', {
      'projectId': 'p',
      'terminalId': 't1',
      ..._escalationJson('e2'),
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.escalations, hasLength(2));
    expect(svc.currentState.escalations[0].kind, 'resolve_in_session');
    expect(svc.currentState.escalations[1].kind, isNull);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('kind survives the status-snapshot escalation replay', () async {
    // The app rebuilds its escalation list wholesale from handler:status —
    // if kind were only on the one-shot message, the very next snapshot
    // would erase it and resolve_in_session rows would open the reply sheet.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 'chat-1',
          pendingEscalations: 1,
          state: 'needs_you',
          escalations: [_escalationJson('e1', kind: 'resolve_in_session')],
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.escalations.single.kind, 'resolve_in_session');

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('choices survive the status-snapshot escalation replay', () async {
    // The replay is what rebuilds answerable rows after a reconnect or a
    // restart. Choices only on the one-shot push would turn every replayed
    // decision card back into a plain row the next time status landed.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'terminalId': 't1',
      ..._escalationJson('e1', choices: _choicesJson),
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.escalations.single.choices, hasLength(2));

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 1,
          state: 'needs_you',
          escalations: [_escalationJson('e1', choices: _choicesJson)],
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    final replayed = svc.currentState.escalations.single;
    expect(replayed.choices, hasLength(2));
    expect(replayed.choiceById('approve')!.text, 'd');

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('a snapshot advert lands, then its re-advert replaces it', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:snapshot', _snapshotJson());
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.snapshots.single.action, 'force_push');
    expect(svc.currentState.snapshots.single.undoable, isTrue);

    // The bridge re-sends the same id on every state change, so a second row
    // here would offer an undo the first row already says is spent.
    t.emit('handler:snapshot', _snapshotJson(state: 'undone'));
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.snapshots, hasLength(1));
    expect(svc.currentState.snapshots.single.undoable, isFalse);
    expect(svc.currentState.snapshots.single.undone, isTrue);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('status replays the offers and clears the in-flight undo', () async {
    // The replay is what lets an app that restarted between the advert and the
    // tap still reach the undo.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'snapshots': [_snapshotJson()],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.snapshots.single.snapshotId, 's1');

    svc.undo(svc.currentState.snapshots.single);
    expect(svc.currentState.pendingUndo, {'s1'});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'snapshots': [_snapshotJson(state: 'undone')],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.pendingUndo, isEmpty);
    expect(svc.currentState.snapshots.single.undone, isTrue);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('a status replay does not drop an undo that is still running', () async {
    // Status is re-emitted on any session's activity, and it reports an in-flight
    // undo as still 'available' — the entry only changes state when its own
    // handler:snapshot frame lands. Clearing on that would flip the row back to a
    // live Undo chip mid-push, and the re-tap it invites is discarded silently.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'snapshots': [_snapshotJson()],
    });
    await Future<void>.delayed(Duration.zero);
    svc.undo(svc.currentState.snapshots.single);
    expect(svc.currentState.pendingUndo, {'s1'});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'snapshots': [_snapshotJson()],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.pendingUndo, {'s1'});

    // An id the replay no longer names cannot still be in flight.
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'snapshots': <Map<String, dynamic>>[],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.pendingUndo, isEmpty);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test(
    'a bridge with no snapshots array still delivers its sessions',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);

      t.emit('handler:status', {
        'projectId': 'p',
        'sessions': [_sessionJson(terminalId: 't1', pendingEscalations: 0)],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.sessions.keys, ['t1']);
      expect(svc.currentState.snapshots, isEmpty);
      expect(svc.currentState.wrapUps, isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test('the wrap-up replay survives a status frame with nothing armed', () async {
    // The morning-after case, and the only delivery there is: the bridge emits
    // no per-wrap-up advert, so an app that restarted after the disarm sees the
    // report on this frame or never.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'wrapUps': [_wrapUpJson(at: 9), _wrapUpJson(wrapUpId: 'w0', at: 2)],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.anyArmed, isFalse);
    // Oldest first, like the offers beside them — the section renders reversed.
    expect(
      svc.currentState.wrapUps.map((w) => w.wrapUpId),
      ['w0', 'w1'],
    );
    expect(svc.currentState.wrapUps.last.outcomes.single.total, 2);

    // Wholesale replace, not append: the replay is the bridge's full current
    // set, so an aged-out record leaves rather than accumulating a duplicate.
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
      'wrapUps': [_wrapUpJson(at: 9)],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.wrapUps.map((w) => w.wrapUpId), ['w1']);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('a malformed wrap-up drops itself, not the frame', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [_sessionJson(terminalId: 't1', pendingEscalations: 0)],
      'wrapUps': [
        {'wrapUpId': 'broken'},
        _wrapUpJson(),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.sessions.keys, ['t1']);
    expect(svc.currentState.wrapUps.single.wrapUpId, 'w1');

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('the push and the replay agree about the ask fields', () async {
    // The one thing coupling two separate hand-written field lists: the push
    // builds a HandlerEscalation out of HandlerEscalationMessage, the replay
    // builds one out of HandlerEscalation.fromWire, and a field only one of
    // them reads makes the same row an ask for a moment and a stopped session
    // for the rest of its life.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    final ask = _escalationJson(
      'e1',
      nonBlocking: true,
      unblocked: ['i1', 'i2'],
      askOptions: _askOptionsJson,
    );
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(terminalId: 't1', pendingEscalations: 0, askAnswer: true),
      ],
    });
    t.emit('handler:escalation', {
      'projectId': 'p',
      'terminalId': 't1',
      ...ask,
    });
    await Future<void>.delayed(Duration.zero);
    final pushed = svc.currentState.escalations.single;

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 1,
          state: 'needs_you',
          escalations: [ask],
          askAnswer: true,
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);
    final replayed = svc.currentState.escalations.single;

    expect(pushed.nonBlocking, isTrue);
    expect(replayed.nonBlocking, pushed.nonBlocking);
    expect(replayed.unblocked, pushed.unblocked);
    expect(
      replayed.askOptions?.map(
        (o) => (o.choiceId, o.label, o.cost, o.recommended),
      ),
      pushed.askOptions?.map(
        (o) => (o.choiceId, o.label, o.cost, o.recommended),
      ),
    );
    expect(replayed.askOptions, hasLength(2));

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test(
    'an ask on a bridge that cannot be answered reads as blocking',
    () async {
      // A bridge can read `nonBlocking` off a record a newer bridge wrote and
      // re-emit it faithfully while having no verb that answers one, so the row
      // cannot be its own capability signal. Ungated it would render a one-tap
      // that goes nowhere, or a sheet whose text lands in the PTY.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', {
        'projectId': 'p',
        'sessions': [
          _sessionJson(
            terminalId: 't1',
            pendingEscalations: 1,
            state: 'needs_you',
            escalations: [
              _escalationJson(
                'e1',
                nonBlocking: true,
                askOptions: _askOptionsJson,
              ),
            ],
          ),
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.escalations.single.nonBlocking, isFalse);
      expect(svc.currentState.escalations.single.askOptions, isNull);
      // The session's own copy is gated too, or the pill would say "asked you"
      // over rows the list renders as stopping the agent.
      final gated = svc.currentState.sessions['t1']!;
      expect(gated.escalations.single.nonBlocking, isFalse);
      expect(gated.asksOnly, isFalse);
      // The question itself is untouched and still answerable in the user's own
      // words.
      expect(svc.currentState.escalations.single.question, 'q');

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test('the advert is re-read every emission and never latched', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    Map<String, dynamic> frame({Object? askAnswer}) => {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 1,
          state: 'needs_you',
          escalations: [
            _escalationJson(
              'e1',
              nonBlocking: true,
              unblocked: ['i1'],
              askOptions: _askOptionsJson,
            ),
          ],
          askAnswer: askAnswer,
        ),
      ],
    };

    t.emit('handler:status', frame(askAnswer: true));
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.escalations.single.nonBlocking, isTrue);
    expect(svc.currentState.escalations.single.askOptions, hasLength(2));
    expect(svc.currentState.sessions['t1']!.asksOnly, isTrue);
    // `unblocked` is a claim about the backlog rather than a capability, so it
    // rides through either way and the footer re-derives it.
    expect(svc.currentState.escalations.single.unblocked, ['i1']);

    // A rollback to a bridge that reads the field but cannot answer it takes
    // the ask treatment away again on the very next frame.
    t.emit('handler:status', frame());
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.escalations.single.nonBlocking, isFalse);
    expect(svc.currentState.escalations.single.askOptions, isNull);
    expect(svc.currentState.sessions['t1']!.asksOnly, isFalse);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  group('answering an ask', () {
    /// A session carrying one ask with two options, on a bridge that
    /// advertises it can be told the answer.
    Map<String, dynamic> askFrame({
      Object? askAnswer = true,
      bool nonBlocking = true,
      List<Map<String, dynamic>>? siblings,
    }) => {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't1',
          pendingEscalations: 1 + (siblings?.length ?? 0),
          state: 'needs_you',
          escalations: [
            _escalationJson(
              'ask-1',
              nonBlocking: nonBlocking ? true : null,
              unblocked: ['i1'],
              askOptions: _askOptionsJson,
            ),
            ...?siblings,
          ],
          askAnswer: askAnswer,
        ),
      ],
    };

    /// Every verb that would put words in front of the agent. An answer must
    /// reach none of them: the agent is still working, and what the user chose
    /// belongs to Handler until the judge decides how to relay it.
    void expectNothingReachedTheSession(FakeAgentTransport t) {
      for (final type in const [
        'terminal:input',
        'agent:prompt',
        'handler:dismiss',
      ]) {
        expect(
          t.sent.any((m) => m['type'] == type),
          isFalse,
          reason: 'an answer must not send $type',
        );
      }
    }

    test('a tap sends the id alone, on its own verb', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', askFrame());
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.answerAsk(svc.currentState.escalations.single, 'migrate'),
        isTrue,
      );

      final answers = t.sent.where((m) => m['type'] == 'handler:answer');
      expect(answers, hasLength(1));
      expect(answers.single['terminalId'], 't1');
      expect(answers.single['escalationId'], 'ask-1');
      expect(answers.single['choiceId'], 'migrate');
      // The option's words are judge-authored, so they never travel back: the
      // bridge resolves the label against its own persisted row, which is what
      // makes a label that misrepresents what a tap sends unspellable.
      expect(answers.single.containsKey('text'), isFalse);
      expect(answers.single.containsKey('label'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'handler:instruct'), isFalse);
      expectNothingReachedTheSession(t);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('a tap for an id the row does not offer sends nothing', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', askFrame());
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.answerAsk(svc.currentState.escalations.single, 'opt9'),
        isFalse,
      );
      expect(t.sent.any((m) => m['type'] == 'handler:answer'), isFalse);
      // The question is still standing, so the user can still answer it.
      expect(svc.currentState.escalations, hasLength(1));

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('a row that is not an ask refuses both transports', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', {
        'projectId': 'p',
        'sessions': [
          _sessionJson(
            terminalId: 't1',
            pendingEscalations: 1,
            state: 'needs_you',
            escalations: [_escalationJson('e1')],
            askAnswer: true,
          ),
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final e = svc.currentState.escalations.single;
      expect(svc.answerAsk(e, 'migrate'), isFalse);
      expect(svc.answerAskText(e, 'do the migration'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'handler:answer'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'handler:instruct'), isFalse);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('a bridge that never advertised the verb is sent neither', () async {
      // Both floors agree here on purpose: the emission gate has already
      // rewritten the row as blocking, and the send path reads the advert again
      // rather than trusting that — the advert is the whole of what says this
      // bridge has a verb, and a `handler:answer` it does not know is dropped
      // at its parser with no error frame and nothing logged.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', askFrame(askAnswer: null));
      await Future<void>.delayed(Duration.zero);

      final e = svc.currentState.escalations.single;
      expect(svc.answerAsk(e, 'migrate'), isFalse);
      expect(svc.answerAskText(e, 'keep the schema'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'handler:answer'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'handler:instruct'), isFalse);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('free text rides handler:instruct and stays out of the '
        'instruction drawer', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', askFrame());
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.answerAskText(
          svc.currentState.escalations.single,
          'keep the schema and note the gap',
        ),
        isTrue,
      );

      final sent = t.sent.where((m) => m['type'] == 'handler:instruct');
      expect(sent, hasLength(1));
      expect(sent.single['terminalId'], 't1');
      expect(sent.single['text'], 'keep the schema and note the gap');
      // The id is what tells the bridge this ANSWERS a standing question. A
      // frame without it lifts authorization for the session and is split into
      // backlog items the judge would then drive at the agent.
      expect(sent.single['escalationId'], 'ask-1');
      expectNothingReachedTheSession(t);
      // `instruct`'s pending row is retired by a backlog or `armedAt` move,
      // and an answer the judge merely reads moves neither — so a sentence
      // parked there would hold the drawer's edit lock for the rest of the
      // session.
      expect(svc.currentState.pendingInstructionsFor('t1'), isEmpty);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('a corrected second answer is not refused as a duplicate', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', askFrame());
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.answerAskText(svc.currentState.escalations.single, 'migrate now'),
        isTrue,
      );

      // A snapshot the bridge computed before the answer landed still lists the
      // ask, which is the window a user corrects themselves in.
      t.emit('handler:status', askFrame());
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.answerAskText(
          svc.currentState.escalations.single,
          'no — keep the schema',
        ),
        isTrue,
      );

      expect(t.sent.where((m) => m['type'] == 'handler:instruct'), hasLength(2));
      expect(svc.currentState.pendingInstructionsFor('t1'), isEmpty);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('answering an ask leaves its siblings standing', () async {
      // A submitted line clears a terminal's whole free-text set on both sides
      // of the wire; an answer names one escalation and the bridge retires that
      // row alone, so a sibling dropped here would come back off the next
      // snapshot with the pill flickering behind it.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', askFrame(siblings: [_escalationJson('stop-1')]));
      await Future<void>.delayed(Duration.zero);

      final ask = svc.currentState.escalations.firstWhere(
        (e) => e.escalationId == 'ask-1',
      );
      expect(svc.answerAsk(ask, 'keep'), isTrue);

      expect(svc.currentState.escalations.map((e) => e.escalationId), [
        'stop-1',
      ]);
      final owner = svc.currentState.sessions['t1']!;
      expect(owner.escalations.single.escalationId, 'stop-1');
      expect(owner.pendingEscalations, 1);
      expect(owner.runState, HandlerRunState.needsYou);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });
  });
}
