import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';
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

Map<String, dynamic> _briefJson({String taskSummary = 'summary'}) => {
  'taskSummary': taskSummary,
  'willHandle': ['fix lint'],
  'wakeFor': ['destructive ops'],
  'thenItems': ['run tests'],
};

Map<String, dynamic> _sessionJson({
  required String terminalId,
  required int pendingEscalations,
  String state = 'watching',
  bool notifyOnly = false,
  Map<String, dynamic>? brief,
  List<Map<String, dynamic>> escalations = const [],
  String? judgeTool,
  String? judgeModel,
}) => {
  'terminalId': terminalId,
  'notifyOnly': notifyOnly,
  'state': state,
  'pendingEscalations': pendingEscalations,
  'armedAt': 0,
  'doneWhenMet': false,
  'brief': brief ?? _briefJson(),
  'ledger': [],
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

Map<String, dynamic> _escalationJson(String escalationId, {String? kind}) => {
  'escalationId': escalationId,
  'question': 'q',
  'reasoning': 'r',
  'draftReply': 'd',
  'urgency': 'normal',
  'at': 1,
  'kind': ?kind,
};

void main() {
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
        brief: HandlerBrief.fromWire(_briefJson())!,
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
      svc.arm(
        terminalId: 't1',
        brief: HandlerBrief.fromWire(_briefJson())!,
        notifyOnly: false,
      );
      final plain = t.sent.lastWhere((m) => m['type'] == 'handler:configure');
      expect(plain.containsKey('judgeTool'), isFalse);
      expect(plain.containsKey('judgeModel'), isFalse);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test('planResult is surfaced on planResultStream', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    final received = <HandlerPlanResultMessage>[];
    final planSub = svc.planResultStream.listen(received.add);

    t.emit('handler:planResult', {
      'projectId': 'p',
      'terminalId': 't1',
      'fallback': false,
      'brief': _briefJson(taskSummary: 'proposed'),
      'previousBrief': _briefJson(taskSummary: 'previous'),
    });
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.single.terminalId, 't1');
    expect(received.single.fallback, false);
    expect(received.single.brief?['taskSummary'], 'proposed');
    // planResult never mutates HandlerState — only lands on its own stream.
    expect(svc.currentState.sessions, isEmpty);
    // previousBrief is cached for the re-arm flow.
    expect(svc.lastKnownBrief('t1')?.taskSummary, 'previous');

    await planSub.cancel();
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

  test(
    'lastKnownBrief survives the session leaving the status snapshot',
    () async {
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
            brief: _briefJson(taskSummary: 'armed brief'),
          ),
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.sessions.keys, ['t1']);
      expect(svc.lastKnownBrief('t1')?.taskSummary, 'armed brief');

      // t1 disarmed / wrapped up server-side: the next snapshot omits it.
      t.emit('handler:status', {'projectId': 'p', 'sessions': []});
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.sessions, isEmpty);
      expect(svc.lastKnownBrief('t1')?.taskSummary, 'armed brief');

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

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

  test('planResult echo seeds the judge cache', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:planResult', {
      'projectId': 'p',
      'terminalId': 't2',
      'fallback': false,
      'judgeTool': 'opencode',
      'judgeModel': 'sm',
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.lastKnownJudge('t2')?.tool, 'opencode');

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('armed session wins over a stale cache entry', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:planResult', {
      'projectId': 'p',
      'terminalId': 't3',
      'fallback': false,
      'judgeTool': 'opencode',
    });
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(
          terminalId: 't3',
          pendingEscalations: 0,
          judgeTool: 'codex',
        ),
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.lastKnownJudge('t3')?.tool, 'codex');

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

    // …then an edit-arm switching to 'opencode'. No new snapshot yet:
    // reopening the sheet in this window must seed the NEW pick — a stale
    // seed committed by a touched arm would silently revert the choice.
    svc.arm(
      terminalId: 't1',
      brief: const HandlerBrief(
        taskSummary: 's',
        willHandle: ['w'],
        wakeFor: [],
        thenItems: [],
      ),
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
    // this must NOT read back as the stale 'codex' pick, or the briefing
    // sheet would silently re-seed and re-arm it on next open.
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
}
