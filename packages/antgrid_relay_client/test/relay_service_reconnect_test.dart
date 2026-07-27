// Live-socket coverage for RelayService's hello / single-attempt-connect /
// error-classification state machine. Unlike relay_service_hello_test.dart
// (debugHandleFrame, no socket), these tests run connect() against a real
// loopback WebSocket server (support/fake_relay_ws_server.dart) — required to
// observe successive hello frames and to prove that NO second connection is
// ever made on its own (RelayService opens its own WebSocketChannel
// internally; there is no injection seam for it).
//
// The retry authority moved out of this class: `ConnectionSupervisor` owns
// when to dial again, so every "does it reconnect?" case below asserts that it
// does NOT. Backoff timing is covered by app/test/connection/
// connection_supervisor_test.dart.
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

/// True when the server accepted another connection within [window] — i.e. the
/// client re-dialled by itself. Must always be false now.
Future<bool> _sawRedial(
  StreamIterator<FakeRelayConnection> conns, {
  Duration window = const Duration(seconds: 2),
}) => conns.moveNext().timeout(window, onTimeout: () => false);

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

  test('connect() completes only on welcome', () async {
    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    var completed = false;
    unawaited(connect.then((_) => completed = true));

    expect(await conns.moveNext(), isTrue);
    final conn = conns.current;
    expect(conn.hello['type'], 'hello');
    expect(conn.hello['protocolVersion'], 3);
    expect(
      completed,
      isFalse,
      reason: 'the hello is out but the relay has not welcomed us yet',
    );

    conn.sendJson({
      'type': 'welcome',
      'deviceId': 'phone-1',
      'epoch': 1,
      'serverTime': DateTime.now().toUtc().toIso8601String(),
    });

    await connect;
    // The dial contract the supervisor scores against: by the time connect()
    // resolves, the socket must ALREADY read authenticated. A future that
    // resolves ahead of the flag makes every healthy dial look like a failure.
    expect(
      relay.currentState.connectionState,
      RelayConnectionState.authenticated,
    );
  });

  test('connect() throws when the socket closes before welcome', () async {
    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    // The expectation is attached BEFORE the failure is triggered: it is the
    // only listener on this future, and a rejection delivered while nothing is
    // listening surfaces as an unhandled async error instead of a failure.
    final rejected = expectLater(
      connect,
      throwsA(
        isA<RelayConnectException>().having(
          (e) => e.retryable,
          'retryable',
          isTrue,
        ),
      ),
    );
    expect(await conns.moveNext(), isTrue);
    await conns.current.close(); // network drop — no error frame
    await rejected;
    expect(
      await _sawRedial(conns),
      isFalse,
      reason: 'an unexplained close is the supervisor\'s to retry, not ours',
    );
  });

  test('a retryable error followed by a close does NOT self-redial', () async {
    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    final rejected = expectLater(
      connect,
      throwsA(isA<RelayConnectException>()),
    );
    expect(await conns.moveNext(), isTrue);
    final conn1 = conns.current;
    conn1.sendJson({
      'type': 'error',
      'code': 'AGENT_OFFLINE',
      'message': 'not yet registered',
      'retryable': true,
    });
    await conn1.close();
    await rejected;
    expect(
      await _sawRedial(conns),
      isFalse,
      reason: 'there is exactly one retry authority and it is not here',
    );
  });

  test(
    'a retryable:false error closes the socket and does NOT self-redial',
    () async {
      final connect = relay.connect(
        server.wsUrl,
        _identity(),
        licenseToken: 'tok',
        epoch: 1,
      );
      final rejected = expectLater(
        connect,
        throwsA(
          isA<RelayConnectException>()
              .having((e) => e.code, 'code', 'PROTOCOL_VIOLATION')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      expect(await conns.moveNext(), isTrue);
      final conn1 = conns.current;
      conn1.sendJson({
        'type': 'error',
        'code': 'PROTOCOL_VIOLATION',
        'message': 'bad frame',
        'retryable': false,
      });
      await conn1.close();
      await rejected;
      await _awaitState(relay, _isDisconnected);
      expect(relay.currentState.errorCode, 'PROTOCOL_VIOLATION');
      expect(await _sawRedial(conns), isFalse);
    },
  );

  test('clock-skew AUTH_FAILED adjusts the NEXT connect()\'s ts once; a second '
      'consecutive skew with the same serverTime does not re-apply/double the '
      'offset, and the connection still recovers', () async {
    final first = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    final firstRejected = expectLater(
      first,
      throwsA(isA<RelayConnectException>()),
    );

    expect(await conns.moveNext(), isTrue);
    final conn1 = conns.current;
    final ts1 = DateTime.parse(conn1.hello['ts'] as String);

    // Far enough from real "now" that an adjusted ts is unmistakable.
    final serverTime = DateTime.now().toUtc().add(const Duration(hours: 2));
    conn1.sendJson({
      'type': 'error',
      'code': 'AUTH_FAILED',
      'message': 'clock skew',
      'retryable': true,
      'serverTime': serverTime.toIso8601String(),
    });
    await conn1.close();
    await firstRejected;

    // The supervisor re-dials; the offset must ride along on the new hello.
    final second = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    final secondRejected = expectLater(
      second,
      throwsA(isA<RelayConnectException>()),
    );
    expect(await conns.moveNext(), isTrue);
    final conn2 = conns.current;
    final ts2 = DateTime.parse(conn2.hello['ts'] as String);
    expect(
      ts1.difference(serverTime).inMinutes.abs(),
      greaterThan(30),
      reason: 'sanity: the first hello was not already skewed',
    );
    expect(
      ts2.difference(serverTime).inSeconds.abs(),
      lessThan(10),
      reason: 'the retried hello must carry the corrected ts',
    );

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
    await secondRejected;

    final third = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    expect(await conns.moveNext(), isTrue);
    final conn3 = conns.current;
    final ts3 = DateTime.parse(conn3.hello['ts'] as String);
    expect(
      ts3.difference(ts2).inSeconds.abs(),
      lessThan(10),
      reason: 'the offset must not be re-applied a second time',
    );

    conn3.sendJson({
      'type': 'welcome',
      'deviceId': 'phone-1',
      'epoch': 1,
      'serverTime': DateTime.now().toUtc().toIso8601String(),
    });
    await third;
    await _awaitState(relay, _isAuthenticated);
  });

  test('SUPERSEDED is terminal-for-this-socket (no redial) but is NOT '
      'classified as a license error', () async {
    final errorEvents = <ErrorMessage>[];
    final errSub = relay.errorStream.listen(errorEvents.add);
    addTearDown(errSub.cancel);

    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    final rejected = expectLater(
      connect,
      throwsA(isA<RelayConnectException>()),
    );
    expect(await conns.moveNext(), isTrue);
    final conn1 = conns.current;
    conn1.sendJson({
      'type': 'error',
      'code': 'SUPERSEDED',
      'message': 'replaced by a newer connection',
      'retryable': false,
    });
    await conn1.close();

    await rejected;
    await _awaitState(relay, _isDisconnected);
    expect(relay.currentState.errorCode, 'SUPERSEDED');
    expect(errorEvents.map((e) => e.code), contains('SUPERSEDED'));

    expect(await _sawRedial(conns), isFalse);
    // `errorStream` is the sole failure channel now: a consumer classifying
    // license verdicts (ConnectionSupervisor.noteRelayError) must be able to
    // tell SUPERSEDED apart from LICENSE_* by CODE alone, since both are
    // `retryable:false` here.
    expect(
      RelayLicenseErrorCode.fromWire('SUPERSEDED'),
      isNull,
      reason:
          'SUPERSEDED must never parse as a license error code — '
          'the type a "re-activate" condition would need',
    );
  });

  test('a genuine license error (contrast case) surfaces on errorStream with '
      'its code intact, unlike SUPERSEDED', () async {
    final errorEvents = <ErrorMessage>[];
    final errSub = relay.errorStream.listen(errorEvents.add);
    addTearDown(errSub.cancel);

    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    final rejected = expectLater(
      connect,
      throwsA(
        isA<RelayConnectException>().having(
          (e) => e.code,
          'code',
          'LICENSE_INVALID',
        ),
      ),
    );
    expect(await conns.moveNext(), isTrue);
    final conn1 = conns.current;
    conn1.sendJson({
      'type': 'error',
      'code': 'LICENSE_INVALID',
      'message': 'license: LICENSE_INVALID',
      'retryable': false,
    });
    await conn1.close();
    await rejected;
    await _awaitState(relay, _isDisconnected);
    expect(errorEvents.map((e) => e.code), ['LICENSE_INVALID']);
    expect(
      RelayLicenseErrorCode.fromWire(errorEvents.single.code),
      RelayLicenseErrorCode.licenseInvalid,
    );
  });
}
