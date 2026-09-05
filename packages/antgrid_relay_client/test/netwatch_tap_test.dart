// Frame-capture hook coverage: the wire taps in RelayService, the type
// annotations MachineSession adds on top of them, and the drops that until now
// returned silently.
//
// Split deliberately across two harnesses. FakeLiveRelay OVERRIDES
// `sendMessage`, so the real body — where the outbound wire tap lives — never
// runs under it; the wire taps are asserted against a real RelayService via its
// `debugHandleFrame` seam instead, and only the annotations are asserted at the
// MachineSession level.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';
import 'support/fake_relay_ws_server.dart';

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

/// A capture that just collects, standing in for `app/lib/util/netwatch.dart`.
class _Capture {
  final events = <Map<String, Object?>>[];
  RelayNetTap get tap => events.add;

  Iterable<Map<String, Object?>> get frames =>
      events.where((e) => e['op'] != 'annotate');
  Iterable<Map<String, Object?>> get annotations =>
      events.where((e) => e['op'] == 'annotate');
  Iterable<Map<String, Object?>> get drops =>
      frames.where((e) => e['kind'] == 'drop');

  Map<String, Object?> annotationFor(String frameId) =>
      annotations.singleWhere((e) => e['frameId'] == frameId);
}

Uint8List _sealedLookingPayload(int fill) =>
    Uint8List.fromList(List<int>.filled(12, fill) + utf8.encode('ciphertext'));

void main() {
  group('frameIdOf', () {
    test('uses the sealed frame own nonce, which both endpoints see', () {
      expect(
        frameIdOf(_sealedLookingPayload(0xab), FrameKind.sealed),
        'ab' * 12,
      );
    });

    test('falls back to a hash for a plaintext frame, which carries no nonce', () {
      final id = frameIdOf(
        Uint8List.fromList(utf8.encode('{"type":"handshake:client-hello"}')),
        FrameKind.handshake,
      );
      // Pinned, not merely well-formed. The SAME bytes are hashed by
      // `frameIdFor` in bridge/src/netwatch.ts and asserted against this exact
      // string there — the pair is hand-mirrored, so a silent divergence would
      // otherwise surface only as a `--join` that matches nothing.
      expect(id, '59e7c7d96c01d53688b362a9');
    });

    test('a short sealed payload cannot yield a nonce and is hashed', () {
      final id = frameIdOf(Uint8List.fromList([1, 2, 3]), FrameKind.sealed);
      expect(id, hasLength(24));
    });
  });

  group('RelayService wire taps', () {
    late _Capture capture;
    late RelayService relay;

    setUp(() {
      capture = _Capture();
      relay = RelayService(crypto: CryptoService(), netTap: capture.tap);
    });

    tearDown(() => relay.dispose());

    test('records the send that logs nothing today: no socket', () {
      relay.sendMessage('machine-1', 'control', _sealedLookingPayload(0x11));

      final drop = capture.drops.single;
      expect(drop['reason'], 'socket-not-open');
      expect(drop['dir'], 'tx');
      expect(drop['channel'], 'control');
      expect(drop['frameId'], '11' * 12);
      expect(drop['bytes'], isA<int>());
    });

    test('records an inbound sealed frame with its nonce and channel', () {
      relay.debugHandleFrame(
        encodeRouteFrame(
          {'type': 'message', 'from': 'machine-1', 'channel': 'control'},
          _sealedLookingPayload(0x7f),
          FrameKind.sealed,
        ),
      );

      final rx = capture.frames.single;
      expect(rx['dir'], 'rx');
      expect(rx['kind'], 'sealed');
      expect(rx['channel'], 'control');
      expect(rx['frameId'], '7f' * 12);
    });

    test('records an inbound handshake frame as its own kind', () {
      final payload = Uint8List.fromList(utf8.encode('{"type":"x"}'));
      relay.debugHandleFrame(
        encodeRouteFrame(
          {'type': 'message', 'from': 'machine-1', 'channel': 'control'},
          payload,
          FrameKind.handshake,
        ),
      );

      final rx = capture.frames.single;
      expect(rx['kind'], 'handshake');
      // Hashed, not nonce-prefixed: a kind-1 frame is plaintext.
      expect(rx['frameId'], frameIdOf(payload, FrameKind.handshake));
    });

    test('records a frame that never decoded', () {
      relay.debugHandleFrame(Uint8List.fromList([0xff, 0x00, 0x00, 0x00]));

      final drop = capture.drops.single;
      expect(drop['dir'], 'rx');
      expect(drop['reason'], 'bad-frame');
      expect((drop['detail']! as Map)['why'], 'badVersion');
    });

    test('stays silent when no capture is armed', () {
      final quiet = RelayService(crypto: CryptoService());
      // The gate is the null hook itself: nothing to assert but that this
      // neither throws nor needs a capture to exist.
      expect(
        () => quiet.sendMessage('m', 'control', _sealedLookingPayload(1)),
        returnsNormally,
      );
      quiet.dispose();
    });
  });

  // The common case needs a socket that is actually open, which RelayService
  // only ever opens itself — hence the loopback server rather than the debug
  // seams above.
  group('RelayService tx over a live socket', () {
    late FakeRelayWsServer server;
    late _Capture capture;
    late RelayService relay;
    late StreamIterator<FakeRelayConnection> connections;

    setUp(() async {
      server = await FakeRelayWsServer.start();
      capture = _Capture();
      relay = RelayService(crypto: CryptoService(), netTap: capture.tap);
      connections = StreamIterator(server.connections);
    });

    tearDown(() async {
      relay.dispose();
      await connections.cancel();
      await server.close();
    });

    test('records an outbound frame with its channel, size and nonce', () async {
      final connect = relay.connect(
        server.wsUrl,
        DeviceIdentity(
          deviceId: 'phone-1#machine-1',
          name: 'Test Phone',
          ed25519PrivateKey: Uint8List(32),
          ed25519PublicKey: Uint8List(32),
          x25519PrivateKey: Uint8List(32),
          x25519PublicKey: Uint8List(32),
        ),
        licenseToken: 'tok',
        epoch: 1,
        machineDeviceId: 'machine-1',
      );
      expect(await connections.moveNext(), isTrue);
      connections.current.sendJson({
        'type': 'welcome',
        'deviceId': 'phone-1#machine-1',
        'epoch': 1,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
      });
      await connect;

      relay.sendMessage('machine-1', 'preview', _sealedLookingPayload(0x5a));

      // By `kind`, not by `dir` alone: the socket's own control json — this
      // connection's `hello`, and the `welcome` answering it — is captured too.
      final tx = capture.frames.singleWhere(
        (e) => e['dir'] == 'tx' && e['kind'] == 'sealed',
      );
      expect(tx['channel'], 'preview');
      expect(tx['frameId'], '5a' * 12);
      expect(tx['bytes'], 22);
      expect(capture.drops, isEmpty);
    });

    test('records the relay control json crossing in both directions', () async {
      final connect = relay.connect(
        server.wsUrl,
        DeviceIdentity(
          deviceId: 'phone-1#machine-1',
          name: 'Test Phone',
          ed25519PrivateKey: Uint8List(32),
          ed25519PublicKey: Uint8List(32),
          x25519PrivateKey: Uint8List(32),
          x25519PublicKey: Uint8List(32),
        ),
        licenseToken: 'tok',
        epoch: 1,
        machineDeviceId: 'machine-1',
      );
      expect(await connections.moveNext(), isTrue);
      connections.current.sendJson({
        'type': 'welcome',
        'deviceId': 'phone-1#machine-1',
        'epoch': 1,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
      });
      await connect;

      final control = capture.frames.where((e) => e['kind'] == 'control');
      // The agent's half records this same class, so a capture missing it shows
      // an idle app beside an agent that saw the socket answer — and an `error`
      // here (MESSAGE_RATE_LIMITED) is the relay saying it threw a frame away,
      // which is the question a capture is usually opened to answer.
      expect(
        control.where((e) => e['dir'] == 'tx').map((e) => e['msgType']),
        contains('hello'),
      );
      final welcome = control.singleWhere((e) => e['dir'] == 'rx');
      expect(welcome['msgType'], 'welcome');
      expect(welcome['bytes'], isPositive);
      expect((welcome['detail']! as Map)['epoch'], 1);
      expect(capture.drops, isEmpty);
    });
  });

  group('MachineSession annotations', () {
    late _Capture capture;
    late FakeLiveRelay relay;
    late SessionKeys keys;
    late MachineSession session;

    setUp(() async {
      capture = _Capture();
      relay = FakeLiveRelay(netTap: capture.tap);
      keys = fixedKeys(1);
      session = MachineSession(
        relay: relay,
        machineDeviceId: 'machine-1',
        handshaker: FakeHandshaker(keys),
      );
      session.start();
      await session.ensureEstablished();
      capture.events.clear(); // establishment traffic is not what is under test
    });

    tearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });

    test('names an outbound frame with the type the wire could not see', () async {
      await session.sendOnStream(
        'proj-1',
        {'type': 'terminal:input', 'data': 'x'},
        'control',
      );

      final sealed = relay.sent.single.payload;
      final note = capture.annotationFor(frameIdOf(sealed, FrameKind.sealed));
      expect(note['msgType'], 'terminal:input');
      expect(note['streamId'], 'proj-1');
    });

    test('records the send dropped for want of an E2E session', () async {
      // A fresh session has installed no keys, so this is the pre-establishment
      // window the app hits on every reconnect.
      final cold = MachineSession(
        relay: relay,
        machineDeviceId: 'machine-1',
        handshaker: FakeHandshaker(keys),
      );
      await cold.sendOnStream('proj-1', {'type': 'file:read'}, 'control');

      final drop = capture.drops.single;
      expect(drop['reason'], 'no-e2e-session');
      expect(drop['msgType'], 'file:read');
      expect(drop['streamId'], 'proj-1');
      await cold.dispose();
    });

    test('names an inbound frame after decrypt, joined by the nonce', () async {
      final payload = await _sealFromAgent(
        keys,
        jsonEncode({
          's': 'proj-1',
          'm': {'type': 'terminal:output', 'data': 'hi'},
        }),
      );
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: payload,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The whole point: the id was readable only before the decrypt, the type
      // only after it, and they meet without either being threaded.
      final note = capture.annotationFor(frameIdOf(payload, FrameKind.sealed));
      expect(note['msgType'], 'terminal:output');
      expect(note['streamId'], 'proj-1');
    });

    test('records an inbound frame that would not decrypt', () async {
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: _sealedLookingPayload(0x01),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final drop = capture.drops.single;
      expect(drop['reason'], 'decrypt-failed');
      expect(drop['frameId'], '01' * 12);
    });

    test('records a frame for a stream nothing is bound to', () async {
      final payload = await _sealFromAgent(
        keys,
        jsonEncode({
          's': 'ghost-stream',
          'm': {'type': 'terminal:output'},
        }),
      );
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: payload,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final drop = capture.drops.single;
      expect(drop['reason'], 'unknown-stream');
      expect(drop['streamId'], 'ghost-stream');
      expect(drop['msgType'], 'terminal:output');
    });
  });
}
