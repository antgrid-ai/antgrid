import 'package:antgrid/analytics/crash_reporting.dart';
import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../helpers/fixed_peer_connector.dart';

class _RecordingSink implements ConnectionBlockSink {
  final breadcrumbs = <Breadcrumb>[];
  final captures = <Map<String, String>>[];

  @override
  void addBreadcrumb(Breadcrumb breadcrumb) => breadcrumbs.add(breadcrumb);

  @override
  void captureWarning(
    String message, {
    required Map<String, String> tags,
    required List<String> fingerprint,
  }) => captures.add(tags);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a terminal native failure blocks and reports its reason and code',
    () async {
      final sink = _RecordingSink();
      final connection = MachineConnection(
        machineDeviceId: 'M',
        crypto: CryptoService(),
        blockReporter: ConnectionBlockReporter(sink: sink),
      );
      addTearDown(connection.dispose);
      connection.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          machineDeviceId: 'M',
          resolveCoords: () async => const ConnCoords(
            relayUrl: 'wss://relay.test',
            agentEd25519PubB64: 'pin',
          ),
          peerRuntime: FailingPeerConnector(
            const PeerConnectionFailure('AUTHORIZATION_DENIED', terminal: true),
          ),
        ),
      );
      final supervisor = connection.nativeSupervisor!;
      supervisor.setWanted(true);

      for (var i = 0; i < 50 && supervisor.status is! Blocked; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(supervisor.status, const Blocked(BlockReason.peerRejected));
      expect(sink.breadcrumbs.single.data, {
        'reason': 'peerRejected',
        'code': 'AUTHORIZATION_DENIED',
      });
      expect(
        sink.captures.single['connection.failure_code'],
        'AUTHORIZATION_DENIED',
      );
    },
  );

  test('a connection whose telemetry gate is closed reports nothing', () async {
    final sink = _RecordingSink();
    final connection = MachineConnection(
      machineDeviceId: 'M',
      crypto: CryptoService(),
      blockReporter: ConnectionBlockReporter(sink: sink),
      telemetryAllowed: () => false,
    );
    addTearDown(connection.dispose);
    connection.ensureStarted(
      mechanisms: PeerConnectionMechanisms(
        machineDeviceId: 'M',
        resolveCoords: () async => const ConnCoords(
          relayUrl: 'wss://relay.test',
          agentEd25519PubB64: 'pin',
        ),
        peerRuntime: FailingPeerConnector(
          const PeerConnectionFailure('AUTHORIZATION_DENIED', terminal: true),
        ),
      ),
    );
    final supervisor = connection.nativeSupervisor!;
    supervisor.setWanted(true);

    for (var i = 0; i < 50 && supervisor.status is! Blocked; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(supervisor.status, const Blocked(BlockReason.peerRejected));
    expect(sink.breadcrumbs, isEmpty);
    expect(sink.captures, isEmpty);
  });
}
