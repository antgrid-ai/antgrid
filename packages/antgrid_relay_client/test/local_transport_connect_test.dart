import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

/// A loopback stand-in for the agent's local WS listener: completes the
/// handshake, records the hello, and refuses the post-ready `state.snapshot`
/// so [LocalTransport.connect] returns without waiting out its RPC budget.
class _HelloRecorder {
  late final HttpServer _server;
  final hello = Completer<Map<String, dynamic>>();

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      _server
          .listen((req) async {
            final ws = await WebSocketTransformer.upgrade(req);
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
              }
            });
          })
          .asFuture<void>()
          .catchError((Object _) {}),
    );
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  test(
    'connect() times out when the port accepts but never upgrades the WS',
    () async {
      // A bare TCP server that accepts the socket and then does nothing — it never
      // completes the WebSocket upgrade. Models a wedged-but-listening data plane.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      server.listen(
        accepted.add,
      ); // hold the socket open; send no upgrade response
      addTearDown(() async {
        for (final s in accepted) {
          s.destroy();
        }
        await server.close();
      });

      final t = LocalTransport(
        port: server.port,
        token: 't',
        appPid: 1,
        connectTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(
        t.dispose,
      ); // idempotent: connect() already disposed on failure

      await expectLater(
        t.connect(),
        throwsA(
          isA<LocalTransportHandshakeException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );

      // A failed connect must tear the transport down — not leave _outbound /
      // _stateController open. A closed broadcast controller hands a fresh
      // listener an immediate onDone, so emitsDone proves it was closed.
      await expectLater(t.stateChanges, emitsDone);
      await expectLater(t.messages, emitsDone);
    },
  );

  group('hello capabilities', () {
    Future<Map<String, dynamic>> helloFrom({
      Map<String, Object?>? capabilities,
    }) async {
      final agent = _HelloRecorder();
      await agent.start();
      addTearDown(agent.close);
      final t = LocalTransport(
        port: agent.port,
        token: 't',
        appPid: 1,
        capabilities: capabilities ?? const {'checkoutRouting': true},
      );
      addTearDown(t.dispose);
      await t.connect();
      return agent.hello.future;
    }

    test('sends the default map when the caller names none', () async {
      final hello = await helloFrom();
      expect(hello['capabilities'], {'checkoutRouting': true});
    });

    test('sends a caller-supplied map verbatim', () async {
      // Verbatim is the contract: the agent gates on individual flags, and a
      // client that filtered to flags it recognized could never announce one
      // added after it shipped.
      final hello = await helloFrom(
        capabilities: const {
          'checkoutRouting': true,
          'sessionBusCarrier': true,
          'somethingNewerThanThisClient': 'yes',
        },
      );
      expect(hello['capabilities'], {
        'checkoutRouting': true,
        'sessionBusCarrier': true,
        'somethingNewerThanThisClient': 'yes',
      });
    });
  });
}
