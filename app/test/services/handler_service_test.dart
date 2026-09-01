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
  bool notifyOnly = false,
  String goal = 'summary',
  List<Map<String, dynamic>> backlog = const [],
  List<Map<String, dynamic>> escalations = const [],
  String? judgeTool,
  String? judgeModel,
}) => {
  'terminalId': terminalId,
  'notifyOnly': notifyOnly,
  'state': state,
  'pendingEscalations': pendingEscalations,
  'armedAt': 0,
  'goal': goal,
  'backlog': backlog,
  'escalations': escalations,
  'judgeTool': ?judgeTool,
  'judgeModel': ?judgeModel,
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

Map<String, dynamic> _escalationJson(
  String escalationId, {
  String? kind,
  List<Map<String, dynamic>>? choices,
  String urgency = 'normal',
  int at = 1,
}) => {
  'escalationId': escalationId,
  'question': 'q',
  'reasoning': 'r',
  'draftReply': 'd',
  'urgency': urgency,
  'at': at,
  'kind': ?kind,
  'choices': ?choices,
};

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
        notifyOnly: false,
        judgeTool: 'opencode',
        judgeModel: 'm1',
      );
      final cfg = t.sent.lastWhere((m) => m['type'] == 'handler:configure');
      expect(cfg['judgeTool'], 'opencode');
      expect(cfg['judgeModel'], 'm1');

      // Arming without touching the judge controls omits the override keys, so
      // the bridge leaves the session's stored judge record alone (no
      // clobber-to-default).
      svc.arm(terminalId: 't1', notifyOnly: false);
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

    final judge = svc.lastKnownJudge('t1');
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
    expect(svc.lastKnownJudge('t1')?.tool, 'codex');

    // …then a re-arm switching to 'opencode'. No new snapshot yet: reopening a
    // picker in this window must seed the NEW pick — a stale seed committed by
    // a touched arm would silently revert the choice.
    svc.arm(
      terminalId: 't1',
      notifyOnly: false,
      judgeTool: 'opencode',
      judgeModel: '',
    );

    final judge = svc.lastKnownJudge('t1');
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
    expect(svc.lastKnownJudge('t1')?.tool, 'codex');

    // …then re-armed with the judge cleared back to default. The session
    // stays armed (still present in the snapshot) with null judge fields —
    // this must NOT read back as the stale 'codex' pick, or a picker would
    // silently re-seed and re-arm it on next open.
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [_sessionJson(terminalId: 't1', pendingEscalations: 0)],
    });
    await Future<void>.delayed(Duration.zero);

    final judge = svc.lastKnownJudge('t1');
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

      await svc.dispose();
      await session.close();
    },
  );
}
