// A dial must always settle, whatever the PREVIOUS socket does.
//
// Field bug this guards: after a relay was killed without a close handshake,
// the app opened exactly one socket, sent zero bytes, and never retried until
// restart. `_doConnect` was awaiting the dead channel's `sink.close()` — which
// waits for a FIN that a killed peer never sends — so the hello was never
// built, and `connect()` never even returned its future to the caller. The
// watchdog fired into a completer nobody was awaiting yet, the supervisor's
// dial step never settled, and its single-flight `evaluate()` wedged with no
// backoff timer scheduled. Symptom on the wire: a socket held for exactly
// HELLO_TIMEOUT_MS, then silence.
//
// Live loopback rather than a mocked channel, for the same reason as
// relay_service_reconnect_test.dart: RelayService opens its own
// WebSocketChannel, so the only way to prove the hello left the app is to
// watch a real server receive it.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay_ws_server.dart';

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(32),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

/// Stands in for a socket whose peer vanished without a close handshake: its
/// `close()` is observable but never completes.
class _StuckSink implements WebSocketSink {
  _StuckSink({required this.hangOnClose});

  final bool hangOnClose;
  final closeCalled = Completer<void>();

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!closeCalled.isCompleted) closeCalled.complete();
    return hangOnClose ? Completer<void>().future : Future<void>.value();
  }

  @override
  void add(dynamic data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StuckChannel implements WebSocketChannel {
  _StuckChannel({required bool hangOnClose})
    : stuckSink = _StuckSink(hangOnClose: hangOnClose);

  final _StuckSink stuckSink;

  @override
  WebSocketSink get sink => stuckSink;

  @override
  Stream<dynamic> get stream => const Stream<dynamic>.empty();

  @override
  Future<void> get ready => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  test('a dial whose previous channel never finishes closing still sends its '
      'hello and still fails on the watchdog', () async {
    final dead = _StuckChannel(hangOnClose: true);
    relay.debugSetChannel(dead);
    relay.debugSetConnectTimeout(const Duration(milliseconds: 400));

    final connect = relay.connect(
      server.wsUrl,
      _identity(),
      licenseToken: 'tok',
      epoch: 1,
    );
    // Attached before the failure lands: this is the future's only listener,
    // and a rejection with nothing listening surfaces as an unhandled error.
    final rejected = expectLater(
      connect,
      throwsA(
        isA<RelayConnectException>()
            .having((e) => e.code, 'code', 'HELLO_TIMEOUT')
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );

    // The heart of it: the hello reaches the relay even though the previous
    // channel is still stuck closing. Under the bug this never arrived.
    expect(
      await conns.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
      reason: 'the dial must not be held hostage by the dead socket',
    );
    expect(conns.current.hello['type'], 'hello');

    // ...and the attempt still settles, so the supervisor can score it and
    // schedule the next one.
    await rejected;
    expect(
      dead.stuckSink.closeCalled.isCompleted,
      isTrue,
      reason: 'the old channel is still retired, just not waited on',
    );
  });

  test('disconnect() still closes the live socket', () async {
    // Guards the placement of the `_channel = null` that retires a dropped
    // socket: nulling it in `_cleanup()` instead of on the drop path would
    // silently stop `disconnect()` from ever closing anything, since
    // `disconnect()` calls `_cleanup()` first.
    final live = _StuckChannel(hangOnClose: false);
    relay.debugSetChannel(live);

    relay.disconnect();

    expect(live.stuckSink.closeCalled.isCompleted, isTrue);
  });
}
