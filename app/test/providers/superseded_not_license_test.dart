import 'dart:typed_data';

import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixed_peer_connector.dart';

class _FakeManager extends RelayConnectionManager {
  _FakeManager(this.connection) : super(crypto: CryptoService());

  final RelayConnection connection;

  @override
  RelayConnection connectionFor(String machineDeviceId) => connection;

  @override
  RelayConnection? peek(String machineDeviceId) => connection;
}

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(64),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SUPERSEDED is a separate central conflict cleared only by Retry',
    () async {
      final connection = RelayConnection(
        machineDeviceId: 'M',
        crypto: CryptoService(),
      );
      addTearDown(connection.dispose);
      connection.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          relay: connection.relay,
          peerRuntime: FixedPeerConnector.stub(),
          crypto: CryptoService(),
          machineDeviceId: 'M',
          identity: _identity(),
          phoneDeviceId: 'phone-1',
          phoneEd25519Seed: List<int>.filled(32, 7),
          epoch: 1,
          resolveCoords: () async => null,
          mintToken: () async => 'token',
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

      connection.supervisor!.noteRelayError('SUPERSEDED', retryable: false);
      for (
        var i = 0;
        i < 20 && container.read(conflictProvider).value != true;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(conflictProvider).value, isTrue);
      expect(connection.supervisor!.status, isNot(isA<Blocked>()));
      expect(RelayLicenseErrorCode.fromWire('SUPERSEDED'), isNull);

      connection.supervisor!.noteFreshToken();
      connection.supervisor!.notePresence(true);
      await container.pump();
      expect(container.read(conflictProvider).value, isTrue);

      connection.supervisor!.retry();
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
