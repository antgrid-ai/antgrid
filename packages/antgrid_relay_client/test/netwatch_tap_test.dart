// Frame-capture coverage for central control frames and native PeerLink annotations.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';
import 'support/fake_relay_ws_server.dart';

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

void main() {
  group('frameIdOf', () {
    test('hashes the frame payload — pinned, not merely well-formed', () {
      // The SAME bytes are hashed by `frameIdFor` in bridge/src/netwatch.ts
      // and asserted against this exact string there — the pair is
      // hand-mirrored, so a silent divergence would otherwise surface only as
      // a `--join` that matches nothing.
      final id = frameIdOf(
        Uint8List.fromList(
          utf8.encode('{"type":"session:hello","attemptId":"a1"}'),
        ),
      );
      expect(id, '1e65322bad672889949c1355');
    });

    test('is stable for identical bytes and differs for different ones', () {
      final a = frameIdOf(Uint8List.fromList([1, 2, 3]));
      final b = frameIdOf(Uint8List.fromList([1, 2, 3]));
      final c = frameIdOf(Uint8List.fromList([1, 2, 4]));
      expect(a, b);
      expect(a, isNot(c));
      expect(a, hasLength(24));
    });
  });

  // RelayService opens its control socket itself — hence the loopback server rather than the debug
  // seams above.
  group('RelayService control capture over a live socket', () {
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

    test(
      'records the relay control json crossing in both directions',
      () async {
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
        expect(
          control.where((e) => e['dir'] == 'tx').map((e) => e['msgType']),
          contains('hello'),
        );
        final welcome = control.singleWhere((e) => e['dir'] == 'rx');
        expect(welcome['msgType'], 'welcome');
        expect(welcome['bytes'], isPositive);
        expect((welcome['detail']! as Map)['epoch'], 1);
        expect(capture.drops, isEmpty);
      },
    );
  });

  group('MachineSession annotations', () {
    late _Capture capture;
    late FakeLiveRelay relay;
    late MachineSession session;

    setUp(() async {
      capture = _Capture();
      relay = FakeLiveRelay(netTap: capture.tap);
      session = await establishSession(relay, handshaker: FakeHandshaker());
      capture.events.clear(); // establishment traffic is not what is under test
    });

    tearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });

    test(
      'names an outbound frame with the type the wire could not see',
      () async {
        await session.sendOnSession({
          'type': 'terminal:input',
          'data': 'x',
        }, 'control');

        final payload = relay.sent.single.payload;
        final note = capture.annotationFor(frameIdOf(payload));
        expect(note['msgType'], 'terminal:input');
        expect(note['streamId'], kControlStreamId);
      },
    );

    test('records the send dropped for want of an E2E session', () async {
      // A fresh session has not yet completed a hello, so this is the
      // pre-establishment window the app hits on every reconnect.
      final cold = MachineSession(
        relay: relay,
        machineDeviceId: 'machine-1',
        handshaker: FakeHandshaker(),
      );
      await cold.sendOnSession({'type': 'file:read'}, 'control');

      final drop = capture.drops.single;
      expect(drop['reason'], 'no-e2e-session');
      expect(drop['msgType'], 'file:read');
      expect(drop['streamId'], kControlStreamId);
      await cold.dispose();
    });

    test('names an inbound frame after decode, joined by the frame id', () async {
      final payload = encodeFromAgent(
        jsonEncode({
          'm': {'type': 'terminal:output', 'data': 'hi'},
        }),
      );
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The whole point: the id is readable before any parsing, the type only
      // after it, and they meet without either being threaded.
      final note = capture.annotationFor(frameIdOf(payload));
      expect(note['msgType'], 'terminal:output');
      expect(note['streamId'], kControlStreamId);
    });

    test('records an inbound frame that is not valid UTF-8', () async {
      // Lone continuation bytes: never a valid UTF-8 sequence on their own.
      final payload = Uint8List.fromList([0x80, 0x80, 0x80]);
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final drop = capture.drops.single;
      expect(drop['reason'], 'bad-utf8');
      expect(drop['frameId'], isNull); // named only once decoded far enough to know a type
    });

    test('a non-control `s` on the session stream is a protocol drop — Stage '
        'A A4 gave every project its own native stream, so no legitimate '
        'peer sends one here any more', () async {
      final payload = encodeFromAgent(
        jsonEncode({
          's': 'ghost-project',
          'm': {'type': 'terminal:output'},
        }),
      );
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final drop = capture.drops.single;
      expect(drop['reason'], 'project-on-session-stream');
      expect(drop['streamId'], 'ghost-project');
    });
  });
}
