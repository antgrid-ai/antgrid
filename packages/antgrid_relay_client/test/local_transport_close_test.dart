// Coverage for LocalTransport's post-ready close handling: a socket closed
// after the handshake must fail fast (state + in-flight RPCs) rather than
// leave callers to burn their own timeouts against a dead channel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

const _token = 'loopback-shared-secret-9f3a';

/// A scriptable stand-in for the agent's `LocalListener`. Self-contained copy
/// (test files here don't share fakes — see `local_transport_netwatch_test.dart`),
/// extended with the ability to withhold a `request` reply so a test can close
/// the socket while an RPC is still in flight.
class _FakeAgent {
  _FakeAgent._(this._server, this.port);

  final HttpServer _server;
  final int port;
  WebSocket? socket;

  String? helloReply = '{"type":"ready"}';
  int closeCode = 4401;

  /// When true, `request` frames are received but never answered.
  bool holdRequests = false;

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
        if (text.contains('"request"')) {
          if (agent.holdRequests) return;
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

void main() {
  late _FakeAgent agent;
  setUp(() async => agent = await _FakeAgent.start());
  tearDown(() => agent.stop());

  test('4409 after ready: error state, lastCloseCode, pending RPC fails fast', () async {
    final t = LocalTransport(port: agent.port, token: _token, appPid: 1);
    addTearDown(t.dispose);
    await t.connect();
    expect(t.currentState, TransportState.connected);

    // Hold the next request's reply so it is still in flight when the socket
    // closes, then assert it fails well inside its own timeout.
    agent.holdRequests = true;
    final pendingRequest = t.request(
      'config.read',
      timeout: const Duration(seconds: 5),
    );
    // Attach the failure expectation before the close, synchronously — a
    // Future's error is only "handled" by a listener registered before it
    // completes; attaching after the fact (post-delay) races an unhandled
    // async error.
    final rejects = expectLater(
      pendingRequest,
      throwsA(
        isA<RpcException>().having((e) => e.code, 'code', 'E_SUPERSEDED'),
      ),
    );

    await agent.socket!.close(4409, 'owner superseded');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(t.currentState, TransportState.error);
    expect(t.lastCloseCode, 4409);
    await rejects;

    // A later send() must not throw — the fail-fast is delivered through
    // state + failAllPending, never through send()'s own contract.
    await t.send({'id': 'm-1', 'type': 'terminal:input'});
  });

  test('a send after a post-ready close records a no-channel drop', () async {
    final events = <Map<String, Object?>>[];
    final t = LocalTransport(
      port: agent.port,
      token: _token,
      appPid: 1,
      netTap: events.add,
    );
    addTearDown(t.dispose);
    await t.connect();

    await agent.socket!.close(4409, 'owner superseded');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    events.clear();

    await t.send({'id': 'm-2', 'type': 'terminal:input'}, channel: 'heavy');

    final drop = events.singleWhere((e) => e['kind'] == 'drop');
    expect(drop['reason'], 'no-channel');
    expect(drop['dir'], 'tx');
    expect(drop['frameId'], 'm-2');
  });

  test('a clean close (1000) after ready: disconnected + E_SOCKET_CLOSED', () async {
    final t = LocalTransport(port: agent.port, token: _token, appPid: 1);
    addTearDown(t.dispose);
    await t.connect();

    agent.holdRequests = true;
    final pendingRequest = t.request(
      'config.read',
      timeout: const Duration(seconds: 5),
    );
    final rejects = expectLater(
      pendingRequest,
      throwsA(
        isA<RpcException>().having((e) => e.code, 'code', 'E_SOCKET_CLOSED'),
      ),
    );

    await agent.socket!.close(1000, 'normal');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(t.currentState, TransportState.disconnected);
    expect(t.lastCloseCode, 1000);
    await rejects;
  });

  test('4409 before ready still throws LocalTransportHandshakeException', () async {
    agent.helloReply = null;
    agent.closeCode = 4409;
    final t = LocalTransport(port: agent.port, token: _token, appPid: 1);
    addTearDown(t.dispose);
    await expectLater(
      t.connect(),
      throwsA(
        isA<LocalTransportHandshakeException>().having(
          (e) => e.closeCode,
          'closeCode',
          4409,
        ),
      ),
    );
  });
}
