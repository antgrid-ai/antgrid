import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  test('connect() times out when the port accepts but never upgrades the WS',
      () async {
    // A bare TCP server that accepts the socket and then does nothing — it never
    // completes the WebSocket upgrade. Models a wedged-but-listening data plane.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    server.listen(accepted.add); // hold the socket open; send no upgrade response
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
    addTearDown(t.dispose); // idempotent: connect() already disposed on failure

    await expectLater(
      t.connect(),
      throwsA(isA<LocalTransportHandshakeException>()
          .having((e) => e.message, 'message', contains('timed out'))),
    );

    // A failed connect must tear the transport down — not leave _outbound /
    // _stateController open. A closed broadcast controller hands a fresh
    // listener an immediate onDone, so emitsDone proves it was closed.
    await expectLater(t.stateChanges, emitsDone);
    await expectLater(t.messages, emitsDone);
  });
}
