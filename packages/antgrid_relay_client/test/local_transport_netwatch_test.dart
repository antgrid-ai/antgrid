// Frame-capture coverage for the loopback transport.
//
// The bridge's `LocalListener` is the far end of this very socket, so it
// already records every frame that crossed it — see `LocalTransport._dropped`.
// What it cannot see is a frame this app never put on the wire, and a handshake
// it refused (from here that is a bare close code). Those are what this file
// pins, plus the one thing no drop may ever carry: the token.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

const _token = 'loopback-shared-secret-9f3a';

/// A scriptable stand-in for the agent's `LocalListener`.
class _FakeAgent {
  _FakeAgent._(this._server, this.port);

  final HttpServer _server;
  final int port;
  WebSocket? socket;

  /// What to answer the hello with. `null` = close with [closeCode] instead,
  /// which is how the real listener refuses one.
  String? helloReply = '{"type":"ready"}';
  int closeCode = 4401;

  static Future<_FakeAgent> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final agent = _FakeAgent._(server, server.port);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      agent.socket = ws;
      ws.listen((data) {
        final text = data as String;
        if (text.contains('"hello"')) {
          final reply = agent.helloReply;
          if (reply == null) {
            ws.close(agent.closeCode, 'refused');
          } else {
            ws.add(reply);
          }
          return;
        }
        // Answer `request` frames, so `connect()`'s `state.snapshot` returns at
        // once instead of burning its 5s timeout in every test that gets past
        // the hello.
        if (text.contains('"request"')) {
          final id = (jsonDecode(text) as Map)['requestId'];
          ws.add(
            jsonEncode({
              'channel': 'control',
              'type': 'response',
              'requestId': id,
              'ok': true,
              'result': {'frames': []},
            }),
          );
        }
      });
    });
    return agent;
  }

  Future<void> stop() async {
    await socket?.close();
    await _server.close(force: true);
  }
}

/// Collects tap events, standing in for `app/lib/util/netwatch.dart`.
class _Capture {
  final events = <Map<String, Object?>>[];
  RelayNetTap get tap => events.add;

  Iterable<Map<String, Object?>> get drops =>
      events.where((e) => e['kind'] == 'drop');

  Map<String, Object?> only(String reason) =>
      drops.singleWhere((e) => e['reason'] == reason);
}

Future<_Capture> _connectExpectingFailure(_FakeAgent agent) async {
  final cap = _Capture();
  final t = LocalTransport(
    port: agent.port,
    token: _token,
    appPid: 1,
    netTap: cap.tap,
  );
  addTearDown(t.dispose);
  await expectLater(t.connect(), throwsA(isA<Object>()));
  return cap;
}

void main() {
  late _FakeAgent agent;
  setUp(() async => agent = await _FakeAgent.start());
  tearDown(() => agent.stop());

  group('handshake', () {
    test(
      'a refused hello records the close code, the only thing we see',
      () async {
        // The listener's own half records WHY it refused (`recordHelloRefused`);
        // this is the other half of that answer, and on its own it is what tells
        // a reader "won't connect" rather than "no traffic".
        agent.helloReply = null;
        agent.closeCode = 4401;
        final cap = await _connectExpectingFailure(agent);

        final drop = cap.only('handshake-closed');
        expect(drop['dir'], 'rx');
        expect(drop['transport'], 'local');
        expect(drop['msgType'], 'hello');
        expect((drop['detail'] as Map)['closeCode'], 4401);
      },
    );

    test('a superseding owner is legible as its own close code', () async {
      agent.helloReply = null;
      agent.closeCode = 4409;
      final cap = await _connectExpectingFailure(agent);
      expect(
        (cap.only('handshake-closed')['detail'] as Map)['closeCode'],
        4409,
      );
    });

    test(
      'a reply that is not `ready` records its type and nothing else',
      () async {
        agent.helloReply = '{"type":"nope","note":"$_token"}';
        final cap = await _connectExpectingFailure(agent);

        final drop = cap.only('handshake-not-ready');
        expect(drop['msgType'], 'hello');
        expect(drop['detail'], {'replyType': 'nope'});
      },
    );

    test(
      'an undecodable reply records the error TYPE, never the text',
      () async {
        agent.helloReply = 'not json at all';
        final cap = await _connectExpectingFailure(agent);

        final detail = cap.only('handshake-unparseable')['detail'] as Map;
        expect(detail['error'], 'FormatException');
        expect('$detail', isNot(contains('not json')));
      },
    );

    test('a port that accepts but never upgrades is not silence', () async {
      // No bridge-side counterpart exists for this one: the listener never sees
      // a connection, so without this row the capture just stops.
      final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      raw.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await raw.close();
      });

      final cap = _Capture();
      final t = LocalTransport(
        port: raw.port,
        token: _token,
        appPid: 1,
        connectTimeout: const Duration(milliseconds: 120),
        netTap: cap.tap,
      );
      addTearDown(t.dispose);
      await expectLater(
        t.connect(),
        throwsA(isA<LocalTransportHandshakeException>()),
      );

      final drop = cap.only('connect-timeout');
      expect(drop['dir'], 'tx');
      expect((drop['detail'] as Map)['attempts'], 2);
    });
  });

  group('data plane', () {
    test('a frame we threw away is recorded; delivered ones are not', () async {
      final cap = _Capture();
      final t = LocalTransport(
        port: agent.port,
        token: _token,
        appPid: 1,
        netTap: cap.tap,
      );
      addTearDown(t.dispose);
      await t.connect();

      // A frame that WORKS. The bridge already recorded it; recording it again
      // here would double it in a merged capture, so this side stays silent.
      final delivered = t.messages.first;
      agent.socket!.add(
        jsonEncode({'channel': 'control', 'type': 'agent:status'}),
      );
      expect((await delivered).json['type'], 'agent:status');

      agent.socket!.add('}{ not a frame');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(cap.events.map((e) => e['reason']), ['unparseable']);
      final drop = cap.only('unparseable');
      expect(drop['dir'], 'rx');
      expect(drop['bytes'], '}{ not a frame'.length);
      expect((drop['detail'] as Map)['error'], isNot(contains('not a frame')));
    });

    test('a send with no channel names the message it lost', () async {
      // Reachable in production: a failed handshake nulls the channel, and the
      // callers that were mid-flight go on sending into it. The `?.` here used
      // to swallow this outright, leaving a caller awaiting a reply to a
      // message that never existed on any wire.
      final cap = _Capture();
      final t = LocalTransport(
        port: agent.port,
        token: _token,
        appPid: 1,
        netTap: cap.tap,
      );
      await t.send({'id': 'm-42', 'type': 'terminal:input'}, channel: 'heavy');

      final drop = cap.only('no-channel');
      expect(drop['dir'], 'tx');
      expect(drop['channel'], 'heavy');
      expect(drop['msgType'], 'terminal:input');
      // The join key: loopback frames carry the whole message, so the id IS the
      // frame id on both ends — no nonce and no hashing on the hot path.
      expect(drop['frameId'], 'm-42');
    });

    test('a send into a closed sink is recorded, not swallowed', () async {
      final cap = _Capture();
      final t = LocalTransport(
        port: agent.port,
        token: _token,
        appPid: 1,
        netTap: cap.tap,
      );
      await t.connect();
      await t.dispose();
      cap.events.clear();

      await t.send({'id': 'm-7', 'type': 'file:read'});
      final drop = cap.only('send-failed');
      expect(drop['msgType'], 'file:read');
      expect(drop['frameId'], 'm-7');
    });
  });

  test(
    'no path records the token, on a refused hello or an accepted one',
    () async {
      // The hello carries the core's shared token and an ACCEPTED one carries a
      // valid one, so this holds for the success path too — not only the refusal.
      agent.helloReply = null;
      final refused = await _connectExpectingFailure(agent);

      agent.helloReply = '{"type":"ready"}';
      final cap = _Capture();
      final t = LocalTransport(
        port: agent.port,
        token: _token,
        appPid: 1,
        netTap: cap.tap,
      );
      addTearDown(t.dispose);
      await t.connect();
      agent.socket!.add('garbage');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Non-vacuous: something WAS captured on both runs.
      expect(refused.drops, isNotEmpty);
      expect(cap.drops, isNotEmpty);
      expect(jsonEncode(refused.events), isNot(contains(_token)));
      expect(jsonEncode(cap.events), isNot(contains(_token)));
    },
  );
}
