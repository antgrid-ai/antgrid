import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/agent_session_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<void> pumpPastDeltaFlush() => Future<void>.delayed(
    kAgentDeltaFlushInterval + const Duration(milliseconds: 20),
  );

  Future<ProjectSession> newSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  // A relay session starts NOT established: its E2E stream must establish before
  // an RPC can be carried (a send before then is silently dropped). Drive the
  // fake with `t.setEstablished(false)` before use and `t.setEstablished(true)`
  // to simulate the handshake completing (which re-drives hydrators).
  Future<ProjectSession> newRelaySession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.relay,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  test(
    'stateFor starts loading until the first session-scoped agent frame',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      expect(svc.stateFor('p').loading, isTrue);

      t.emit('agent:capabilities', {
        'sessionId': 'p',
        'models': [
          {'id': 'gpt-5.2', 'name': 'GPT-5.2'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.stateFor('p').loading, isFalse);
    },
  );

  test('assembles a turn with an item and applies a delta', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
    t.emit('agent:item-added', {
      'sessionId': 'p',
      'turnId': 't1',
      'itemId': 'i1',
      'item': {
        'itemId': 'i1',
        'kind': 'message',
        'role': 'assistant',
        'text': 'He',
      },
    });
    t.emit('agent:item-delta', {
      'sessionId': 'p',
      'turnId': 't1',
      'itemId': 'i1',
      'textChunk': 'llo',
    });
    await pumpPastDeltaFlush();

    final turn = svc.stateFor('p').turns.single;
    expect(turn.turnId, 't1');
    expect(turn.items.single.text, 'Hello');
  });

  test(
    'stamps item from envelope timestamp; update preserves first-seen',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      const addedMs = 1735730000000; // fixed historical epoch ms (not "now")
      t.emit('agent:turn-start', {
        'sessionId': 'p',
        'turnId': 't1',
        'timestamp': addedMs,
      });
      t.emit('agent:item-added', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'timestamp': addedMs,
        'item': {
          'itemId': 'i1',
          'kind': 'message',
          'role': 'assistant',
          'text': 'hi',
        },
      });
      await Future<void>.delayed(Duration.zero);

      var item = svc.stateFor('p').turns.single.items.single;
      expect(item.timestamp, DateTime.fromMillisecondsSinceEpoch(addedMs));
      expect(
        svc.stateFor('p').turns.single.startedAt,
        DateTime.fromMillisecondsSinceEpoch(addedMs),
      );

      // A later update re-parse carries no time and a newer envelope; the
      // first-seen time must survive so the footer doesn't drift.
      t.emit('agent:item-updated', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'timestamp': addedMs + 60000,
        'item': {
          'itemId': 'i1',
          'kind': 'message',
          'role': 'assistant',
          'text': 'hi there',
        },
      });
      await Future<void>.delayed(Duration.zero);

      item = svc.stateFor('p').turns.single.items.single;
      expect(item.text, 'hi there');
      expect(item.timestamp, DateTime.fromMillisecondsSinceEpoch(addedMs));
    },
  );

  test(
    'routes a delta into a tool_call terminal block, not its text',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      t.emit('agent:item-added', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'c1',
        'item': {
          'itemId': 'c1',
          'kind': 'tool_call',
          'toolKind': 'shell',
          'title': 'ls',
        },
      });
      t.emit('agent:item-delta', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'c1',
        'textChunk': 'a.dart\n',
      });
      t.emit('agent:item-delta', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'c1',
        'textChunk': 'b.dart\n',
      });
      await pumpPastDeltaFlush();

      final item = svc.stateFor('p').turns.single.items.single;
      expect(item.text, isNull); // shell output never becomes the item's text
      final terminal = item.content!.firstWhere((b) => b.type == 'terminal');
      expect(terminal.data, 'a.dart\nb.dart\n');
    },
  );

  test('routes a reasoning delta into the item text', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
    t.emit('agent:item-added', {
      'sessionId': 'p',
      'turnId': 't1',
      'itemId': 'r1',
      'item': {'itemId': 'r1', 'kind': 'reasoning', 'text': ''},
    });
    t.emit('agent:item-delta', {
      'sessionId': 'p',
      'turnId': 't1',
      'itemId': 'r1',
      'textChunk': 'think',
    });
    await pumpPastDeltaFlush();

    expect(svc.stateFor('p').turns.single.items.single.text, 'think');
  });

  test('agent:usage updates session token usage', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:usage', {
      'sessionId': 'p',
      'turnId': 't1',
      'total': {'totalTokens': 1234, 'cacheReadTokens': 100},
      'contextWindow': 200000,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.stateFor('p').usage?.total.totalTokens, 1234);
    expect(svc.stateFor('p').usage?.contextWindow, 200000);
  });

  test(
    'item-updated snapshot replaces the item; turn-end records stopReason',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      t.emit('agent:item-added', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'item': {
          'itemId': 'i1',
          'kind': 'tool_call',
          'status': 'running',
          'title': 'ls',
        },
      });
      t.emit('agent:item-updated', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'item': {
          'itemId': 'i1',
          'kind': 'tool_call',
          'status': 'completed',
          'title': 'ls',
        },
      });
      t.emit('agent:turn-end', {
        'sessionId': 'p',
        'turnId': 't1',
        'stopReason': 'end_turn',
      });
      await Future<void>.delayed(Duration.zero);

      final turn = svc.stateFor('p').turns.single;
      expect(turn.items.single.status, 'completed');
      expect(turn.stopReason, 'end_turn');
    },
  );

  test('permission request is tracked then cleared on resolve', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:permission-request', {
      'sessionId': 'p',
      'permissionId': 'perm-0',
      'title': 'Run?',
      'options': [
        {'optionId': 'ok', 'label': 'Allow', 'kind': 'allow_once'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.stateFor('p').pendingPermissions, hasLength(1));

    svc.resolvePermission('p', 'perm-0', 'ok');
    await Future<void>.delayed(Duration.zero);
    expect(svc.stateFor('p').pendingPermissions, isEmpty);

    final sent = t.sent.firstWhere(
      (m) => m['type'] == 'agent:permission-resolve',
    );
    expect(sent['permissionId'], 'perm-0');
    expect(sent['optionId'], 'ok');
  });

  test(
    'question is tracked then cleared on resolve (answer = option id)',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:question', {
        'sessionId': 'p',
        'questionId': 'q-0',
        'kind': 'single_select',
        'prompt': 'Which branch?',
        'options': [
          {'id': '0', 'label': 'main'},
          {'id': '1', 'label': 'dev'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      final q = svc.stateFor('p').pendingQuestions.single;
      expect(q.prompt, 'Which branch?');
      expect(q.options, hasLength(2));

      svc.resolveQuestion('p', 'q-0', '1');
      await Future<void>.delayed(Duration.zero);
      expect(svc.stateFor('p').pendingQuestions, isEmpty);

      final sent = t.sent.firstWhere(
        (m) => m['type'] == 'agent:question-resolve',
      );
      expect(sent['questionId'], 'q-0');
      expect(sent['answer'], '1');
    },
  );

  test('prompt() sends agent:prompt with the text', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    svc.prompt('p', 'do it');
    await Future<void>.delayed(Duration.zero);
    final sent = t.sent.firstWhere((m) => m['type'] == 'agent:prompt');
    expect(sent['sessionId'], 'p');
    expect(sent['text'], 'do it');
  });

  test('routes turn-start to the matching session id only', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:turn-start', {'sessionId': 's1', 'turnId': 't1'});
    await Future<void>.delayed(Duration.zero);
    expect(svc.stateFor('s1').turns.length, 1);
    expect(svc.stateFor('s2').turns, isEmpty);
  });

  test('prompt sends sessionId = the given session id', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    svc.prompt('s7', 'hello');
    await Future<void>.delayed(Duration.zero);
    expect(t.sent.last['sessionId'], 's7');
    expect(t.sent.last['text'], 'hello');
  });

  test(
    'agent:request-retracted removes the matching pending permission',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:permission-request', {
        'sessionId': 'p',
        'permissionId': 'perm-0',
        'title': 'Run?',
        'options': [
          {'optionId': 'ok', 'label': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.stateFor('p').pendingPermissions, hasLength(1));

      t.emit('agent:request-retracted', {
        'sessionId': 'p',
        'permissionId': 'perm-0',
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.stateFor('p').pendingPermissions, isEmpty);
    },
  );

  test(
    'agent:request-retracted removes the matching pending question',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:question', {
        'sessionId': 'p',
        'questionId': 'q-0',
        'kind': 'text',
        'prompt': 'Note?',
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.stateFor('p').pendingQuestions, hasLength(1));

      t.emit('agent:request-retracted', {
        'sessionId': 'p',
        'questionId': 'q-0',
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.stateFor('p').pendingQuestions, isEmpty);
    },
  );

  test('agent:request-retracted with an unknown id is a no-op', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:question', {
      'sessionId': 'p',
      'questionId': 'q-0',
      'kind': 'text',
      'prompt': 'Note?',
    });
    await Future<void>.delayed(Duration.zero);

    t.emit('agent:request-retracted', {
      'sessionId': 'p',
      'questionId': 'q-other',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.stateFor('p').pendingQuestions, hasLength(1));
  });

  test('agent:capabilities lands in session state (latest wins)', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:capabilities', {
      'sessionId': 'p',
      'models': [
        {'id': 'gpt-5.2', 'name': 'GPT-5.2'},
      ],
      'currentModelId': 'gpt-5.2',
    });
    t.emit('agent:capabilities', {'sessionId': 'p', 'currentModelId': 'other'});
    await Future<void>.delayed(Duration.zero);

    final caps = svc.stateFor('p').capabilities;
    expect(caps?.currentModelId, 'other');
    expect(caps?.models, isEmpty); // latest frame replaces wholesale
  });

  test('setConfig sends agent:set-config', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    svc.setConfig('p', 'model', 'gpt-5.2');
    final msg = t.sent.firstWhere((m) => m['type'] == 'agent:set-config');
    expect(msg['sessionId'], 'p');
    expect(msg['key'], 'model');
    expect(msg['value'], 'gpt-5.2');
  });

  test('revert sends conversation-only agent:session-action target', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    svc.revert('p', turnId: 't1', messageId: 'm1');

    final msg = t.sent.firstWhere((m) => m['type'] == 'agent:session-action');
    expect(msg['sessionId'], 'p');
    expect(msg['action'], 'revert');
    expect(msg['turnId'], 't1');
    expect(msg['messageId'], 'm1');
  });

  test(
    'agent:session-reset clears transcript state for that session',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      t.emit('agent:item-added', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'item': {'itemId': 'i1', 'kind': 'message', 'role': 'user'},
      });
      t.emit('agent:capabilities', {
        'sessionId': 'p',
        'currentModelId': 'gpt-5.2',
      });
      t.emit('agent:usage', {
        'sessionId': 'p',
        'turnId': 't1',
        'total': {'totalTokens': 5000},
        'last': {'totalTokens': 1200},
        'contextWindow': 200000,
      });
      t.emit('agent:usage', {
        'sessionId': 'p',
        'turnId': 'resumed',
        'itemId': 'msg:a1',
        'total': <String, Object?>{},
        'last': {'totalTokens': 900},
      });
      await Future<void>.delayed(Duration.zero);
      final before = svc.stateFor('p');
      expect(before.turns, hasLength(1));
      expect(before.usage, isNotNull);
      expect(before.usageByTurn, isNotEmpty);
      expect(before.usageByItem, isNotEmpty);
      expect(before.capabilities?.currentModelId, 'gpt-5.2');

      t.emit('agent:session-reset', {'sessionId': 'p'});
      await Future<void>.delayed(Duration.zero);

      final after = svc.stateFor('p');
      expect(after.turns, isEmpty);
      expect(after.usage, isNull);
      expect(after.usageByTurn, isEmpty);
      expect(after.usageByItem, isEmpty);
      expect(after.capabilities?.currentModelId, 'gpt-5.2');
    },
  );

  test('prompt carries commandId only when given', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    svc.prompt('p', 'plain text');
    svc.prompt('p', 'src/', commandId: 'cmd:review');
    final prompts = t.sent.where((m) => m['type'] == 'agent:prompt').toList();
    expect(prompts[0].containsKey('commandId'), isFalse);
    expect(prompts[1]['commandId'], 'cmd:review');
    expect(prompts[1]['text'], 'src/');
  });

  test(
    'AgentTurnStart is idempotent by turnId (no duplicate turn on replay)',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      await Future<void>.delayed(Duration.zero);

      expect(svc.stateFor('p').turns.length, 1);
    },
  );

  test('hydrationFailed defaults to false and round-trips via copyWith', () {
    const s = AgentSessionState();
    expect(s.hydrationFailed, isFalse);
    final failed = s.copyWith(hydrationFailed: true);
    expect(failed.hydrationFailed, isTrue);
    final cleared = failed.copyWith(hydrationFailed: false);
    expect(cleared.hydrationFailed, isFalse);
  });

  test(
    'hydrateIfNeeded applies returned frames through the inbound pipe',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.requestHandler = (method, params) {
        expect(method, 'session.transcriptSnapshot');
        expect(params, {'sessionId': 'p'});
        return {
          'frames': [
            {
              'id': '0',
              'timestamp': 1,
              'type': 'agent:turn-start',
              'sessionId': 'p',
              'turnId': 'resumed',
            },
            {
              'id': '1',
              'timestamp': 1,
              'type': 'agent:item-added',
              'sessionId': 'p',
              'turnId': 'resumed',
              'itemId': 'i1',
              'item': {
                'itemId': 'i1',
                'kind': 'message',
                'role': 'assistant',
                'text': 'hi',
              },
            },
            {
              'id': '2',
              'timestamp': 1,
              'type': 'agent:turn-end',
              'sessionId': 'p',
              'turnId': 'resumed',
              'stopReason': 'end_turn',
            },
          ],
        };
      };

      await svc.hydrateIfNeeded('p');

      final turn = svc.stateFor('p').turns.single;
      expect(turn.turnId, 'resumed');
      expect(turn.items.single.text, 'hi');
      expect(svc.stateFor('p').hydrationFailed, isFalse);
    },
  );

  test(
    'relay hydration defers until the transport is ready, then drives the pull',
    () async {
      final t = FakeAgentTransport()..setEstablished(false);
      final session = await newRelaySession(t);
      final svc = AgentSessionService.fromSession(session);

      t.requestHandler = (method, params) => {
        'frames': [
          {
            'id': '0',
            'timestamp': 1,
            'type': 'agent:turn-start',
            'sessionId': 'p',
            'turnId': 'resumed',
          },
          {
            'id': '1',
            'timestamp': 1,
            'type': 'agent:turn-end',
            'sessionId': 'p',
            'turnId': 'resumed',
            'stopReason': 'end_turn',
          },
        ],
      };

      // Not yet established: firing the transcript RPC now would be silently
      // dropped by the relay stream and burn its full timeout, so the pull must
      // be DEFERRED, not sent. The view meanwhile shows the loading spinner.
      await svc.hydrateIfNeeded('p');
      expect(t.requests, isEmpty);
      expect(svc.stateFor('p').loading, isTrue);

      // Establishment re-drives the registered hydrator (as refreshSnapshot does
      // on each handshake) — the fix that makes the transcript ride the
      // establishment wave like the durable snapshot does.
      t.setEstablished(true);
      await Future<void>.delayed(Duration.zero);

      expect(t.requests.single.method, 'session.transcriptSnapshot');
      expect(svc.stateFor('p').turns.single.turnId, 'resumed');
      expect(svc.stateFor('p').loading, isFalse);
    },
  );

  test('stopHydrating deregisters the transcript hydrator so a reconnect no '
      'longer re-pulls that session', () async {
    final t = FakeAgentTransport();
    final session = await newRelaySession(t);
    final svc = AgentSessionService.fromSession(session);

    t.requestHandler = (method, params) => {'frames': <dynamic>[]};

    // Established: one snapshot pull on the initial hydrate.
    await svc.hydrateIfNeeded('p');
    expect(t.requests.length, 1);

    // The view is gone. A subsequent (re)establishment must NOT re-pull the
    // now-unviewed session — otherwise every session ever opened would
    // re-fetch its transcript on each reconnect.
    svc.stopHydrating('p');
    t.setEstablished(false);
    t.setEstablished(true); // re-drives every STILL-registered hydrator
    await Future<void>.delayed(Duration.zero);

    expect(t.requests.length, 1);
  });

  test('hydrateIfNeeded sets hydrationFailed on RPC failure', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.requestHandler = (method, params) => throw Exception('boom');

    await svc.hydrateIfNeeded('p');

    expect(svc.stateFor('p').hydrationFailed, isTrue);
    expect(svc.stateFor('p').turns, isEmpty);
  });

  test(
    'a successful but empty hydrate clears loading (idle running session)',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      // The seed state is loading:true until something lands.
      expect(svc.stateFor('p').loading, isTrue);

      // An idle running session with no completed turns snapshots empty.
      t.requestHandler = (method, params) => {'frames': <dynamic>[]};
      await svc.hydrateIfNeeded('p');

      // Without the fix the transcript would spin on AbLoading forever.
      expect(svc.stateFor('p').loading, isFalse);
      expect(svc.stateFor('p').turns, isEmpty);
      expect(svc.stateFor('p').hydrationFailed, isFalse);
    },
  );

  test(
    'a turn-end retries hydration once when the snapshot came back empty',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.requestHandler = (method, params) => {'frames': <dynamic>[]};

      await svc.hydrateIfNeeded('p');
      expect(t.requests.length, 1);

      // The live turn this attach caught mid-flight now closes.
      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 'live-1'});
      t.emit('agent:turn-end', {
        'sessionId': 'p',
        'turnId': 'live-1',
        'stopReason': 'end_turn',
      });
      await Future<void>.delayed(Duration.zero);

      expect(t.requests.length, 2);
      expect(t.requests.last.method, 'session.transcriptSnapshot');

      // A SECOND turn-end must NOT trigger a third call — one-shot per attempt.
      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 'live-2'});
      t.emit('agent:turn-end', {
        'sessionId': 'p',
        'turnId': 'live-2',
        'stopReason': 'end_turn',
      });
      await Future<void>.delayed(Duration.zero);

      expect(t.requests.length, 2);
    },
  );

  group('agent:usage routing', () {
    test('live frame updates meter usage and usageByTurn', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:usage', {
        'sessionId': 'p',
        'turnId': 't1',
        'total': {'totalTokens': 5000},
        'last': {'totalTokens': 1200, 'inputTokens': 1000, 'outputTokens': 200},
        'contextWindow': 200000,
      });
      await Future<void>.delayed(Duration.zero);

      final s = svc.stateFor('p');
      expect(s.usage?.contextWindow, 200000);
      expect(s.usage?.last?.totalTokens, 1200);
      expect(s.usageByTurn['t1']?.totalTokens, 1200);
      expect(s.usageByItem, isEmpty);
    });

    test('itemId frame updates ONLY usageByItem, never the meter', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:usage', {
        'sessionId': 'p',
        'turnId': 't-live',
        'total': {'totalTokens': 5000},
        'contextWindow': 200000,
      });
      t.emit('agent:usage', {
        'sessionId': 'p',
        'turnId': 'resumed',
        'itemId': 'msg:a1',
        'total': <String, Object?>{},
        'last': {'totalTokens': 900},
      });
      await Future<void>.delayed(Duration.zero);

      final s = svc.stateFor('p');
      expect(s.usageByItem['msg:a1']?.totalTokens, 900);
      expect(s.usage?.total.totalTokens, 5000);
      expect(s.usage?.contextWindow, 200000);
      expect(s.usageByTurn.containsKey('resumed'), isFalse);
    });

    test(
      'a frame without contextWindow keeps the previously known window',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = AgentSessionService.fromSession(session);

        t.emit('agent:usage', {
          'sessionId': 'p',
          'total': <String, Object?>{},
          'contextWindow': 200000,
        });
        t.emit('agent:usage', {
          'sessionId': 'p',
          'turnId': 't1',
          'total': {'totalTokens': 7000},
        });
        await Future<void>.delayed(Duration.zero);

        final s = svc.stateFor('p');
        expect(s.usage?.total.totalTokens, 7000);
        expect(s.usage?.contextWindow, 200000);
      },
    );
  });

  test(
    'agent:transcript-replay unwraps into a fully-formed, closed turn',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      // The bridge batches a resumed transcript into ONE frame so the relay
      // can't drop its tail (which carries turn-end) past the rate limit.
      t.emit('agent:transcript-replay', {
        'sessionId': 'p',
        'frames': [
          {'type': 'agent:turn-start', 'sessionId': 'p', 'turnId': 'resumed'},
          {
            'type': 'agent:item-added',
            'sessionId': 'p',
            'turnId': 'resumed',
            'itemId': 'i1',
            'item': {
              'itemId': 'i1',
              'kind': 'message',
              'role': 'user',
              'text': 'old q',
            },
          },
          {
            'type': 'agent:turn-end',
            'sessionId': 'p',
            'turnId': 'resumed',
            'stopReason': 'end_turn',
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final turns = svc.stateFor('p').turns;
      expect(turns.length, 1);
      expect(turns.single.items.single.text, 'old q');
      // The turn must be CLOSED: an open last turn is what renders the session
      // as running forever with a stop button that can do nothing.
      expect(turns.single.stopReason, 'end_turn');
    },
  );

  test(
    'a snapshot REPLACES live turns it renumbers, rather than doubling them',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      // claude's disk replay numbers turns `resumed:N`; the same turn went out
      // live as `turn-N`. Nothing dedups those two ids, so an appending reducer
      // renders the whole conversation twice.
      Map<String, dynamic> turnFrames(String turnId) => {
        'sessionId': 'p',
        'frames': [
          {'type': 'agent:turn-start', 'sessionId': 'p', 'turnId': turnId},
          {
            'type': 'agent:item-added',
            'sessionId': 'p',
            'turnId': turnId,
            'itemId': 'i1',
            'item': {
              'itemId': 'i1',
              'kind': 'message',
              'role': 'user',
              'text': 'hello',
            },
          },
          {
            'type': 'agent:turn-end',
            'sessionId': 'p',
            'turnId': turnId,
            'stopReason': 'end_turn',
          },
        ],
      };

      t.requestHandler = (method, params) => {'frames': <dynamic>[]};
      await svc.hydrateIfNeeded('p');

      // The live turn, then the retry the empty snapshot armed — which now
      // answers with the same turn under the replay's id space.
      for (final f in turnFrames('turn-0')['frames'] as List) {
        t.emit(f['type'] as String, f as Map<String, dynamic>);
      }
      t.requestHandler = (method, params) => turnFrames('resumed:0');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final turns = svc.stateFor('p').turns;
      expect(turns.length, 1);
      expect(turns.single.turnId, 'resumed:0');
    },
  );

  test(
    'an empty snapshot leaves a live transcript alone, rather than wiping it',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 'turn-0'});
      t.emit('agent:turn-end', {
        'sessionId': 'p',
        'turnId': 'turn-0',
        'stopReason': 'end_turn',
      });
      await Future<void>.delayed(Duration.zero);

      // A driver that can't read its own store reports an empty snapshot.
      t.requestHandler = (method, params) => {'frames': <dynamic>[]};
      await svc.hydrateIfNeeded('p');

      expect(svc.stateFor('p').turns.length, 1);
    },
  );

  test('a snapshot keeps the open turn it cannot carry', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    // The in-flight turn has no turn-end yet, so no snapshot reports it — it
    // must survive the replace, and stay last.
    t.requestHandler = (method, params) => {
      'frames': [
        {
          'id': '0',
          'timestamp': 1,
          'type': 'agent:turn-start',
          'sessionId': 'p',
          'turnId': 'resumed:0',
        },
        {
          'id': '1',
          'timestamp': 1,
          'type': 'agent:turn-end',
          'sessionId': 'p',
          'turnId': 'resumed:0',
          'stopReason': 'end_turn',
        },
      ],
    };

    t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 'live-1'});
    await Future<void>.delayed(Duration.zero);

    await svc.hydrateIfNeeded('p');

    final turns = svc.stateFor('p').turns;
    expect(turns.map((t) => t.turnId), ['resumed:0', 'live-1']);
    expect(svc.stateFor('p').openTurn?.turnId, 'live-1');
  });

  group('a snapshot that names the bridge live turn', () {
    // A phone that went away mid-turn and came back after it finished: the
    // turn-end never reached it, so it still holds the half-streamed turn open.
    // The reconnect's snapshot carries the finished turn renumbered, which is
    // why only the named live turn can say whether the open one survives.
    Map<String, dynamic> snapshot(Object? activeTurnId) => {
      'frames': [
        {
          'type': 'agent:turn-start',
          'sessionId': 'p',
          'turnId': 'resumed:0',
        },
        {
          'type': 'agent:item-added',
          'sessionId': 'p',
          'turnId': 'resumed:0',
          'itemId': 'a1',
          'item': {
            'itemId': 'a1',
            'kind': 'message',
            'role': 'assistant',
            'text': 'the whole answer',
          },
        },
        {
          'type': 'agent:turn-end',
          'sessionId': 'p',
          'turnId': 'resumed:0',
          'stopReason': 'end_turn',
        },
      ],
      'activeTurnId': activeTurnId,
    };

    Future<AgentSessionService> midTurn(FakeAgentTransport t) async {
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 'turn-0'});
      t.emit('agent:item-added', {
        'sessionId': 'p',
        'turnId': 'turn-0',
        'itemId': 'a1',
        'item': {
          'itemId': 'a1',
          'kind': 'message',
          'role': 'assistant',
          'text': 'the whole',
        },
      });
      await Future<void>.delayed(Duration.zero);
      return svc;
    }

    test('drops the open turn once the bridge is idle', () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      t.requestHandler = (method, params) => snapshot(null);

      await svc.hydrateIfNeeded('p');

      final s = svc.stateFor('p');
      expect(s.turns.map((t) => t.turnId), ['resumed:0']);
      expect(s.openTurn, isNull);
      expect(s.turns.single.items.single.text, 'the whole answer');
    });

    test('drops the open turn when a different turn is live', () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      t.requestHandler = (method, params) => snapshot('turn-1');

      await svc.hydrateIfNeeded('p');

      expect(svc.stateFor('p').turns.map((t) => t.turnId), ['resumed:0']);
    });

    test('closes an ended open turn even when the snapshot is empty', () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'activeTurnId': null,
      };

      await svc.hydrateIfNeeded('p');

      final s = svc.stateFor('p');
      expect(s.turns.single.turnId, 'turn-0');
      expect(s.openTurn, isNull);
    });

    test('merges the live turn when the snapshot carries it', () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      // The bridge relabelled its mid-turn replay to the live id: it carries
      // what streamed while we were away (a2), we carry the rest (a1).
      t.requestHandler = (method, params) => {
        'frames': [
          {'type': 'agent:turn-start', 'sessionId': 'p', 'turnId': 'turn-0'},
          for (final id in ['a1', 'a2'])
            {
              'type': 'agent:item-added',
              'sessionId': 'p',
              'turnId': 'turn-0',
              'itemId': id,
              'item': {
                'itemId': id,
                'kind': 'message',
                'role': 'assistant',
                'text': 'disk $id',
              },
            },
        ],
        'activeTurnId': 'turn-0',
      };

      await svc.hydrateIfNeeded('p');

      final s = svc.stateFor('p');
      expect(s.turns, hasLength(1));
      expect(s.openTurn?.turnId, 'turn-0');
      expect(s.openTurn!.items.map((i) => i.text), ['the whole', 'disk a2']);
    });

    test('keeps the open turn the bridge is still streaming', () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      t.requestHandler = (method, params) => snapshot('turn-0');

      await svc.hydrateIfNeeded('p');

      final s = svc.stateFor('p');
      expect(s.turns.map((t) => t.turnId), ['resumed:0', 'turn-0']);
      expect(s.openTurn?.turnId, 'turn-0');
    });

    test('hydration never rewrites a turn list or item list it already '
        'published', () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      final heldTurns = svc.stateFor('p').turns;
      final heldTurn = heldTurns.single;
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'activeTurnId': null,
      };

      await svc.hydrateIfNeeded('p');

      expect(heldTurns, hasLength(1));
      expect(identical(heldTurns.single, heldTurn), isTrue);
      expect(heldTurn.stopReason, isNull);
      expect(svc.stateFor('p').turns.single.stopReason, 'end_turn');

      // The held open turn is re-appended inside the fold, and the live frame
      // then upserts into it within that same fold.
      final t2 = FakeAgentTransport();
      final svc2 = await midTurn(t2);
      final heldItems = svc2.stateFor('p').turns.single.items;
      t2.requestHandler = (method, params) => {
        ...snapshot('turn-0'),
        'live': [
          {
            'type': 'agent:item-added',
            'sessionId': 'p',
            'turnId': 'turn-0',
            'itemId': 'a2',
            'item': {
              'itemId': 'a2',
              'kind': 'message',
              'role': 'assistant',
              'text': 'more',
            },
          },
        ],
      };

      await svc2.hydrateIfNeeded('p');

      expect(heldItems, hasLength(1));
      expect(heldItems.single.text, 'the whole');
      final s = svc2.stateFor('p');
      expect(s.turns.map((t) => t.turnId), ['resumed:0', 'turn-0']);
      expect(s.turns.last.items.map((i) => i.text), ['the whole', 'more']);
    });

    test('an item in the snapshot live set lands on the merged open turn',
        () async {
      final t = FakeAgentTransport();
      final svc = await midTurn(t);
      t.requestHandler = (method, params) => {
        'frames': [
          {'type': 'agent:turn-start', 'sessionId': 'p', 'turnId': 'turn-0'},
          for (final id in ['a1', 'a2'])
            {
              'type': 'agent:item-added',
              'sessionId': 'p',
              'turnId': 'turn-0',
              'itemId': id,
              'item': {
                'itemId': id,
                'kind': 'message',
                'role': 'assistant',
                'text': 'disk $id',
              },
            },
        ],
        'activeTurnId': 'turn-0',
        'live': [
          {
            'type': 'agent:item-added',
            'sessionId': 'p',
            'turnId': 'turn-0',
            'itemId': 'a3',
            'item': {
              'itemId': 'a3',
              'kind': 'message',
              'role': 'assistant',
              'text': 'live a3',
            },
          },
        ],
      };

      await svc.hydrateIfNeeded('p');

      expect(svc.stateFor('p').openTurn!.items.map((i) => i.text), [
        'the whole',
        'disk a2',
        'live a3',
      ]);
    });
  });

  group('a snapshot live set', () {
    Map<String, dynamic> perm(String id) => {
      'type': 'agent:permission-request',
      'sessionId': 'p',
      'permissionId': id,
      'title': 'Run?',
      'options': [
        {'optionId': 'ok', 'label': 'Allow', 'kind': 'allow_once'},
      ],
    };

    test('replaces the prompts: missed ones appear, answered-elsewhere ones '
        'go', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.emit('agent:permission-request', perm('answered-on-desktop'));
      await Future<void>.delayed(Duration.zero);
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'live': [
          perm('raised-while-away'),
          {
            'type': 'agent:question',
            'sessionId': 'p',
            'questionId': 'q1',
            'kind': 'text',
            'prompt': '?',
          },
        ],
      };

      await svc.hydrateIfNeeded('p');

      final s = svc.stateFor('p');
      expect(s.pendingPermissions.map((p) => p.permissionId), [
        'raised-while-away',
      ]);
      expect(s.pendingQuestions.map((q) => q.questionId), ['q1']);
    });

    test('a prompt answered here that the bridge read before the answer '
        'returns, then clears on its retraction', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.emit('agent:permission-request', perm('perm-0'));
      await Future<void>.delayed(Duration.zero);
      svc.resolvePermission('p', 'perm-0', 'ok');
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'live': [perm('perm-0')],
      };

      await svc.hydrateIfNeeded('p');
      expect(
        svc.stateFor('p').pendingPermissions.map((p) => p.permissionId),
        ['perm-0'],
      );

      t.emit('agent:request-retracted', {
        'sessionId': 'p',
        'permissionId': 'perm-0',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.stateFor('p').pendingPermissions, isEmpty);
    });

    test('restores the usage meter', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'live': [
          {
            'type': 'agent:usage',
            'sessionId': 'p',
            'total': {'totalTokens': 42},
            'contextWindow': 1000,
          },
        ],
      };

      await svc.hydrateIfNeeded('p');

      expect(svc.stateFor('p').usage?.contextWindow, 1000);
    });
  });

  group('a snapshot update state', () {
    Map<String, dynamic> result(String sessionId) => {
      'type': 'agent:updateResult',
      'tool': 'claude-code',
      'sessionId': sessionId,
      'ok': true,
    };

    test('settles a spinner whose result landed while away', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      svc.requestUpdate('p', 'claude-code');
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'update': {'running': false, 'result': result('other-session')},
      };

      await svc.hydrateIfNeeded('p');

      final s = svc.stateFor('p');
      expect(s.updating, isFalse);
      expect(s.updateResult?.ok, isTrue);
    });

    test('keeps spinning while the update still runs', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      svc.requestUpdate('p', 'claude-code');
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'update': {'running': true},
      };

      await svc.hydrateIfNeeded('p');

      expect(svc.stateFor('p').updating, isTrue);
    });

    test('never re-raises a result nobody is waiting for', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.requestHandler = (method, params) => {
        'frames': <dynamic>[],
        'update': {'running': false, 'result': result('p')},
      };

      await svc.hydrateIfNeeded('p');

      expect(svc.stateFor('p').updateResult, isNull);
    });
  });

  test(
    'cancel names the turn the UI shows as running, so the bridge can close it',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = AgentSessionService.fromSession(session);

      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      await Future<void>.delayed(Duration.zero);
      t.clearSent();

      svc.cancel('p');
      final cancels = t.sent.where((m) => m['type'] == 'agent:cancel').toList();
      expect(cancels.length, 1);
      expect(cancels.single['turnId'], 't1');
    },
  );

  test('reduces agent:background-tasks latest-wins', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:background-tasks', {
      'sessionId': 'p',
      'tasks': [
        {
          'taskId': 'task-1',
          'kind': 'shell',
          'title': 'bun dev',
          'status': 'running',
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.stateFor('p').backgroundTasks?.tasks, hasLength(1));
    expect(svc.stateFor('p').backgroundTasks?.tasks.single.taskId, 'task-1');

    // The settle frame replaces the whole list.
    t.emit('agent:background-tasks', {'sessionId': 'p', 'tasks': const []});
    await Future<void>.delayed(Duration.zero);
    expect(svc.stateFor('p').backgroundTasks?.tasks, isEmpty);
  });

  test('stopTask sends agent:task-stop', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    svc.stopTask('p', 'task-1');

    final sent = t.sent.last;
    expect(sent['type'], 'agent:task-stop');
    expect(sent['sessionId'], 'p');
    expect(sent['taskId'], 'task-1');
  });

  test('background tasks survive a session reset', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = AgentSessionService.fromSession(session);

    t.emit('agent:background-tasks', {
      'sessionId': 'p',
      'tasks': [
        {
          'taskId': 'task-1',
          'kind': 'shell',
          'title': 'bun dev',
          'status': 'running',
        },
      ],
    });
    t.emit('agent:session-reset', {'sessionId': 'p'});
    await Future<void>.delayed(Duration.zero);
    // A rollback does not kill background processes — the list carries over.
    expect(svc.stateFor('p').backgroundTasks?.tasks, hasLength(1));
  });

  group('batch replay and streaming', () {
    Map<String, dynamic> frame(
      String type,
      int ts, [
      Map<String, dynamic> extra = const {},
    ]) => {
      'id': 'f$ts',
      'timestamp': ts,
      'type': type,
      'sessionId': 'p',
      ...extra,
    };

    Map<String, dynamic> itemAdded(
      String turnId,
      String itemId,
      int ts, {
      String kind = 'message',
      String role = 'assistant',
      String? text,
      String? status,
    }) => frame('agent:item-added', ts, {
      'turnId': turnId,
      'itemId': itemId,
      'item': {
        'itemId': itemId,
        'kind': kind,
        'role': role,
        'text': ?text,
        'status': ?status,
      },
    });

    List<Map<String, dynamic>> threeTurns() => [
      for (var n = 0; n < 3; n++) ...[
        frame('agent:turn-start', 1, {'turnId': 'r$n'}),
        itemAdded('r$n', 'u$n', 1, role: 'user', text: 'q$n'),
        itemAdded('r$n', 'a$n', 1, text: 'a$n'),
        frame('agent:turn-end', 1, {
          'turnId': 'r$n',
          'stopReason': 'end_turn',
        }),
      ],
    ];

    test('a transcript snapshot reaches listeners as one state', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      final seen = <AgentSessionState>[];
      svc.stateStreamFor('p').listen(seen.add);
      t.requestHandler = (method, params) => {'frames': threeTurns()};

      await svc.hydrateIfNeeded('p');
      await Future<void>.delayed(Duration.zero);

      final withTurns = seen.where((s) => s.turns.isNotEmpty).toList();
      expect(withTurns, hasLength(1));
      expect(withTurns.single.turns.map((t) => t.turnId), ['r0', 'r1', 'r2']);
      expect(withTurns.single.turns.every((t) => t.items.length == 2), isTrue);
      expect(withTurns.single.loading, isFalse);
      expect(identical(seen.last, svc.stateFor('p')), isTrue);
    });

    test('a pushed transcript replay reaches listeners as one state', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      final seen = <AgentSessionState>[];
      svc.stateStreamFor('p').listen(seen.add);

      t.emit('agent:transcript-replay', {
        'sessionId': 'p',
        'frames': threeTurns(),
      });
      await Future<void>.delayed(Duration.zero);

      final withTurns = seen.where((s) => s.turns.isNotEmpty).toList();
      expect(withTurns, hasLength(1));
      final turns = withTurns.single.turns;
      expect(turns.map((t) => t.turnId), ['r0', 'r1', 'r2']);
      expect(turns.every((t) => t.stopReason == 'end_turn'), isTrue);
      expect(turns.every((t) => t.items.length == 2), isTrue);
    });

    test('a streamed delta copies only the turn it lands in', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      for (var n = 0; n < 20; n++) {
        t.emitJson(frame('agent:turn-start', 1, {'turnId': 's$n'}));
        t.emitJson(itemAdded('s$n', 'm$n', 1, text: 'x'));
        t.emitJson(
          frame('agent:turn-end', 1, {
            'turnId': 's$n',
            'stopReason': 'end_turn',
          }),
        );
      }
      t.emitJson(frame('agent:turn-start', 1, {'turnId': 'open'}));
      t.emitJson(itemAdded('open', 'live', 1, text: 'He'));
      await Future<void>.delayed(Duration.zero);
      final before = svc.debugCollectionCopies;
      final prior = svc.stateFor('p');

      t.emitJson(
        frame('agent:item-delta', 1, {
          'turnId': 'open',
          'itemId': 'live',
          'textChunk': 'llo',
        }),
      );
      await pumpPastDeltaFlush();

      // One turn list in _flushDeltas plus one item list, the open turn's.
      expect(svc.debugCollectionCopies - before, equals(2));
      expect(svc.stateFor('p').turns.last.items.single.text, 'Hello');
      for (var i = 0; i < 20; i++) {
        expect(
          identical(svc.stateFor('p').turns[i], prior.turns[i]),
          isTrue,
        );
      }
    });

    test("hydrating a long transcript copies each turn's items once", () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      const base = 1000000;
      t.requestHandler = (method, params) => {
        'frames': [
          for (var n = 0; n < 30; n++) ...[
            frame('agent:turn-start', base, {'turnId': 'r$n'}),
            itemAdded('r$n', 'u$n', base, role: 'user', text: 'q$n'),
            itemAdded('r$n', 'a$n', base, text: 'a$n'),
            frame('agent:usage', base, {
              'turnId': 'r$n',
              'itemId': 'a$n',
              'total': <String, Object?>{},
              'last': {'totalTokens': n},
            }),
            itemAdded(
              'r$n',
              't$n',
              base,
              kind: 'tool_call',
              status: 'running',
            ),
            frame('agent:item-updated', base + 60000, {
              'turnId': 'r$n',
              'itemId': 't$n',
              'item': {
                'itemId': 't$n',
                'kind': 'tool_call',
                'status': 'completed',
              },
            }),
            frame('agent:turn-end', base, {
              'turnId': 'r$n',
              'stopReason': 'end_turn',
            }),
          ],
        ],
      };
      final before = svc.debugCollectionCopies;

      await svc.hydrateIfNeeded('p');

      // 1 turn list on the first append after the reset to const [], plus 30
      // item lists (one per turn, on its first item), plus 1 usageByItem map.
      expect(svc.debugCollectionCopies - before, equals(32));
      final s = svc.stateFor('p');
      expect(s.turns.map((t) => t.turnId), [for (var n = 0; n < 30; n++) 'r$n']);
      expect(s.turns.every((t) => t.items.length == 3), isTrue);
      for (final turn in s.turns) {
        final tool = turn.items.last;
        expect(tool.status, 'completed');
        expect(tool.timestamp, DateTime.fromMillisecondsSinceEpoch(base));
      }
      expect(s.usageByItem, hasLength(30));
      for (var n = 0; n < 30; n++) {
        expect(s.usageByItem['a$n']?.totalTokens, n);
      }
      expect(s.loading, isFalse);
    });

    test('a replayed batch builds the same transcript as the same frames '
        'streamed live', () async {
      var k = 0;
      Map<String, dynamic> f(String type, Map<String, dynamic> extra) =>
          frame(type, 1000000 + 1000 * k++, extra);
      final frames = [
        f('agent:turn-start', {'turnId': 't1'}),
        itemAdded('t1', 'u1', 0, role: 'user', text: 'q1'),
        itemAdded('t1', 'c1', 0, kind: 'tool_call', status: 'running'),
        f('agent:item-updated', {
          'turnId': 't1',
          'itemId': 'c1',
          'item': {'itemId': 'c1', 'kind': 'tool_call', 'status': 'completed'},
        }),
        itemAdded('t1', 'm1', 0, text: 'a1'),
        f('agent:usage', {
          'turnId': 't1',
          'itemId': 'm1',
          'total': <String, Object?>{},
          'last': {'totalTokens': 10},
        }),
        f('agent:snapshot', {
          'turnId': 't1',
          'items': [
            {'itemId': 'u1', 'kind': 'message', 'role': 'user', 'text': 'q1'},
            {
              'itemId': 'm1',
              'kind': 'message',
              'role': 'assistant',
              'text': 'a1 final',
            },
          ],
        }),
        f('agent:turn-end', {'turnId': 't1', 'stopReason': 'end_turn'}),
        f('agent:turn-start', {'turnId': 't2'}),
        itemAdded('t2', 'u2', 0, role: 'user', text: 'q2'),
        f('agent:usage', {
          'turnId': 't2',
          'total': {'totalTokens': 50},
          'last': {'totalTokens': 20},
          'contextWindow': 1000,
        }),
        f('agent:permission-request', {
          'permissionId': 'perm1',
          'title': 'Run?',
          'options': [
            {'optionId': 'ok', 'label': 'Allow', 'kind': 'allow_once'},
          ],
        }),
        itemAdded('t2', 'm2', 0, text: 'He'),
        f('agent:item-delta', {
          'turnId': 't2',
          'itemId': 'm2',
          'textChunk': 'llo',
        }),
      ];
      // itemAdded stamps its own ts; restamp so every frame has a distinct one.
      for (var i = 0; i < frames.length; i++) {
        frames[i]['timestamp'] = 1000000 + 1000 * i;
      }

      final ta = FakeAgentTransport();
      final a = AgentSessionService.fromSession(await newSession(ta));
      for (final fr in frames) {
        ta.emit(fr['type'] as String, fr);
      }
      await pumpPastDeltaFlush();

      final tb = FakeAgentTransport();
      final b = AgentSessionService.fromSession(await newSession(tb));
      tb.emit('agent:transcript-replay', {'sessionId': 'p', 'frames': frames});
      await pumpPastDeltaFlush();

      String describe(AgentSessionState s) {
        int? ms(DateTime? d) => d?.millisecondsSinceEpoch;
        return [
          for (final turn in s.turns)
            '${turn.turnId}|${turn.stopReason}|${ms(turn.startedAt)}|'
                '${ms(turn.endedAt)}|${[
                  for (final i in turn.items)
                    '${i.itemId}/${i.kind}/${i.role}/${i.text}/${i.status}/'
                        '${ms(i.timestamp)}',
                ]}',
          'item usage ${[
            for (final e in s.usageByItem.entries) '${e.key}=${e.value.totalTokens}',
          ]}',
          'turn usage ${[
            for (final e in s.usageByTurn.entries) '${e.key}=${e.value.totalTokens}',
          ]}',
          'meter ${s.usage?.total.totalTokens}/${s.usage?.last?.totalTokens}/'
              '${s.usage?.contextWindow}',
          'perms ${s.pendingPermissions.map((p) => p.permissionId).toList()}',
          'loading ${s.loading}',
        ].join('\n');
      }

      expect(describe(b.stateFor('p')), describe(a.stateFor('p')));
      expect(b.stateFor('p').turns, hasLength(2));
    });

    test('hydration never rewrites a usage map it already published', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.emitJson(
        frame('agent:usage', 1, {
          'itemId': 'x',
          'total': <String, Object?>{},
          'last': {'totalTokens': 1},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      final heldUsage = svc.stateFor('p').usageByItem;
      expect(heldUsage.keys, ['x']);
      t.requestHandler = (method, params) => {
        'frames': [
          frame('agent:turn-start', 1, {'turnId': 'r0'}),
          frame('agent:usage', 1, {
            'turnId': 'r0',
            'itemId': 'y',
            'total': <String, Object?>{},
            'last': {'totalTokens': 2},
          }),
          frame('agent:turn-end', 1, {
            'turnId': 'r0',
            'stopReason': 'end_turn',
          }),
        ],
      };

      await svc.hydrateIfNeeded('p');

      expect(heldUsage.keys, ['x']);
      expect(svc.stateFor('p').usageByItem.keys, unorderedEquals(['x', 'y']));
    });

    test('a live frame after hydration never rewrites the list hydration '
        'published', () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.requestHandler = (method, params) => {
        'frames': [
          frame('agent:turn-start', 1, {'turnId': 'live'}),
          itemAdded('live', 'i1', 1, text: 'one'),
          frame('agent:usage', 1, {
            'turnId': 'live',
            'itemId': 'i1',
            'total': <String, Object?>{},
            'last': {'totalTokens': 1},
          }),
        ],
        'activeTurnId': 'live',
      };
      await svc.hydrateIfNeeded('p');
      final published = svc.stateFor('p');
      final heldTurns = published.turns;
      final heldItems = published.turns.single.items;
      final heldUsage = published.usageByItem;

      t.emitJson(itemAdded('live', 'i2', 2, text: 'two'));
      t.emitJson(
        frame('agent:usage', 2, {
          'turnId': 'live',
          'itemId': 'i2',
          'total': <String, Object?>{},
          'last': {'totalTokens': 2},
        }),
      );
      t.emitJson(frame('agent:turn-start', 2, {'turnId': 'next'}));
      await Future<void>.delayed(Duration.zero);

      expect(heldTurns, hasLength(1));
      expect(heldItems, hasLength(1));
      expect(heldUsage, hasLength(1));
      final s = svc.stateFor('p');
      expect(s.turns, hasLength(2));
      expect(s.turns.first.items, hasLength(2));
      expect(s.usageByItem, hasLength(2));
    });

    test('a buffered delta follows its item into the turn that now holds it',
        () async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));

      t.emit('agent:transcript-replay', {
        'sessionId': 'p',
        'frames': [
          frame('agent:turn-start', 1, {'turnId': 'a'}),
          itemAdded('a', 'X', 1, text: 'He'),
          frame('agent:item-delta', 1, {
            'turnId': 'a',
            'itemId': 'X',
            'textChunk': 'llo',
          }),
          frame('agent:snapshot', 1, {
            'turnId': 'a',
            'items': [
              {
                'itemId': 'Y',
                'kind': 'message',
                'role': 'assistant',
                'text': 'y',
              },
            ],
          }),
          itemAdded('b', 'X', 1, text: 'He'),
        ],
      });
      await pumpPastDeltaFlush();

      final turns = svc.stateFor('p').turns;
      expect(turns.firstWhere((t) => t.turnId == 'b').items.single.text,
          'Hello');
      expect(
        turns.firstWhere((t) => t.turnId == 'a').items.map((i) => i.itemId),
        ['Y'],
      );
    });
  });

  group('live delta coalescing', () {
    Future<(FakeAgentTransport, AgentSessionService)> openStreaming(
      String kind,
    ) async {
      final t = FakeAgentTransport();
      final svc = AgentSessionService.fromSession(await newSession(t));
      t.emit('agent:turn-start', {'sessionId': 'p', 'turnId': 't1'});
      t.emit('agent:item-added', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'item': {
          'itemId': 'i1',
          'kind': 'message',
          'role': 'assistant',
          'text': 'He',
        },
      });
      await Future<void>.delayed(Duration.zero);
      return (t, svc);
    }

    void delta(FakeAgentTransport t, String chunk) {
      t.emit('agent:item-delta', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'textChunk': chunk,
      });
    }

    String textOf(AgentSessionService svc) =>
        svc.stateFor('p').turns.single.items.single.text ?? '';

    test('deltas inside one interval publish a single state', () async {
      final (t, svc) = await openStreaming('message');
      addTearDown(svc.dispose);
      final seen = <AgentSessionState>[];
      svc.stateStreamFor('p').listen(seen.add);

      // Microtask hops only: a zero-length timer queued behind a stalled VM
      // could fall due after the flush timer and split the interval.
      for (final c in ['l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd']) {
        delta(t, c);
        await Future<void>.value();
      }
      expect(seen, isEmpty);
      expect(textOf(svc), 'He');

      await pumpPastDeltaFlush();

      expect(seen, hasLength(1));
      expect(textOf(svc), 'Hello world');
      expect(seen.single.turns.single.items.single.text, 'Hello world');
    });

    test('non-agent frames between deltas do not flush them early', () async {
      final (t, svc) = await openStreaming('message');
      addTearDown(svc.dispose);
      final seen = <AgentSessionState>[];
      svc.stateStreamFor('p').listen(seen.add);

      delta(t, 'l');
      await Future<void>.value();
      t.emit('terminal:frame', {'terminalId': 'x'});
      await Future<void>.value();
      delta(t, 'o');
      await Future<void>.value();
      t.emit('tree:update', {'changes': <Object?>[]});
      await Future<void>.value();
      delta(t, '!');
      await Future<void>.value();

      expect(seen, isEmpty);
      expect(textOf(svc), 'He');

      await pumpPastDeltaFlush();

      expect(seen, hasLength(1));
      expect(textOf(svc), 'Helo!');
    });

    test('a steady stream still publishes once per interval', () async {
      final (t, svc) = await openStreaming('message');
      addTearDown(svc.dispose);
      final seen = <AgentSessionState>[];
      svc.stateStreamFor('p').listen(seen.add);

      final stop = DateTime.now().add(const Duration(milliseconds: 200));
      while (DateTime.now().isBefore(stop)) {
        delta(t, 'x');
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await pumpPastDeltaFlush();

      expect(seen, isNotEmpty);
      expect(seen.length, lessThan(25));
      expect(textOf(svc), startsWith('Hexxx'));
    });

    test('an item completion right after deltas lands in order', () async {
      final (t, svc) = await openStreaming('message');
      addTearDown(svc.dispose);
      final seen = <String>[];
      svc.stateStreamFor('p').listen(
        (s) => seen.add(s.turns.single.items.single.text ?? ''),
      );

      delta(t, 'llo');
      delta(t, ' there');
      t.emit('agent:item-updated', {
        'sessionId': 'p',
        'turnId': 't1',
        'itemId': 'i1',
        'item': {
          'itemId': 'i1',
          'kind': 'message',
          'role': 'assistant',
          'text': 'Hello there!',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(textOf(svc), 'Hello there!');
      await pumpPastDeltaFlush();

      expect(textOf(svc), 'Hello there!');
      expect(seen.last, 'Hello there!');
      expect(seen.where((x) => x == 'Hello there').length, lessThanOrEqualTo(1));
    });

    test('a turn end right after deltas sees the complete text', () async {
      final (t, svc) = await openStreaming('message');
      addTearDown(svc.dispose);

      delta(t, 'llo');
      t.emit('agent:turn-end', {
        'sessionId': 'p',
        'turnId': 't1',
        'stopReason': 'end_turn',
      });
      await Future<void>.delayed(Duration.zero);

      final turn = svc.stateFor('p').turns.single;
      expect(turn.stopReason, 'end_turn');
      expect(turn.items.single.text, 'Hello');
      await pumpPastDeltaFlush();
      expect(svc.stateFor('p').turns.single.items.single.text, 'Hello');
      expect(svc.stateFor('p').turns.single.stopReason, 'end_turn');
    });

    test('a session reset drops pending deltas for good', () async {
      final (t, svc) = await openStreaming('message');
      addTearDown(svc.dispose);

      delta(t, 'llo');
      t.emit('agent:session-reset', {'sessionId': 'p'});
      await Future<void>.delayed(Duration.zero);
      await pumpPastDeltaFlush();

      expect(svc.stateFor('p').turns, isEmpty);
    });

    test('dispose with a pending flush publishes nothing and throws nothing',
        () async {
      final (t, svc) = await openStreaming('message');
      final seen = <AgentSessionState>[];
      svc.stateStreamFor('p').listen(seen.add);

      delta(t, 'llo');
      await Future<void>.delayed(Duration.zero);
      await svc.dispose();
      await pumpPastDeltaFlush();

      expect(seen, isEmpty);
    });
  });
}
