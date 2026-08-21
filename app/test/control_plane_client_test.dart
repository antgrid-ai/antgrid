import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/services/session_delete_policy.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';

void main() {
  test('agent:projects populates the projects list', () async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);

    t.emit('agent:projects', {
      'projects': [
        {
          'projectId': 'projA',
          'label': 'Project A',
          'path': '/home/u/a',
          'running': true,
        },
        {'projectId': 'projB', 'label': 'Project B', 'running': false},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    final projects = client.currentState.projects;
    expect(projects, hasLength(2));
    expect(projects[0].projectId, 'projA');
    expect(projects[0].label, 'Project A');
    expect(projects[0].path, '/home/u/a');
    expect(projects[0].running, isTrue);
    expect(projects[1].projectId, 'projB');
    expect(projects[1].label, 'Project B');
    expect(projects[1].running, isFalse);
    expect(projects[1].path, isNull);

    await client.dispose();
  });

  test(
    'agent:projects parses the work status, null when absent/unknown',
    () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.emit('agent:projects', {
        'projects': [
          {'projectId': 'a', 'running': true, 'status': 'working'},
          {'projectId': 'b', 'running': true, 'status': 'attention'},
          {'projectId': 'c', 'running': false, 'status': 'error'},
          {'projectId': 'd', 'running': false, 'status': 'done'},
          {'projectId': 'e', 'running': false, 'status': 'bogus'},
          {'projectId': 'f', 'running': false},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final byId = {
        for (final p in client.currentState.projects) p.projectId: p.status,
      };
      expect(byId['a'], AgentWorkStatus.working);
      expect(byId['b'], AgentWorkStatus.attention);
      expect(byId['c'], AgentWorkStatus.error);
      expect(byId['d'], AgentWorkStatus.done);
      // Unknown value (newer bridge) and a missing field both degrade to null —
      // the app falls back to `running`.
      expect(byId['e'], isNull);
      expect(byId['f'], isNull);
    },
  );

  test(
    'agent:projects parses runningSessions, null when absent (older bridge)',
    () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.emit('agent:projects', {
        'projects': [
          {'projectId': 'a', 'running': true, 'runningSessions': 2},
          {'projectId': 'b', 'running': true, 'runningSessions': 0},
          {'projectId': 'c', 'running': false},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final byId = {
        for (final p in client.currentState.projects)
          p.projectId: p.runningSessions,
      };
      expect(byId['a'], 2);
      expect(byId['b'], 0);
      expect(byId['c'], isNull);
    },
  );

  group('machine-level remoteAccessEnabled', () {
    test('false parses (switch off — empty projects with a reason)', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.emit('agent:projects', {
        'projects': <Object>[],
        'remoteAccessEnabled': false,
      });
      await Future<void>.delayed(Duration.zero);

      expect(client.currentState.projects, isEmpty);
      expect(client.currentState.remoteAccessEnabled, isFalse);
    });

    test('true parses (online, genuinely no projects)', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.emit('agent:projects', {
        'projects': <Object>[],
        'remoteAccessEnabled': true,
      });
      await Future<void>.delayed(Duration.zero);

      expect(client.currentState.remoteAccessEnabled, isTrue);
    });

    test(
      'absent key → null, and a keyless advert resets a stale flag',
      () async {
        final t = FakeAgentTransport();
        final client = ControlPlaneClient(transport: t);
        addTearDown(client.dispose);

        // Older bridge: no key at all → unknown, never assumed off.
        t.emit('agent:projects', {'projects': <Object>[]});
        await Future<void>.delayed(Duration.zero);
        expect(client.currentState.remoteAccessEnabled, isNull);

        // A new-bridge advert sets the flag…
        t.emit('agent:projects', {
          'projects': <Object>[],
          'remoteAccessEnabled': false,
        });
        await Future<void>.delayed(Duration.zero);
        expect(client.currentState.remoteAccessEnabled, isFalse);

        // …and a subsequent keyless advert (bridge downgrade / mixed replay)
        // clears it back to unknown rather than leaving the stale flag.
        t.emit('agent:projects', {'projects': <Object>[]});
        await Future<void>.delayed(Duration.zero);
        expect(client.currentState.remoteAccessEnabled, isNull);
      },
    );

    test('clearAdvert() resets the flag to unknown', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.emit('agent:projects', {
        'projects': <Object>[],
        'remoteAccessEnabled': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.currentState.remoteAccessEnabled, isTrue);

      // A dropped peer says nothing about its switch — back to neutral copy.
      client.clearAdvert();
      expect(client.currentState.remoteAccessEnabled, isNull);
    });
  });

  test('startProject sends a project:start with the projectId', () async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);

    await client.startProject('projA');

    final sent = t.sent.firstWhere((m) => m['type'] == 'project:start');
    expect(sent['projectId'], 'projA');

    await client.dispose();
  });

  test('startProject fails fast (no silent drop) when the session is not '
      'established', () async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);

    // Keyless window: the stream reads connected but a send would silently drop
    // (sendOnStream no-ops without keys). Tier-2 fail-fast so awaitProjectRunning
    // never burns the full 30s on an undeliverable start.
    t.setEstablished(false);

    await expectLater(
      client.startProject('projA'),
      throwsA(isA<RpcException>()),
    );
    // Nothing was pushed onto the wire — the caller gets to retry, not strand.
    expect(t.sent.any((m) => m['type'] == 'project:start'), isFalse);

    await client.dispose();
  });

  test('NOT_ALLOWED error response surfaces error state, no throw', () async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);

    // Agent error shape: { ok:false, error:{ code, message } }.
    t.emitJson({
      'type': 'project:start',
      'ok': false,
      'error': {
        'code': 'NOT_ALLOWED',
        'message': 'mobile access is disabled on this machine',
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(client.currentState.lastError, isNotNull);
    expect(client.currentState.lastError!.code, 'NOT_ALLOWED');
    expect(
      client.currentState.lastError!.message,
      'mobile access is disabled on this machine',
    );

    await client.dispose();
  });

  test('parses agent:tools into the tools set', () async {
    final transport = FakeAgentTransport();
    final client = ControlPlaneClient(transport: transport);
    addTearDown(client.dispose);

    // FakeAgentTransport.emit(type, [extra]) stamps `type` + id/timestamp and
    // emits on the 'control' channel — do NOT pass 'control' as the first arg.
    transport.emit('agent:tools', {
      'tools': [
        {'tool': 'claude-code', 'path': '/usr/bin/claude'},
        {'tool': 'codex', 'path': '/usr/bin/codex'},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(client.currentState.tools.map((t) => t.tool).toSet(), {
      'claude-code',
      'codex',
    });
  });

  test(
    'parses agent:tools chatCapable when present, null when absent',
    () async {
      final transport = FakeAgentTransport();
      final client = ControlPlaneClient(transport: transport);
      addTearDown(client.dispose);

      transport.emit('agent:tools', {
        'tools': [
          {
            'tool': 'claude-code',
            'path': '/usr/bin/claude',
            'chatCapable': true,
          },
          {
            'tool': 'github-copilot',
            'path': '/usr/bin/copilot',
            'chatCapable': false,
          },
          {'tool': 'cursor-agent', 'path': '/usr/bin/cursor-agent'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final byTool = {for (final t in client.currentState.tools) t.tool: t};
      expect(byTool['claude-code']!.chatCapable, isTrue);
      expect(byTool['github-copilot']!.chatCapable, isFalse);
      expect(byTool['cursor-agent']!.chatCapable, isNull);
    },
  );

  test(
    'refresh() re-pulls state.snapshot and applies the response frames',
    () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      // Simulate the bridge recompute: the snapshot RESPONSE carries the fresh
      // advert (a project that wasn't there at connect). The bus dedups an
      // unchanged live push, so refresh must read these response frames directly.
      t.requestHandler = (method, params) => {
        'frames': [
          {
            'type': 'agent:projects',
            'projects': [
              {'projectId': 'late', 'label': 'Late Project', 'running': false},
            ],
          },
        ],
      };

      await client.refresh();

      expect(t.requests, hasLength(1));
      expect(t.requests.single.method, 'state.snapshot');
      expect(client.currentState.projects, hasLength(1));
      expect(client.currentState.projects.single.projectId, 'late');
    },
  );

  test('refresh() swallows an RpcException and keeps current state', () async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);
    addTearDown(client.dispose);

    t.emit('agent:projects', {
      'projects': [
        {'projectId': 'p1', 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    // Offline/pre-RPC agent: request throws. refresh must not rethrow, and the
    // previously-advertised projects must remain.
    t.requestHandler = (_, _) => throw RpcException('E_TIMEOUT', 'timed out');
    await client.refresh();

    expect(client.currentState.projects, hasLength(1));
    expect(client.currentState.projects.single.projectId, 'p1');
  });

  test('peerPresence=false clears the cached advert (reactive offline)', () async {
    final t = FakeAgentTransport();
    final presence = StreamController<bool>.broadcast();
    addTearDown(presence.close);
    final client = ControlPlaneClient(
      transport: t,
      peerPresence: presence.stream,
    );
    addTearDown(client.dispose);

    t.emit('agent:projects', {
      'projects': [
        {'projectId': 'p1', 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.currentState.projects, hasLength(1));

    // The control-plane peer drops (desktop closed). The relay transport emits
    // no disconnect, so the presence signal is what flips the client to offline.
    presence.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(
      client.currentState.projects,
      isEmpty,
      reason: 'a peer disconnect must clear the stale advert reactively',
    );

    // A re-advert after the peer returns repopulates without a manual refresh.
    presence.add(true);
    t.emit('agent:projects', {
      'projects': [
        {'projectId': 'p2', 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.currentState.projects.single.projectId, 'p2');
  });

  test('state stream emits on agent:projects', () async {
    final t = FakeAgentTransport();
    final client = ControlPlaneClient(transport: t);

    final future = client.stateStream.first;
    t.emit('agent:projects', {
      'projects': [
        {'projectId': 'p1', 'running': true},
      ],
    });

    final state = await future;
    expect(state.projects, hasLength(1));
    expect(state.projects.first.projectId, 'p1');

    await client.dispose();
  });

  group('listSessions', () {
    test('returns parsed sessions from the sessions.list response', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.requestHandler = (method, params) => {
        'sessions': [
          {
            'id': 's1',
            'name': 'Session 1',
            'createdAt': 1,
            'lastUsedAt': 2,
            'archived': false,
            'running': false,
          },
        ],
      };

      final sessions = await client.listSessions('p1');

      expect(t.requests.single.method, 'sessions.list');
      expect(t.requests.single.params, {
        'projectId': 'p1',
        'includeArchived': false,
      });
      expect(sessions, hasLength(1));
      expect(sessions.single.id, 's1');
    });

    test('propagates a NOT_ALLOWED RpcException', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.requestHandler = (_, _) => throw RpcException('NOT_ALLOWED', 'no');

      await expectLater(
        () => client.listSessions('p1'),
        throwsA(
          isA<RpcException>().having((e) => e.code, 'code', 'NOT_ALLOWED'),
        ),
      );
    });
  });

  group('deleteSession', () {
    test(
      'deleteSession sends sessions.delete and returns result.deleted',
      () async {
        final t = FakeAgentTransport();
        final client = ControlPlaneClient(transport: t);
        addTearDown(client.dispose);

        t.requestHandler = (method, params) => {'deleted': true};

        final ok = await client.deleteSession('projA', 's1');

        expect(ok, isTrue);
        expect(t.requests.single.method, 'sessions.delete');
        expect(t.requests.single.params, {
          'projectId': 'projA',
          'sessionId': 's1',
        });
      },
    );

    // Removing an isolated checkout is unbounded work on the bridge, so this
    // one verb must not inherit the transport's fast-read default; its siblings
    // are ordinary reads and must keep it.
    test(
      'deleteSession overrides the transport timeout, siblings do not',
      () async {
        final t = FakeAgentTransport();
        final client = ControlPlaneClient(transport: t);
        addTearDown(client.dispose);

        t.requestHandler = (method, params) =>
            method == 'sessions.delete' ? {'deleted': true} : {'sessions': []};

        await client.deleteSession('projA', 's1');
        await client.listSessions('projA');

        final byMethod = {for (final r in t.requests) r.method: r.timeout};
        expect(byMethod['sessions.delete'], kSessionDeleteAckTimeout);
        expect(byMethod['sessions.list'], isNot(kSessionDeleteAckTimeout));
      },
    );

    test('propagates a NOT_ALLOWED RpcException on delete', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.requestHandler = (_, _) => throw RpcException('NOT_ALLOWED', 'no');

      await expectLater(
        () => client.deleteSession('projA', 's1'),
        throwsA(
          isA<RpcException>().having((e) => e.code, 'code', 'NOT_ALLOWED'),
        ),
      );
    });
  });

  group('gitBranches & gitCheckout', () {
    test('gitBranches sends git.branches RPC and returns catalog', () async {
      final t = FakeAgentTransport();
      final client = ControlPlaneClient(transport: t);
      addTearDown(client.dispose);

      t.requestHandler = (method, params) => {
        'isRepository': true,
        'current': 'main',
        'branches': ['main', 'dev'],
      };

      final catalog = await client.gitBranches(projectId: 'p1');
      expect(catalog.isRepository, isTrue);
      expect(catalog.current, 'main');
      expect(catalog.branches, ['main', 'dev']);
      expect(t.requests.single.method, 'git.branches');
      expect(t.requests.single.params, {'projectId': 'p1'});
    });

    test(
      'gitCheckout sends git.checkout RPC with allowActiveSessions',
      () async {
        final t = FakeAgentTransport();
        final client = ControlPlaneClient(transport: t);
        addTearDown(client.dispose);

        t.requestHandler = (method, params) => {'current': 'dev'};

        final current = await client.gitCheckout(
          projectId: 'p1',
          branch: 'dev',
          allowActiveSessions: true,
        );
        expect(current, 'dev');
        expect(t.requests.single.method, 'git.checkout');
        expect(t.requests.single.params, {
          'projectId': 'p1',
          'branch': 'dev',
          'allowActiveSessions': true,
        });
      },
    );
  });
}
