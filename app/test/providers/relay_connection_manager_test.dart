import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/relay_connection.dart';
import '../helpers/fixed_peer_connector.dart';

PeerConnectionMechanisms _mechanismsFor(
  MachineConnection conn,
  String machineId,
) => PeerConnectionMechanisms(
  peerRuntime: FixedPeerConnector.stub(),
  machineDeviceId: machineId,
  // Never resolves — these tests only need a live supervisor to ping, not
  // a real climb to Connected.
  resolveCoords: () async => null,
);

void main() {
  test('returns one connection per machine, memoized across compound ids', () {
    final mgr = MachineConnectionManager(crypto: CryptoService());
    addTearDown(mgr.disposeAll);

    final a1 = mgr.connectionFor('uuid');
    final a2 = mgr.connectionFor('uuid');
    // v3: a compound `<uuid>.<projectId>` id normalizes to its base machine —
    // projects are stream views inside the ONE machine socket, never their own.
    final b = mgr.connectionFor('uuid.proj');
    final other = mgr.connectionFor('uuid2');

    expect(identical(a1, a2), isTrue, reason: 'same id memoizes');
    expect(
      identical(a1, b),
      isTrue,
      reason: 'compound id lands on its bare machine slot',
    );
    expect(
      b.machineDeviceId,
      'uuid',
      reason: 'the connection identity is the BARE machine uuid',
    );
    expect(
      identical(a1, other),
      isFalse,
      reason: 'distinct machine distinct socket',
    );
    expect(
      a1.relay,
      isNot(same(other.relay)),
      reason: 'isolation: each machine has its own RelayService',
    );
  });

  test('release disposes and drops a single connection', () async {
    final mgr = MachineConnectionManager(crypto: CryptoService());
    addTearDown(mgr.disposeAll);
    final a = mgr.connectionFor('uuid');
    expect(await mgr.release('uuid'), NativeStopResult.stopped);
    final a2 = mgr.connectionFor('uuid');
    expect(identical(a, a2), isFalse, reason: 'released → rebuilt fresh');
  });

  test('two DIFFERENT projects on one machine resolve to the identical '
      'connection — the provider-wiring half of "one MachineSession per '
      'machine" (the session/RelayService itself is proven at '
      'relay_connection_open_test.dart)', () {
    final mgr = MachineConnectionManager(crypto: CryptoService());
    addTearDown(mgr.disposeAll);

    final projectA = mgr.connectionFor('uuid.proj-a');
    final projectB = mgr.connectionFor('uuid.proj-b');

    expect(
      identical(projectA, projectB),
      isTrue,
      reason: 'both compound ids share the bare machine slot',
    );
    expect(
      identical(projectA.relay, projectB.relay),
      isTrue,
      reason: 'only ONE RelayService is ever constructed for the machine',
    );
    expect(mgr.openControlPlaneIds(), ['uuid']);
  });

  test(
    'central supersession conflicts immediately and Retry clears it',
    () async {
      final mgr = MachineConnectionManager(crypto: CryptoService());
      addTearDown(mgr.disposeAll);
      final connection = mgr.connectionFor('m');
      connection.ensureStarted(mechanisms: _mechanismsFor(connection, 'm'));

      connection.centralSupervisor!.noteRelayError('SUPERSEDED');
      expect(connection.centralSupervisor!.conflict, isTrue);
      expect(connection.nativeSupervisor!.status, isNot(isA<Blocked>()));

      connection.nativeSupervisor!.noteFreshToken();
      expect(connection.centralSupervisor!.conflict, isTrue);

      connection.retry();
      expect(connection.centralSupervisor!.conflict, isFalse);
    },
  );

  test('disposeAll blocks new slots and returns typed outcomes', () async {
    final mgr = MachineConnectionManager(crypto: CryptoService());
    mgr.connectionFor('m');

    expect(await mgr.disposeAll(), {'m': NativeStopResult.stopped});
    expect(mgr.newWorkBlocked, isTrue);
    expect(() => mgr.connectionFor('other'), throwsStateError);
  });
}
