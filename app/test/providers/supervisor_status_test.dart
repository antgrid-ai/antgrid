// The workspace UI reads SupervisorStatus as its single source of truth
// instead of the raw RelayConnectionState. Covered here: the provider that
// carries the status to the UI (through a real container, in the ordering
// production actually uses), the reachability mapping, app-resume fanning
// `noteResume()` out to every live machine, and the control-plane reaper
// toggling `wanted` around a release instead of only releasing.
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/screens/app_shell.dart';
import '../helpers/fixed_peer_connector.dart';

/// A [PeerConnectionMechanisms] whose rung getters are settable directly, decoupled
/// from the underlying (never-connected) RelayService — the only way to
/// simulate a rung silently breaking with NO edge event to notice it, which is
/// exactly the case `noteResume()` exists for (see its doc comment on
/// `RelayConnection`).
class _ToggleableMechanisms extends PeerConnectionMechanisms {
  _ToggleableMechanisms({
    required super.crypto,
    required super.machineDeviceId,
    required super.phoneDeviceId,
    required super.phoneEd25519Seed,
    required super.resolveCoords,
    required super.peerRuntime,
  });

  bool payloadOk = false;
  int dialCalls = 0;

  @override
  bool get payloadConnected => payloadOk;

  @override
  bool get sessionEstablished => true;

  @override
  Future<void> connectPayload(ConnCoords coords) async {
    dialCalls++;
    payloadOk = true;
  }

  @override
  Future<void> release() async {}
}

_ToggleableMechanisms _toggleable(MachineConnection conn, String machineId) =>
    _ToggleableMechanisms(
      crypto: CryptoService(),
      machineDeviceId: machineId,
      phoneDeviceId: 'phone-1',
      phoneEd25519Seed: List<int>.filled(32, 7),
      resolveCoords: () async => const ConnCoords(
        relayUrl: 'ws://relay.test',
        agentEd25519PubB64: 'AGENT_PUB',
      ),
      peerRuntime: FixedPeerConnector.stub(),
    );

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Records release calls and reports a fixed, mutable set of "open"
/// control-plane ids without touching the connection it hands back — unlike
/// the real `RelayConnectionManager.release()`, which also disposes the
/// supervisor. That keeps `reconcileControlPlaneWantedness`'s OWN
/// `setWanted(false)` call the only thing that can be driving the supervisor
/// in this test, isolating the behavior under test from release's own
/// (independently correct) teardown.
class _NonDisposingManager extends MachineConnectionManager {
  _NonDisposingManager(this._byId) : super(crypto: CryptoService());

  final Map<String, MachineConnection> _byId;
  final List<String> released = [];

  @override
  List<String> openControlPlaneIds() => _byId.keys.toList(growable: false);

  @override
  MachineConnection? peek(String machineDeviceId) => _byId[machineDeviceId];

  @override
  Future<NativeStopResult?> release(String machineDeviceId) async {
    released.add(machineDeviceId);
    return NativeStopResult.stopped;
  }
}

void main() {
  group('supervisorStatusProvider through a ProviderContainer', () {
    /// Production ordering (`agent_transport.dart`): `connectionFor()` fires
    /// the change event, then the epoch read and the token mint each await —
    /// a real `SharedPreferencesAsync` platform round trip on the first relay
    /// connection of a launch — and only then does `ensureStarted()` build the
    /// supervisor. A provider that peeks at `conn.supervisor` once, on the
    /// change event, sees null and never hears about the supervisor at all.
    Future<void> productionOrderingGap() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    ({MachineConnectionManager mgr, ProviderContainer container}) harness() {
      final mgr = MachineConnectionManager(crypto: CryptoService());
      final container = ProviderContainer(
        overrides: [relayConnectionManagerProvider.overrideWithValue(mgr)],
      );
      addTearDown(mgr.disposeAll);
      addTearDown(container.dispose);
      return (mgr: mgr, container: container);
    }

    test('a supervisor built several event-loop turns after the subscription '
        'still reaches the provider', () async {
      final h = harness();
      final sub = h.container.listen(
        supervisorStatusProvider('m'),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      final conn = h.mgr.connectionFor('m');
      await productionOrderingGap();
      conn.ensureStarted(mechanisms: _toggleable(conn, 'm'));

      await _waitUntil(
        () =>
            h.container.read(supervisorStatusProvider('m')).value is Connected,
        timeout: const Duration(seconds: 3),
      );
    });

    test('a released machine stops reporting a live status, and a fresh '
        'connection for the same id does not inherit the old one', () async {
      final h = harness();
      final sub = h.container.listen(
        supervisorStatusProvider('m'),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      final conn = h.mgr.connectionFor('m');
      await productionOrderingGap();
      conn.ensureStarted(mechanisms: _toggleable(conn, 'm'));
      await _waitUntil(
        () =>
            h.container.read(supervisorStatusProvider('m')).value is Connected,
        timeout: const Duration(seconds: 3),
      );

      // The control-plane reaper drops the machine, then something re-dials it.
      await h.mgr.release('m');
      h.mgr.connectionFor('m');

      await _waitUntil(
        () => h.container.read(supervisorStatusProvider('m')).value == null,
        timeout: const Duration(seconds: 3),
      );
      // A reaped socket that still reported Connected would light the boot
      // screen's 'agent link — done' for a machine with no socket at all.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.container.read(supervisorStatusProvider('m')).value, isNull);
    });
  });

  group('agentReachabilityProvider mapping (reachabilityForStatus)', () {
    test('Connected -> online', () {
      expect(
        reachabilityForStatus(const Connected()),
        AgentReachability.online,
      );
    });

    test('every other Blocked reason stays connecting, never offline', () {
      for (final reason in BlockReason.values) {
        expect(
          reachabilityForStatus(Blocked(reason)),
          AgentReachability.connecting,
          reason:
              '$reason must not collapse into the "not reachable" bucket — '
              'native payload failures remain retry-controlled',
        );
      }
    });

    test('Climbing -> connecting', () {
      for (final rung in ConnRung.values) {
        expect(
          reachabilityForStatus(Climbing(rung)),
          AgentReachability.connecting,
        );
      }
    });

    test('Released -> connecting', () {
      expect(
        reachabilityForStatus(const Released()),
        AgentReachability.connecting,
      );
    });

    test('null (nothing dialed yet) -> connecting', () {
      expect(reachabilityForStatus(null), AgentReachability.connecting);
    });
  });

  group(
    'RelayConnectionManager.noteResume() fans out to every live machine',
    () {
      test('a rung that silently broke with no edge event is retried on EVERY '
          'live connection, not just one', () async {
        final mgr = MachineConnectionManager(crypto: CryptoService());
        addTearDown(mgr.disposeAll);

        final connA = mgr.connectionFor('a');
        final connB = mgr.connectionFor('b');
        final mechA = _ToggleableMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          crypto: CryptoService(),
          machineDeviceId: 'a',
          phoneDeviceId: 'phone-1',
          phoneEd25519Seed: List<int>.filled(32, 7),
          resolveCoords: () async => const ConnCoords(
            relayUrl: 'ws://relay.test',
            agentEd25519PubB64: 'AGENT_PUB',
          ),
        );
        final mechB = _ToggleableMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          crypto: CryptoService(),
          machineDeviceId: 'b',
          phoneDeviceId: 'phone-1',
          phoneEd25519Seed: List<int>.filled(32, 7),
          resolveCoords: () async => const ConnCoords(
            relayUrl: 'ws://relay.test',
            agentEd25519PubB64: 'AGENT_PUB',
          ),
        );
        connA.ensureStarted(mechanisms: mechA);
        connB.ensureStarted(mechanisms: mechB);

        await _waitUntil(() => connA.supervisor!.status is Connected);
        await _waitUntil(() => connB.supervisor!.status is Connected);
        expect(mechA.dialCalls, 1);
        expect(mechB.dialCalls, 1);

        // The socket dies on BOTH machines with nothing else happening in the
        // app — no relay event, no user action. A backoff that was never
        // armed for this fresh break (it was reset to null on reaching
        // Connected) means the ladder is just waiting for someone to ask it
        // to look again.
        mechA.payloadOk = false;
        mechB.payloadOk = false;

        mgr.noteResume();

        await _waitUntil(() => mechA.dialCalls == 2);
        await _waitUntil(
          () => mechB.dialCalls == 2,
          timeout: const Duration(seconds: 1),
        );
      });
    },
  );

  group('reconcileControlPlaneWantedness', () {
    test('a machine that drops out of alive/openProjects gets setWanted(false) '
        'before it is released', () async {
      final mgr = MachineConnectionManager(crypto: CryptoService());
      addTearDown(mgr.disposeAll);
      final conn = mgr.connectionFor('m');
      conn.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          crypto: CryptoService(),
          machineDeviceId: 'm',
          phoneDeviceId: 'phone-1',
          phoneEd25519Seed: List<int>.filled(32, 7),
          // Never resolves — this test only needs a live supervisor to
          // toggle `wanted` on, not a real climb.
          resolveCoords: () async => null,
        ),
      );
      final fake = _NonDisposingManager({'m': conn});

      final released = reconcileControlPlaneWantedness(
        mgr: fake,
        alive: const <String>{},
        openProjects: const <String>{},
      );

      expect(released, ['m']);
      expect(fake.released, ['m']);
      await _waitUntil(
        () => conn.supervisor!.status is Released,
        timeout: const Duration(seconds: 2),
      );
    });

    test('a live machine in alive is never released', () async {
      final mgr = MachineConnectionManager(crypto: CryptoService());
      addTearDown(mgr.disposeAll);
      final conn = mgr.connectionFor('m');
      conn.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          crypto: CryptoService(),
          machineDeviceId: 'm',
          phoneDeviceId: 'phone-1',
          phoneEd25519Seed: List<int>.filled(32, 7),
          resolveCoords: () async => null,
        ),
      );
      final fake = _NonDisposingManager({'m': conn});
      final released = reconcileControlPlaneWantedness(
        mgr: fake,
        alive: const {'m'},
        openProjects: const <String>{},
      );

      expect(released, isEmpty);
      expect(fake.released, isEmpty);
    });
  });
}
