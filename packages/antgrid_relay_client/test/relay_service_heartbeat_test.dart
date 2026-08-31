import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_relay_ws_server.dart';

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1#machine-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(32),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

Map<String, dynamic> _welcome() => {
  'type': 'welcome',
  'deviceId': 'phone-1#machine-1',
  'epoch': 1,
  'serverTime': DateTime.now().toUtc().toIso8601String(),
};

void main() {
  late FakeRelayWsServer server;
  late RelayService relay;
  late StreamIterator<FakeRelayConnection> connections;

  setUp(() async {
    server = await FakeRelayWsServer.start();
    relay = RelayService(crypto: CryptoService());
    relay.debugSetHeartbeatInterval(const Duration(milliseconds: 60));
    connections = StreamIterator(server.connections);
  });

  tearDown(() async {
    relay.dispose();
    await connections.cancel();
    await server.close();
  });

  Future<({FakeRelayConnection connection, Future<void> connect})>
  dial() async {
    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
      machineDeviceId: 'machine-1',
    );
    expect(await connections.moveNext(), isTrue);
    return (connection: connections.current, connect: connect);
  }

  test('heartbeat begins only after welcome', () async {
    final attempt = await dial();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(attempt.connection.receivedCount, 0);

    attempt.connection.sendJson(_welcome());
    await attempt.connect;
    expect(await attempt.connection.nextJson(), {'type': 'ping'});
  });

  test(
    'pong and a valid routed frame each clear an outstanding probe',
    () async {
      final attempt = await dial();
      attempt.connection.sendJson(_welcome());
      await attempt.connect;

      expect(await attempt.connection.nextJson(), {'type': 'ping'});
      attempt.connection.sendJson({'type': 'pong'});
      expect(await attempt.connection.nextJson(), {'type': 'ping'});

      attempt.connection.sendBinary(
        encodeRouteFrame(
          {'type': 'message', 'from': 'machine-1', 'channel': 'agent'},
          Uint8List.fromList(utf8.encode('sealed')),
          FrameKind.sealed,
        ),
      );
      expect(await attempt.connection.nextJson(), {'type': 'ping'});
      attempt.connection.sendJson({'type': 'pong'});
      expect(
        relay.currentState.connectionState,
        RelayConnectionState.authenticated,
      );
    },
  );

  test('unknown and malformed input do not clear a probe', () async {
    final attempt = await dial();
    attempt.connection.sendJson(_welcome());
    await attempt.connect;

    expect(await attempt.connection.nextJson(), {'type': 'ping'});
    attempt.connection.sendJson({'type': 'future-message'});
    attempt.connection.sendText('not json');
    final disconnected = relay.stateStream.firstWhere(
      (s) => s.connectionState == RelayConnectionState.disconnected,
    );
    await attempt.connection.done.timeout(const Duration(seconds: 1));
    await disconnected.timeout(const Duration(seconds: 1));
  });

  test('timeout logs diagnostics and never creates its own redial', () async {
    final logs =
        <
          ({RelayLogLevel level, String message, Map<String, Object?>? fields})
        >[];
    relay.dispose();
    relay = RelayService(
      crypto: CryptoService(),
      logger: (level, message, {fields}) {
        logs.add((level: level, message: message, fields: fields));
      },
    )..debugSetHeartbeatInterval(const Duration(milliseconds: 50));

    final attempt = await dial();
    attempt.connection.sendJson(_welcome());
    await attempt.connect;
    expect(await attempt.connection.nextJson(), {'type': 'ping'});
    await attempt.connection.done.timeout(const Duration(seconds: 1));

    final timeout = logs.singleWhere(
      (e) => e.message == 'relay heartbeat timed out',
    );
    expect(timeout.level, RelayLogLevel.warn);
    expect(timeout.fields, containsPair('machineSlot', 'phone-1#machine-1'));
    expect(timeout.fields?['socketAgeMs'], isA<int>());
    expect(timeout.fields?['lastInboundAgeMs'], isA<int>());
    expect(timeout.fields?['outstandingProbeAgeMs'], isA<int>());
    expect(
      await connections.moveNext().timeout(
        const Duration(milliseconds: 150),
        onTimeout: () => false,
      ),
      isFalse,
    );
  });

  test(
    'resume leaves fresh sockets alone and probes stale sockets immediately',
    () async {
      final attempt = await dial();
      attempt.connection.sendJson(_welcome());
      await attempt.connect;
      relay.debugPauseHeartbeat();

      relay.onResume();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(attempt.connection.receivedCount, 0);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      relay.onResume();
      expect(await attempt.connection.nextJson(), {'type': 'ping'});
      attempt.connection.sendJson({'type': 'pong'});
    },
  );

  test('resume does not shorten an outstanding probe deadline', () async {
    relay.debugSetHeartbeatInterval(const Duration(milliseconds: 100));
    final attempt = await dial();
    attempt.connection.sendJson(_welcome());
    await attempt.connect;

    expect(await attempt.connection.nextJson(), {'type': 'ping'});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    relay.onResume();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(
      relay.currentState.connectionState,
      RelayConnectionState.authenticated,
    );
    attempt.connection.sendJson({'type': 'pong'});
  });

  test(
    'disconnect cancels the old heartbeat before a replacement dial',
    () async {
      final first = await dial();
      first.connection.sendJson(_welcome());
      await first.connect;
      relay.disconnect();

      final secondFuture = relay.connect(
        server.wsUrl,
        _identity(),
        licenseToken: 'tok-2',
        epoch: 1,
        machineDeviceId: 'machine-1',
      );
      expect(await connections.moveNext(), isTrue);
      final second = connections.current;
      second.sendJson(_welcome());
      await secondFuture;
      expect(await second.nextJson(), {'type': 'ping'});
      second.sendJson({'type': 'pong'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        relay.currentState.connectionState,
        RelayConnectionState.authenticated,
      );
    },
  );
}
