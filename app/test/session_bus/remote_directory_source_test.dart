import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/session_bus/remote_directory_source.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';

ControlPlaneClient _clientAnswering(
  Map<String, dynamic> Function(String method, Map<String, dynamic>? params)
  handler,
) {
  final t = FakeAgentTransport();
  t.requestHandler = handler;
  return ControlPlaneClient(transport: t);
}

ControlPlaneClient _clientThrowing(RpcException e) => _clientAnswering((
  method,
  params,
) {
  throw e;
});

void main() {
  group('classifyMachine', () {
    test('a null sessions key classifies as no-card, not as a machine with '
        'no sessions', () async {
      final noKey = _clientAnswering(
        (_, _) => {
          'os': {'name': 'linux', 'version': '1', 'arch': 'x64'},
          'projects': <String, dynamic>{},
          // no `sessions` key at all — an older bridge.
        },
      );
      final outcome = await classifyMachine(noKey, const []);
      expect(outcome, isA<RemoteMachineNoCard>());

      final emptyKey = _clientAnswering(
        (_, _) => {
          'os': {'name': 'linux', 'version': '1', 'arch': 'x64'},
          'projects': <String, dynamic>{},
          'sessions': <dynamic>[],
          'sessionsTruncated': 0,
        },
      );
      final honoured = await classifyMachine(emptyKey, const []);
      expect(
        honoured,
        isA<RemoteMachineRows>().having((r) => r.rows, 'rows', isEmpty),
      );
      expect(honoured, isNot(isA<RemoteMachineNoCard>()));

      await noKey.dispose();
      await emptyKey.dispose();
    });

    test('NOT_ALLOWED classifies as refused and a timeout as unreachable', () async {
      final refused = _clientThrowing(
        RpcException('NOT_ALLOWED', 'mobile access is disabled'),
      );
      expect(
        await classifyMachine(refused, const []),
        isA<RemoteMachineRefused>(),
      );

      final timedOut = _clientThrowing(
        RpcException('E_TIMEOUT', 'request timed out'),
      );
      expect(
        await classifyMachine(timedOut, const []),
        isA<RemoteMachineUnreachable>(),
      );

      // A null client — no live socket to peek — is unreachable too, with no
      // RPC attempted at all.
      expect(
        await classifyMachine(null, const []),
        isA<RemoteMachineUnreachable>(),
      );

      await refused.dispose();
      await timedOut.dispose();
    });

    test('a bridge too old for this verb, or one that disagrees on its '
        'params, classifies as no-card rather than unreachable', () async {
      final tooOld = _clientThrowing(
        RpcException('E_UNKNOWN_METHOD', 'unknown method: machine.capability-card'),
      );
      expect(await classifyMachine(tooOld, const []), isA<RemoteMachineNoCard>());

      final badParams = _clientThrowing(
        RpcException('E_BAD_PARAMS', 'repoKeys must be strings'),
      );
      expect(await classifyMachine(badParams, const []), isA<RemoteMachineNoCard>());

      await tooOld.dispose();
      await badParams.dispose();
    });

    test('a card with rows classifies as rows, carrying the truncated count', () async {
      final client = _clientAnswering(
        (_, _) => {
          'os': {'name': 'linux', 'version': '1', 'arch': 'x64'},
          'projects': <String, dynamic>{},
          'sessions': [
            {
              'repoKey': 'github.com/a/b',
              'projectId': 'p1',
              'sessionId': 's1',
              'title': 'Fix the thing',
              'branch': 'main',
              'activity': 'running',
              'lastActiveAt': 1000,
              'canReply': true,
            },
          ],
          'sessionsTruncated': 2,
        },
      );
      final outcome = await classifyMachine(client, const []);
      expect(outcome, isA<RemoteMachineRows>());
      final rows = outcome as RemoteMachineRows;
      expect(rows.rows, hasLength(1));
      expect(rows.rows.single.sessionId, 's1');
      expect(rows.truncated, 2);
      await client.dispose();
    });
  });

  group('collectRemoteMachineReports', () {
    test('a resolved-null peek asks nothing over RPC but is classified '
        'unreachable and backed off', () async {
      // RemoteClientResolved(null) is what a genuinely offline target
      // produces — settled, no client, worth a real answer. It must not cost
      // an RPC (there is nothing to ask), but it IS an answer: unreachable,
      // with a backoff armed so it isn't re-asked every cycle.
      final peeked = <String>[];
      final tracker = RemoteMachineTracker();
      final reports = await collectRemoteMachineReports(
        candidates: {'m1', 'm2'},
        peekClient: (uuid) {
          peeked.add(uuid);
          return const RemoteClientResolved(null);
        },
        repoKeys: const [],
        inventory: const [],
        tracker: tracker,
        now: DateTime.now(),
      );
      expect(peeked.toSet(), {'m1', 'm2'});
      expect(reports, hasLength(2));
      for (final r in reports) {
        expect(r.outcome, isA<RemoteMachineUnreachable>());
      }
      expect(tracker.shouldAsk('m1', DateTime.now()), isFalse);
    });

    test('a pending peek is skipped entirely: no report, no backoff, and the '
        'machine is asked again next cycle', () async {
      final tracker = RemoteMachineTracker();
      final t0 = DateTime(2024, 1, 1);
      final reports = await collectRemoteMachineReports(
        candidates: {'m1'},
        peekClient: (_) => const RemoteClientPending(),
        repoKeys: const [],
        inventory: const [],
        tracker: tracker,
        now: t0,
      );
      expect(reports, isEmpty);
      expect(tracker.cached('m1'), isNull);
      // Not backed off — the very next cycle (once the provider resolves)
      // must still be free to ask it.
      expect(tracker.shouldAsk('m1', t0), isTrue);
    });

    test('a backed-off machine is reported from cache, not re-asked', () async {
      var asks = 0;
      RemoteClientPeek peek(String uuid) {
        asks++;
        return RemoteClientResolved(
          _clientThrowing(RpcException('NOT_ALLOWED', 'off')),
        );
      }

      final tracker = RemoteMachineTracker();
      final t0 = DateTime(2024, 1, 1);
      final first = await collectRemoteMachineReports(
        candidates: {'m1'},
        peekClient: peek,
        repoKeys: const [],
        inventory: const [],
        tracker: tracker,
        now: t0,
      );
      expect(first.single.outcome, isA<RemoteMachineRefused>());
      expect(asks, 1);

      // Still inside the refused backoff window — reused from cache, no
      // fresh ask, and the ORIGINAL observedAt travels unchanged so the far
      // mirror's own TTL (not this pump) is what ages the row out.
      final second = await collectRemoteMachineReports(
        candidates: {'m1'},
        peekClient: peek,
        repoKeys: const [],
        inventory: const [],
        tracker: tracker,
        now: t0.add(const Duration(seconds: 30)),
      );
      expect(asks, 1);
      expect(second.single.observedAt, first.single.observedAt);
    });
  });

  group('RemoteMachineTracker', () {
    test('a refused machine backs off longer than an unreachable one', () {
      final tracker = RemoteMachineTracker();
      final now = DateTime(2024, 1, 1);
      tracker.record(
        'refused',
        const RemoteMachineReport(
          machineId: 'refused',
          observedAt: 0,
          outcome: RemoteMachineRefused(),
        ),
        now,
      );
      tracker.record(
        'unreachable',
        const RemoteMachineReport(
          machineId: 'unreachable',
          observedAt: 0,
          outcome: RemoteMachineUnreachable(),
        ),
        now,
      );
      // Just past the unreachable backoff: unreachable is due again, refused
      // is not.
      final shortlyAfter = now.add(kRemoteDirectoryUnreachableBackoff + const Duration(seconds: 1));
      expect(tracker.shouldAsk('unreachable', shortlyAfter), isTrue);
      expect(tracker.shouldAsk('refused', shortlyAfter), isFalse);
    });

    test('rows clear any prior backoff', () {
      final tracker = RemoteMachineTracker();
      final now = DateTime(2024, 1, 1);
      tracker.record(
        'm1',
        const RemoteMachineReport(
          machineId: 'm1',
          observedAt: 0,
          outcome: RemoteMachineUnreachable(),
        ),
        now,
      );
      // Backed off immediately after an unreachable record.
      expect(tracker.shouldAsk('m1', now), isFalse);
      tracker.record(
        'm1',
        const RemoteMachineReport(
          machineId: 'm1',
          observedAt: 0,
          outcome: RemoteMachineRows(rows: [], truncated: 0),
        ),
        now,
      );
      expect(
        tracker.shouldAsk('m1', now.add(const Duration(milliseconds: 1))),
        isTrue,
      );
    });

    test('a no-card machine is not re-asked until its socket drops', () {
      final tracker = RemoteMachineTracker();
      final now = DateTime(2024, 1, 1);
      tracker.record(
        'legacy',
        const RemoteMachineReport(
          machineId: 'legacy',
          observedAt: 0,
          outcome: RemoteMachineNoCard(),
        ),
        now,
      );
      // Past even the refused window: no ask can change this answer, and the
      // one event that can — the peer restarting its bridge — drops it from
      // the candidate set, which prunes the backoff with it.
      expect(
        tracker.shouldAsk('legacy', now.add(kRemoteDirectoryRefusedBackoff * 2)),
        isFalse,
      );
      tracker.prune(const {});
      expect(tracker.shouldAsk('legacy', now), isTrue);
    });

    test('prune drops a machine no longer a candidate', () {
      final tracker = RemoteMachineTracker();
      final now = DateTime(2024, 1, 1);
      tracker.record(
        'gone',
        const RemoteMachineReport(
          machineId: 'gone',
          observedAt: 0,
          outcome: RemoteMachineRefused(),
        ),
        now,
      );
      expect(tracker.cached('gone'), isNotNull);
      tracker.prune(const {});
      expect(tracker.cached('gone'), isNull);
    });
  });

  group('remoteDirectoryCandidates / notConnected / label', () {
    test('candidates excludes the local machine', () {
      expect(
        remoteDirectoryCandidates(['m1', 'm2', 'local'], 'local'),
        {'m1', 'm2'},
      );
    });

    test('notConnected counts account machines neither local nor a candidate', () {
      final inventory = [
        _agent('local'),
        _agent('m1'),
        _agent('m2'),
        _agent('m3'),
      ];
      expect(
        remoteDirectoryNotConnectedCount(inventory, 'local', {'m1'}),
        2, // m2, m3
      );
    });

    test('label prefers machineName over displayName, and omits when neither is set', () {
      final inventory = [
        InventoryAgent(
          deviceUuid: 'm1',
          displayName: 'Bharath (laptop)',
          platform: 'windows',
          ed25519Pub: 'x',
          machineName: 'macbook-pro',
        ),
        InventoryAgent(
          deviceUuid: 'm2',
          displayName: 'Bharath (desktop)',
          platform: 'windows',
          ed25519Pub: 'x',
        ),
      ];
      expect(remoteDirectoryMachineLabel(inventory, 'm1'), 'macbook-pro');
      expect(remoteDirectoryMachineLabel(inventory, 'm2'), 'Bharath (desktop)');
      expect(remoteDirectoryMachineLabel(inventory, 'unknown'), isNull);
    });
  });

  group('RemoteMachineReport.toWire', () {
    test('rows serialize to the RemoteDirectoryRowSchema shape', () {
      const row = MachineSessionRow(
        repoKey: 'github.com/a/b',
        projectId: 'p1',
        sessionId: 's1',
        title: 'Fix the thing',
        branch: 'main',
        activity: MachineSessionActivity.running,
        lastActiveAt: 1000,
        canReply: true,
      );
      const report = RemoteMachineReport(
        machineId: 'm1',
        machineLabel: 'macbook-pro',
        observedAt: 5000,
        outcome: RemoteMachineRows(rows: [row], truncated: 1),
      );
      final wire = report.toWire();
      expect(wire['machineId'], 'm1');
      expect(wire['machineLabel'], 'macbook-pro');
      expect(wire['observedAt'], 5000);
      expect(wire['outcome'], 'rows');
      expect(wire['truncated'], 1);
      final wireRows = wire['rows'] as List;
      expect(wireRows, hasLength(1));
      final wireRow = wireRows.single as Map<String, dynamic>;
      expect(wireRow['repoKey'], 'github.com/a/b');
      expect(wireRow['sessionId'], 's1');
      expect(wireRow['branch'], 'main');
      expect(wireRow['activity'], 'running');
      expect(wireRow['canReply'], true);
      expect(wireRow.containsKey('projectLabel'), isFalse);
      expect(wireRow.containsKey('workStatus'), isFalse);
    });

    test('a non-rows outcome sends empty rows and zero truncated', () {
      const report = RemoteMachineReport(
        machineId: 'm1',
        observedAt: 5000,
        outcome: RemoteMachineRefused(),
      );
      final wire = report.toWire();
      expect(wire['outcome'], 'refused');
      expect(wire['rows'], isEmpty);
      expect(wire['truncated'], 0);
      expect(wire.containsKey('machineLabel'), isFalse);
    });

    // `ControlRequestSchema` (control-protocol.ts) requires `truncated >= 0`
    // and caps `rows` — a peer's own numbers are untrusted input, and
    // forwarding either one verbatim is exactly what 400s the whole push and
    // latches the pump off (see `kRemoteDirectoryLatchThreshold`).
    test('a negative truncated count from a peer never reaches the wire '
        'negative', () {
      const report = RemoteMachineReport(
        machineId: 'm1',
        observedAt: 5000,
        outcome: RemoteMachineRows(rows: [], truncated: -1),
      );
      expect(report.toWire()['truncated'], 0);
    });

    test('rows past the product cap are clamped, and the overflow is folded '
        'into truncated rather than silently dropped', () {
      final rows = List.generate(
        kRemoteDirectoryMaxRowsPerMachine + 5,
        (i) => MachineSessionRow(
          repoKey: 'github.com/a/b',
          projectId: 'p1',
          sessionId: 's$i',
          title: 'session $i',
          branch: 'main',
          lastActiveAt: 0,
          canReply: false,
        ),
      );
      final report = RemoteMachineReport(
        machineId: 'm1',
        observedAt: 5000,
        outcome: RemoteMachineRows(rows: rows, truncated: 2),
      );
      final wire = report.toWire();
      expect(wire['rows'], hasLength(kRemoteDirectoryMaxRowsPerMachine));
      // 2 the peer already reported truncated, plus 5 this machine itself
      // clamped off.
      expect(wire['truncated'], 7);
    });
  });

  group('clampReportsForWire', () {
    test('a push naming more machines than the product cap is trimmed, '
        'independent of the reports the engine still tracks', () {
      final reports = List.generate(
        kRemoteDirectoryMaxMachinesPerPush + 3,
        (i) => RemoteMachineReport(
          machineId: 'm$i',
          observedAt: 0,
          outcome: const RemoteMachineRefused(),
        ),
      );
      final wired = clampReportsForWire(reports);
      expect(wired, hasLength(kRemoteDirectoryMaxMachinesPerPush));
    });

    test('a push within the cap is returned unchanged', () {
      final reports = [
        const RemoteMachineReport(
          machineId: 'm1',
          observedAt: 0,
          outcome: RemoteMachineRefused(),
        ),
      ];
      expect(clampReportsForWire(reports), same(reports));
    });
  });

  group('RemoteDirectoryCadence', () {
    test('an unserved read shortens the tick', () {
      final cadence = RemoteDirectoryCadence();
      final t0 = DateTime(2024, 1, 1);
      cadence.notePush(t0);
      final sixSecondsLater = t0.add(const Duration(seconds: 6));
      // Without an unserved read, 6s is well inside the 30s heartbeat.
      expect(cadence.heartbeatDue(sixSecondsLater), isFalse);
      cadence.noteAck(1, t0);
      // With one, the fast tick (5s) applies — 6s later is now due.
      expect(cadence.heartbeatDue(sixSecondsLater), isTrue);
    });

    test('heartbeatDue is unconditionally true before the first push', () {
      final cadence = RemoteDirectoryCadence();
      expect(cadence.heartbeatDue(DateTime.now()), isTrue);
    });
  });
}

InventoryAgent _agent(String uuid) => InventoryAgent(
  deviceUuid: uuid,
  displayName: uuid,
  platform: 'windows',
  ed25519Pub: 'x',
);
