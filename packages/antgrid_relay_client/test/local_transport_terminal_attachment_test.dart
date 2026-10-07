// LocalTransport's `openTerminalAttachment` is entirely inherited from
// `BufferedAgentTransport` (the socket path: loopback is unchanged on the
// wire) — this pins that the subscribe still goes out over the same socket
// and that a diverted reply never reaches the ordinary `messages` stream.
// Server fixture modeled on `local_transport_connect_test.dart`'s
// `_HelloRecorder`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

/// A loopback stand-in for the agent's local WS listener: completes the
/// handshake, refuses `state.snapshot` so `connect()` returns promptly, and
/// records every subsequent inbound frame while allowing the test to push
/// frames down to the client on demand.
class _EchoServer {
  late final HttpServer _server;
  late final WebSocket _ws;
  final hello = Completer<Map<String, dynamic>>();
  final _wsReady = Completer<void>();
  final received = <Map<String, dynamic>>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      _server
          .listen((req) async {
            final ws = await WebSocketTransformer.upgrade(req);
            _ws = ws;
            if (!_wsReady.isCompleted) _wsReady.complete();
            ws.listen((data) {
              final m = jsonDecode(data as String) as Map<String, dynamic>;
              switch (m['type']) {
                case 'hello':
                  if (!hello.isCompleted) hello.complete(m);
                  ws.add(jsonEncode({'type': 'ready'}));
                case 'request':
                  ws.add(
                    jsonEncode({
                      'type': 'response',
                      'requestId': m['requestId'],
                      'ok': false,
                      'error': {
                        'code': 'E_UNSUPPORTED',
                        'message': 'no snapshot',
                      },
                    }),
                  );
                default:
                  received.add(m);
              }
            });
          })
          .asFuture<void>()
          .catchError((Object _) {}),
    );
  }

  /// Pushes a `{channel, ...message}` frame to the client, exactly as the
  /// agent's `LocalListener` would.
  Future<void> push(Map<String, dynamic> message, {String channel = 'control'}) async {
    await _wsReady.future;
    _ws.add(jsonEncode({'channel': channel, ...message}));
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _EchoServer server;
  late LocalTransport transport;

  setUp(() async {
    server = _EchoServer();
    await server.start();
    transport = LocalTransport(port: server.port, token: 't', appPid: 1);
    await transport.connect();
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  test(
    'LocalTransport.openTerminalAttachment sends the subscribe over the '
    'socket unchanged and diverts that attachment\'s replies away from '
    'messages',
    () async {
      final generalMessages = <Map<String, dynamic>>[];
      transport.messages.listen((m) => generalMessages.add(m.json));

      final subscribe = {
        'type': 'terminal:subscribe',
        'requestId': 'r1',
        'checkoutId': 'main',
      };
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: subscribe,
      );
      expect(attachment.isStream, isFalse);

      await pumpEventQueue();
      expect(
        server.received.any(
          (m) =>
              m['type'] == 'terminal:subscribe' &&
              m['requestId'] == 'r1' &&
              m['checkoutId'] == 'main',
        ),
        isTrue,
        reason: 'the subscribe must reach the socket exactly as given',
      );

      final attachmentMsgs = <Map<String, dynamic>>[];
      attachment.messages.listen(attachmentMsgs.add);
      await server.push({
        'type': 'terminal:subscribed',
        'requestId': 'r1',
        'attachmentId': 'att-1',
      });
      await server.push({
        'type': 'terminal:frame',
        'attachmentId': 'att-1',
        'seq': 1,
      });

      await pumpEventQueue();
      expect(attachmentMsgs.map((m) => m['type']), [
        'terminal:subscribed',
        'terminal:frame',
      ]);
      expect(
        generalMessages,
        isEmpty,
        reason: 'a diverted reply must never reach the ordinary stream',
      );
    },
  );

  test('unmatched terminal messages still reach messages', () async {
    final generalMessages = <Map<String, dynamic>>[];
    transport.messages.listen((m) => generalMessages.add(m.json));

    // No attachment was ever opened for this requestId, so nothing claims it.
    await server.push({
      'type': 'terminal:display:status',
      'requestId': 'unknown-request',
      'status': 'UNKNOWN_TERMINAL',
    });

    await pumpEventQueue();
    expect(generalMessages, hasLength(1));
    expect(generalMessages.single['type'], 'terminal:display:status');
  });
}

Future<void> pumpEventQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
