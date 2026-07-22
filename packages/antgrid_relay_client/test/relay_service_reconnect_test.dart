// Live-socket coverage for RelayService's hello/backoff/error-classification
// state machine. Unlike relay_service_hello_test.dart (debugHandleFrame,
// no socket), these tests run connect() against a real loopback WebSocket
// server (support/fake_relay_ws_server.dart) — required to observe reconnect
// TIMING and successive hello frames, which debugHandleFrame can't drive
// (RelayService opens its own WebSocketChannel internally; there is no
// injection seam for it).
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_relay_ws_server.dart';

DeviceIdentity _identity() => DeviceIdentity(
      deviceId: 'phone-1',
      name: 'Test Phone',
      ed25519PrivateKey: Uint8List(32),
      ed25519PublicKey: Uint8List(32),
      x25519PrivateKey: Uint8List(32),
      x25519PublicKey: Uint8List(32),
    );

/// Waits until [pred] holds for the service's connection state.
///
/// Checks [RelayService.currentState] BEFORE subscribing: `stateStream` is a
/// broadcast stream with no replay, and the transition these tests trigger can
/// land before the wait begins — the client processes a queued error frame
/// while the test is still awaiting the server-side `close()`. Subscribing
/// first and only then reading would miss it and hang for the full timeout.
Future<void> _awaitState(
  RelayService relay,
  bool Function(AppState) pred, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (pred(relay.currentState)) return;
  await relay.stateStream.firstWhere(pred).timeout(timeout);
}

bool _isDisconnected(AppState s) =>
    s.connectionState == RelayConnectionState.disconnected;
bool _isAuthenticated(AppState s) =>
    s.connectionState == RelayConnectionState.authenticated;

void main() {
  late FakeRelayWsServer server;
  late RelayService relay;
  late StreamIterator<FakeRelayConnection> conns;

  setUp(() async {
    server = await FakeRelayWsServer.start();
    relay = RelayService(crypto: CryptoService());
    conns = StreamIterator<FakeRelayConnection>(server.connections);
  });

  tearDown(() async {
    await conns.cancel();
    relay.dispose();
    await server.close();
  });

  test('welcome authenticates over a real socket', () async {
    await relay.connect(server.wsUrl, _identity(),
        licenseToken: 'tok', epoch: 1);
    expect(await conns.moveNext(), isTrue);
    final conn = conns.current;
    expect(conn.hello['type'], 'hello');
    expect(conn.hello['protocolVersion'], 3);
    conn.sendJson({
      'type': 'welcome',
      'deviceId': 'phone-1',
      'epoch': 1,
      'serverTime': DateTime.now().toUtc().toIso8601String(),
    });

    await _awaitState(relay, _isAuthenticated);
  });

  test(
    'clock-skew AUTH_FAILED adjusts the next hello\'s ts once; a second '
    'consecutive skew with the same serverTime does not re-apply/double the '
    'offset, and the connection still recovers',
    () async {
      await relay.connect(server.wsUrl, _identity(),
          licenseToken: 'tok', epoch: 1);

      expect(await conns.moveNext(), isTrue);
      final conn1 = conns.current;
      final ts1 = DateTime.parse(conn1.hello['ts'] as String);

      // Far enough from real "now" that an adjusted ts is unmistakable.
      final serverTime =
          DateTime.now().toUtc().add(const Duration(hours: 2));
      conn1.sendJson({
        'type': 'error',
        'code': 'AUTH_FAILED',
        'message': 'clock skew',
        'retryable': true,
        'serverTime': serverTime.toIso8601String(),
      });
      await conn1.close();

      expect(await conns.moveNext(), isTrue);
      final conn2 = conns.current;
      final ts2 = DateTime.parse(conn2.hello['ts'] as String);
      expect(ts1.difference(serverTime).inMinutes.abs(), greaterThan(30),
          reason: 'sanity: the first hello was not already skewed');
      expect(ts2.difference(serverTime).inSeconds.abs(), lessThan(10),
          reason: 'the retried hello must carry the corrected ts');

      // Same serverTime again: _appliedSkewMs guards against re-applying the
      // identical offset — the corrected ts must not drift further/double.
      conn2.sendJson({
        'type': 'error',
        'code': 'AUTH_FAILED',
        'message': 'clock skew (again, same offset)',
        'retryable': true,
        'serverTime': serverTime.toIso8601String(),
      });
      await conn2.close();

      expect(await conns.moveNext(), isTrue);
      final conn3 = conns.current;
      final ts3 = DateTime.parse(conn3.hello['ts'] as String);
      expect(ts3.difference(ts2).inSeconds.abs(), lessThan(10),
          reason: 'the offset must not be re-applied a second time');

      // The second consecutive skew failure "surfaces normally": it's just
      // another retryable close, and the connection keeps retrying/recovers.
      conn3.sendJson({
        'type': 'welcome',
        'deviceId': 'phone-1',
        'epoch': 1,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
      });
      await _awaitState(relay, _isAuthenticated);
    },
  );

  test(
    'a retryable:false error closes the socket and the client does NOT '
    'reconnect',
    () async {
      await relay.connect(server.wsUrl, _identity(),
          licenseToken: 'tok', epoch: 1);
      expect(await conns.moveNext(), isTrue);
      final conn1 = conns.current;
      conn1.sendJson({
        'type': 'error',
        'code': 'PROTOCOL_VIOLATION',
        'message': 'bad frame',
        'retryable': false,
      });
      await conn1.close();

      await _awaitState(relay, _isDisconnected);
      expect(relay.currentState.errorCode, 'PROTOCOL_VIOLATION');

      final sawReconnect = await conns
          .moveNext()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
      expect(sawReconnect, isFalse,
          reason:
              'retryable:false marks the disconnect intentional — no auto-reconnect');
    },
  );

  test(
    'a retryable error followed by a close triggers a jittered backoff '
    'reconnect',
    () async {
      await relay.connect(server.wsUrl, _identity(),
          licenseToken: 'tok', epoch: 1);
      expect(await conns.moveNext(), isTrue);
      final conn1 = conns.current;
      conn1.sendJson({
        'type': 'error',
        'code': 'AGENT_OFFLINE',
        'message': 'not yet registered',
        'retryable': true,
      });
      await conn1.close();

      final sawReconnect = await conns
          .moveNext()
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
      expect(sawReconnect, isTrue,
          reason: 'a retryable close must schedule a backoff reconnect');
    },
  );

  test(
    'a bare close with NO error frame at all also triggers a jittered '
    'backoff reconnect',
    () async {
      await relay.connect(server.wsUrl, _identity(),
          licenseToken: 'tok', epoch: 1);
      expect(await conns.moveNext(), isTrue);
      await conns.current.close(); // network drop — no error frame

      final sawReconnect = await conns
          .moveNext()
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
      expect(sawReconnect, isTrue,
          reason: 'an unexplained close is retryable by default');
    },
  );

  test(
    'SUPERSEDED is terminal-for-this-socket (no reconnect) but is NOT '
    'classified as a license error',
    () async {
      final errorEvents = <ErrorMessage>[];
      final errSub = relay.errorStream.listen(errorEvents.add);
      final licenseEvents = <RelayLicenseErrorCode>[];
      final licenseSub = relay.licenseErrorStream.listen(licenseEvents.add);
      addTearDown(errSub.cancel);
      addTearDown(licenseSub.cancel);

      await relay.connect(server.wsUrl, _identity(),
          licenseToken: 'tok', epoch: 1);
      expect(await conns.moveNext(), isTrue);
      final conn1 = conns.current;
      conn1.sendJson({
        'type': 'error',
        'code': 'SUPERSEDED',
        'message': 'replaced by a newer connection',
        'retryable': false,
      });
      await conn1.close();

      await _awaitState(relay, _isDisconnected);
      expect(relay.currentState.errorCode, 'SUPERSEDED');
      expect(errorEvents.map((e) => e.code), contains('SUPERSEDED'));

      final sawReconnect = await conns
          .moveNext()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
      expect(sawReconnect, isFalse,
          reason: 'SUPERSEDED is retryable:false — terminal for this socket');
      // Checked last (after the 2s reconnect-wait window has already elapsed)
      // so a late/misordered emission can't produce a false negative.
      expect(licenseEvents, isEmpty,
          reason:
              'SUPERSEDED must never surface on licenseErrorStream — it is '
              'not a "re-activate" condition');
    },
  );

  test(
    'a genuine license error (contrast case) DOES surface on '
    'licenseErrorStream, unlike SUPERSEDED',
    () async {
      final licenseEvents = <RelayLicenseErrorCode>[];
      final licenseSub = relay.licenseErrorStream.listen(licenseEvents.add);
      addTearDown(licenseSub.cancel);

      await relay.connect(server.wsUrl, _identity(),
          licenseToken: 'tok', epoch: 1);
      expect(await conns.moveNext(), isTrue);
      final conn1 = conns.current;
      conn1.sendJson({
        'type': 'error',
        'code': 'LICENSE_INVALID',
        'message': 'license: LICENSE_INVALID',
        'retryable': false,
      });
      await conn1.close();

      await _awaitState(relay, _isDisconnected);
      // `licenseErrorStream` is populated a beat after the state transition
      // (see RelayService._handleError's ordering) — poll briefly rather than
      // race the exact microtask interleaving.
      for (var i = 0; i < 50 && licenseEvents.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(licenseEvents, [RelayLicenseErrorCode.licenseInvalid]);
    },
  );
}
