import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/agent_session_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

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
    await Future<void>.delayed(Duration.zero);

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
      await Future<void>.delayed(Duration.zero);

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
    await Future<void>.delayed(Duration.zero);

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

  test(
    'stopHydrating deregisters the transcript hydrator so a reconnect no '
    'longer re-pulls that session',
    () async {
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
    },
  );

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
}
