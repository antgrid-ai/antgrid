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
    late List<Map<String, Object?>?> warns;

    setUp(() async {
      capture = _Capture();
      relay = FakeLiveRelay(netTap: capture.tap);
      warns = [];
      session = await establishSession(
        relay,
        handshaker: FakeHandshaker(),
        // Short enough that a test can cross the window without idling out the
        // shipped 30s.
        unknownStreamLogInterval: const Duration(milliseconds: 500),
        logger: (level, message, {fields}) {
          if (message == 'dropping inbound frame for unknown stream') {
            warns.add(fields);
          }
        },
      );
      capture.events.clear(); // establishment traffic is not what is under test
    });

    tearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });

    test(
      'names an outbound frame with the type the wire could not see',
      () async {
        await session.sendOnStream('proj-1', {
          'type': 'terminal:input',
          'data': 'x',
        }, 'control');

        final payload = relay.sent.single.payload;
        final note = capture.annotationFor(frameIdOf(payload));
        expect(note['msgType'], 'terminal:input');
        expect(note['streamId'], 'proj-1');
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
      await cold.sendOnStream('proj-1', {'type': 'file:read'}, 'control');

      final drop = capture.drops.single;
      expect(drop['reason'], 'no-e2e-session');
      expect(drop['msgType'], 'file:read');
      expect(drop['streamId'], 'proj-1');
      await cold.dispose();
    });

    test('names an inbound frame after decode, joined by the frame id', () async {
      final payload = encodeFromAgent(
        jsonEncode({
          's': 'proj-1',
          'm': {'type': 'terminal:output', 'data': 'hi'},
        }),
      );
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The whole point: the id is readable before any parsing, the type only
      // after it, and they meet without either being threaded.
      final note = capture.annotationFor(frameIdOf(payload));
      expect(note['msgType'], 'terminal:output');
      expect(note['streamId'], 'proj-1');
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

    test('records a frame for a stream nothing is bound to', () async {
      final payload = encodeFromAgent(
        jsonEncode({
          's': 'ghost-stream',
          'm': {'type': 'terminal:output'},
        }),
      );
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final drop = capture.drops.single;
      expect(drop['reason'], 'unknown-stream');
      expect(drop['streamId'], 'ghost-stream');
      expect(drop['msgType'], 'terminal:output');
    });

    test('a drop storm on one stream throttles the log, never the tap', () async {
      // Nothing heals an agent pushing onto an id this app holds no transport
      // for, so a live PTY on a stale stream drops one frame per frame with no
      // end. A capture is bounded by how long it runs; app.log is not.
      Future<void> injectGhost() async {
        final payload = encodeFromAgent(
          jsonEncode({
            's': 'ghost-stream',
            'm': {'type': 'terminal:output'},
          }),
        );
        relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      await injectGhost();
      await injectGhost();
      await injectGhost();

      expect(capture.drops, hasLength(3));
      expect(warns, hasLength(1));
      expect(warns.single!['streamId'], 'ghost-stream');
      expect(warns.single!['msgType'], 'terminal:output');
      expect(warns.single!['framesDropped'], 1);

      // The two the throttle swallowed are not lost to the reader — they land on
      // the next line. This is the assertion that matters: `framesDropped` is
      // the ONLY thing carrying magnitude once the throttle is on, so summing
      // lines instead of this field understates the loss by orders of magnitude.
      await Future<void>.delayed(const Duration(milliseconds: 550));
      await injectGhost();

      expect(capture.drops, hasLength(4));
      expect(warns, hasLength(2));
      expect(warns.last!['framesDropped'], 3);
    });
  });
}
