import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/session_bus/remote_directory_pump.dart';
import 'package:antgrid/session_bus/remote_directory_source.dart';

// The widget itself (`RemoteDirectoryPumpHost`) owns only a `Timer` and two
// `ref.listenManual` registrations — see its own doc comment. Everything it
// delegates to is `RemoteDirectoryPumpEngine`, which is what these tests
// drive directly, with a recording `pushFn` standing in for the loopback
// POST.
class _Push {
  _Push(this.machines, this.notConnected);
  final List<Map<String, dynamic>> machines;
  final int notConnected;
}

class _RecordingPusher {
  final calls = <_Push>[];
  RemoteDirectoryAck Function(List<Map<String, dynamic>>, int)? answer;
  Object? Function()? fail;

  Future<RemoteDirectoryAck> call(
    List<Map<String, dynamic>> machines,
    int notConnected,
  ) async {
    calls.add(_Push(machines, notConnected));
    final failure = fail?.call();
    if (failure != null) throw failure;
    return (answer ?? _defaultAck)(machines, notConnected);
  }

  static RemoteDirectoryAck _defaultAck(
    List<Map<String, dynamic>> machines,
    int notConnected,
  ) => const RemoteDirectoryAck(
    accepted: 0,
    dropped: 0,
    wantedRepoKeys: [],
    unservedReads: 0,
  );
}

void main() {
  group('bootstrap', () {
    test('the first push is empty and adopts the repo keys the ack names', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher()
        ..answer = (_, _) => const RemoteDirectoryAck(
          accepted: 0,
          dropped: 0,
          wantedRepoKeys: ['github.com/a/b'],
          unservedReads: 0,
        );
      var asked = false;
      final t0 = DateTime(2024, 1, 1);

      final result = await engine.maybeRunCycle(
        now: t0,
        triggered: false,
        controlPort: 1234,
        candidates: const {'m1'},
        localUuid: 'local',
        peekClient: (uuid) {
          asked = true;
          return const RemoteClientResolved(null);
        },
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );

      expect(result, isNotNull);
      expect(pusher.calls, hasLength(1));
      expect(pusher.calls.single.machines, isEmpty);
      expect(asked, isFalse); // bootstrap never collects — no candidate asked
      expect(engine.wantedRepoKeys, ['github.com/a/b']);

      // The bootstrap push does not consume the heartbeat slot, so the very
      // next poll tick (well inside kRemoteDirectoryHeartbeat) still finds a
      // real cycle due, and THIS time the candidate is actually asked.
      var askedSecond = false;
      final second = await engine.maybeRunCycle(
        now: t0.add(kRemoteDirectoryMinSpacing),
        triggered: false,
        controlPort: 1234,
        candidates: const {'m1'},
        localUuid: 'local',
        peekClient: (uuid) {
          askedSecond = true;
          return const RemoteClientResolved(null);
        },
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(second, isNotNull);
      expect(askedSecond, isTrue);
      expect(pusher.calls, hasLength(2));
    });
  });

  group('cadence feedback', () {
    test('an unserved read shortens the tick, and a refused machine backs '
        'off longer than an unreachable one', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher()
        ..answer = (_, _) => const RemoteDirectoryAck(
          accepted: 0,
          dropped: 0,
          wantedRepoKeys: [],
          unservedReads: 3,
        );
      final t0 = DateTime(2024, 1, 1);

      // Bootstrap push.
      await engine.maybeRunCycle(
        now: t0,
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );

      // Real cycle, which reports 3 unserved reads and arms the fast tick.
      final t1 = t0.add(kRemoteDirectoryMinSpacing);
      await engine.maybeRunCycle(
        now: t1,
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(pusher.calls, hasLength(2));

      // Without the fast tick, kRemoteDirectoryFastTick (5s) after t1 would
      // be inside the 30s heartbeat and no push would fire; with it armed,
      // this cycle is due.
      final t2 = t1.add(kRemoteDirectoryFastTick);
      final fastResult = await engine.maybeRunCycle(
        now: t2,
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(fastResult, isNotNull);
      expect(pusher.calls, hasLength(3));
    });
  });

  group('BAD_REQUEST latch', () {
    test('a single BAD_REQUEST does not latch the pump off — it takes '
        '$kRemoteDirectoryLatchThreshold consecutive ones', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher()
        ..fail = () => HostControlException('BAD_REQUEST', 'unknown verb');
      final t0 = DateTime(2024, 1, 1);

      for (var i = 0; i < kRemoteDirectoryLatchThreshold - 1; i++) {
        final result = await engine.maybeRunCycle(
          now: t0.add(kRemoteDirectoryMinSpacing * i),
          triggered: false,
          controlPort: 1,
          candidates: const {},
          localUuid: 'local',
          peekClient: (_) => const RemoteClientResolved(null),
          inventory: const <InventoryAgent>[],
          pushFn: pusher.call,
        );
        expect(result, isNull);
        expect(engine.isLatched, isFalse);
      }
      expect(pusher.calls, hasLength(kRemoteDirectoryLatchThreshold - 1));

      // One more consecutive BAD_REQUEST crosses the threshold.
      final latching = await engine.maybeRunCycle(
        now: t0.add(kRemoteDirectoryMinSpacing * kRemoteDirectoryLatchThreshold),
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(latching, isNull);
      expect(engine.isLatched, isTrue);
      expect(pusher.calls, hasLength(kRemoteDirectoryLatchThreshold));
    });

    test('once latched, a due cycle on the same port makes no push at all, '
        'and a different control port clears the latch and the streak', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher()
        ..fail = () => HostControlException('BAD_REQUEST', 'unknown verb');
      final t0 = DateTime(2024, 1, 1);

      for (var i = 0; i < kRemoteDirectoryLatchThreshold; i++) {
        await engine.maybeRunCycle(
          now: t0.add(kRemoteDirectoryMinSpacing * i),
          triggered: false,
          controlPort: 1,
          candidates: const {},
          localUuid: 'local',
          peekClient: (_) => const RemoteClientResolved(null),
          inventory: const <InventoryAgent>[],
          pushFn: pusher.call,
        );
      }
      expect(engine.isLatched, isTrue);
      expect(pusher.calls, hasLength(kRemoteDirectoryLatchThreshold));

      // Latched: a due cycle on the SAME port makes no push at all.
      final stillLatched = await engine.maybeRunCycle(
        now: t0.add(kRemoteDirectoryHeartbeat),
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(stillLatched, isNull);
      expect(pusher.calls, hasLength(kRemoteDirectoryLatchThreshold));

      // A different control port (the bridge restarted, presumably upgraded)
      // clears the latch AND the streak, and tries again.
      pusher.fail = null;
      final afterRestart = await engine.maybeRunCycle(
        now: t0.add(kRemoteDirectoryHeartbeat * 2),
        triggered: false,
        controlPort: 2,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(afterRestart, isNotNull);
      expect(engine.isLatched, isFalse);
      expect(pusher.calls, hasLength(kRemoteDirectoryLatchThreshold + 1));
    });
  });

  group('BAD_RESPONSE (an unparseable ack)', () {
    test('a malformed ack still exits bootstrap, so the next cycle actually '
        'collects instead of repeating an empty replace forever', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher()
        ..fail = () => HostControlException('BAD_RESPONSE', 'malformed reply');
      final t0 = DateTime(2024, 1, 1);

      final first = await engine.maybeRunCycle(
        now: t0,
        triggered: false,
        controlPort: 1,
        candidates: const {'m1'},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(first, isNull);
      expect(pusher.calls, hasLength(1));
      expect(pusher.calls.single.machines, isEmpty); // bootstrap: still empty

      // A second cycle, well inside the heartbeat, must no longer be
      // bootstrap: the malformed ack still proved the POST was accepted, so
      // this must actually collect rather than send another empty replace.
      var asked = false;
      final second = await engine.maybeRunCycle(
        now: t0.add(kRemoteDirectoryMinSpacing),
        triggered: false,
        controlPort: 1,
        candidates: const {'m1'},
        localUuid: 'local',
        peekClient: (_) {
          asked = true;
          return const RemoteClientResolved(null);
        },
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(second, isNull); // still BAD_RESPONSE-failing on this bridge
      expect(asked, isTrue);
      expect(pusher.calls, hasLength(2));
    });
  });

  group('off-cadence trigger', () {
    test('a peer presence drop pushes without an RPC', () async {
      // "A peer presence drop" is a candidate set shrinking between cycles —
      // reachable off-cadence via `triggered: true`, which the widget passes
      // on `relayConnectionChangesProvider` firing. The push itself carries
      // no RPC to the departed machine: it is simply absent from
      // `candidates`, so `collectRemoteMachineReports` never asks it.
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher();
      final t0 = DateTime(2024, 1, 1);

      // Bootstrap.
      await engine.maybeRunCycle(
        now: t0,
        triggered: false,
        controlPort: 1,
        candidates: const {'m1', 'm2'},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );

      // A real cycle establishes both machines as known. Both peek null (no
      // live socket to either), which classifies as unreachable and arms
      // that tracker's own backoff — so by the next cycle neither is asked
      // again regardless of the trigger, which is exactly the point: the
      // trigger's own value is in not waiting a full heartbeat, not in
      // forcing a fresh RPC.
      final t1 = t0.add(kRemoteDirectoryMinSpacing);
      await engine.maybeRunCycle(
        now: t1,
        triggered: false,
        controlPort: 1,
        candidates: const {'m1', 'm2'},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(pusher.calls.last.machines.map((m) => m['machineId']).toSet(), {
        'm1',
        'm2',
      });

      // m2's socket closes — it drops out of candidates. The widget fires
      // this off-cadence (triggered: true) the moment
      // relayConnectionChangesProvider notices, not waiting for the
      // heartbeat; minSpacing has to have elapsed since the last push for
      // the trigger to be honoured.
      final t2 = t1.add(kRemoteDirectoryMinSpacing);
      final asked = <String>[];
      final dropResult = await engine.maybeRunCycle(
        now: t2,
        triggered: true,
        controlPort: 1,
        candidates: const {'m1'},
        localUuid: 'local',
        peekClient: (uuid) {
          asked.add(uuid);
          return const RemoteClientResolved(null);
        },
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(dropResult, isNotNull);
      // No RPC at all: m1 is still inside its backoff window from t1, and
      // m2 is no longer a candidate to ask.
      expect(asked, isEmpty);
      final lastPush = pusher.calls.last;
      final pushedIds = lastPush.machines.map((m) => m['machineId']).toSet();
      expect(pushedIds, contains('m1')); // reported from cache
      expect(pushedIds, isNot(contains('m2'))); // dropped, not merely stale
    });

    test('a trigger inside minSpacing of the last push is not due', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher();
      final t0 = DateTime(2024, 1, 1);
      // Bootstrap — deliberately does not set cadence's lastPush, so a real
      // cycle is needed first to give `triggerDue` something to measure
      // against.
      await engine.maybeRunCycle(
        now: t0,
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      final t1 = t0.add(kRemoteDirectoryMinSpacing);
      await engine.maybeRunCycle(
        now: t1,
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(pusher.calls, hasLength(2));

      final result = await engine.maybeRunCycle(
        now: t1.add(const Duration(milliseconds: 1)),
        triggered: true,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(result, isNull);
      expect(pusher.calls, hasLength(2));
    });
  });

  group('transport failure', () {
    test('a transport error between peek and push is swallowed and retried '
        'on the next due cycle', () async {
      final engine = RemoteDirectoryPumpEngine();
      final pusher = _RecordingPusher()..fail = () => Exception('ECONNRESET');
      final t0 = DateTime(2024, 1, 1);
      final result = await engine.maybeRunCycle(
        now: t0,
        triggered: false,
        controlPort: 1,
        candidates: const {},
        localUuid: 'local',
        peekClient: (_) => const RemoteClientResolved(null),
        inventory: const <InventoryAgent>[],
        pushFn: pusher.call,
      );
      expect(result, isNull);
      expect(engine.isLatched, isFalse); // only BAD_REQUEST latches
    });
  });

  group('peekControlPlaneClient', () {
    test('a control-plane client element that was never built is reported '
        'pending, and peeking it never builds — never dials — it', () {
      // This is the dial guard `_tick`'s peekClient wires into the engine.
      // A bare ProviderContainer with no overrides proves the point: if
      // peeking ever fell back to `ref.read` past the `exists` check, it
      // would run `controlPlaneClientForProvider`'s body here (transport →
      // device provisioning → token mint → dial) rather than merely check
      // for one, and this container has none of that wired up to survive it.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = RefreshRef.ofContainer(container);

      final peek = peekControlPlaneClient(ref, 'peer-uuid');

      expect(peek, isA<RemoteClientPending>());
      expect(
        container.exists(controlPlaneClientForProvider('peer-uuid')),
        isFalse,
      );
    });
  });
}
