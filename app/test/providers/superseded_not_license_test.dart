import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixed_peer_connector.dart';

class _FakeManager extends MachineConnectionManager {
  _FakeManager(this.connection) : super(crypto: CryptoService());

  final MachineConnection connection;

  @override
  MachineConnection connectionFor(String machineDeviceId) => connection;

  @override
  MachineConnection? peek(String machineDeviceId) => connection;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SUPERSEDED is a separate central conflict cleared only by Retry',
    () async {
      final connection = MachineConnection(
        machineDeviceId: 'M',
        crypto: CryptoService(),
      );
      addTearDown(connection.dispose);
      connection.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          machineDeviceId: 'M',
          resolveCoords: () async => null,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          relayConnectionManagerProvider.overrideWithValue(
            _FakeManager(connection),
          ),
        ],
      );
      addTearDown(container.dispose);

      final conflictProvider = centralControlConflictProvider('M');
      final conflictSub = container.listen(conflictProvider, (_, _) {});
      addTearDown(conflictSub.close);
      expect(await container.read(conflictProvider.future), isFalse);

      connection.centralSupervisor!.noteRelayError('SUPERSEDED');
      for (
        var i = 0;
        i < 20 && container.read(conflictProvider).value != true;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(conflictProvider).value, isTrue);
      expect(connection.nativeSupervisor!.status, isNot(isA<Blocked>()));
      expect(RelayLicenseErrorCode.fromWire('SUPERSEDED'), isNull);

      connection.nativeSupervisor!.noteFreshToken();
      connection.nativeSupervisor!.notePresence(true);
      await container.pump();
      expect(container.read(conflictProvider).value, isTrue);

      connection.retry();
      for (
        var i = 0;
        i < 20 && container.read(conflictProvider).value != false;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(conflictProvider).value, isFalse);
    },
  );
}
