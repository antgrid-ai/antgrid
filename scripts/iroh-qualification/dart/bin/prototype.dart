import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:iroh_quic/src/rust/frb_generated.dart' show RustLib;
import 'package:antgrid_iroh_qualification/peer_link.dart';

String uuid() {
  final r = Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

Map<String, dynamic> message(String type, Map<String, dynamic> fields) => {
  'type': type,
  'id': uuid(),
  'timestamp': DateTime.now().millisecondsSinceEpoch,
  ...fields,
};

Future<void> main() async {
  await iroh.Iroh.init();
  final crypto = CryptoService();
  final (seed, public) = await crypto.generateEd25519KeyPair();
  final endpoint = await iroh.Endpoint.bindWithAddressLookup(
    resolve: (_) => null,
    relayMode: iroh.RelayMode.disabled,
  );
  MachineSession? session;
  IrohSessionLink? link;
  try {
    stdout.writeln(
      jsonEncode({
        'endpointId': endpoint.id.toHex(),
        'publicKey': base64Encode(public),
      }),
    );
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final config = jsonDecode(line) as Map<String, dynamic>;
    final expected = iroh.PublicKey.fromHex(config['endpointId'] as String);
    final connection = await endpoint.connect(
      iroh.EndpointAddr(
        expected,
        ipAddrs: (config['addresses'] as List).cast<String>(),
      ),
      utf8.encode('antgrid/peer/1'),
    );
    if (connection.remoteId != expected ||
        utf8.decode(connection.alpn) != 'antgrid/peer/1') {
      throw StateError('AUTHENTICATED_ENDPOINT_MISMATCH');
    }
    final stableId = connection.stableId;
    final (send, recv) = await connection.openBi();
    if (config['testCase'] == 'oversize-record' ||
        config['testCase'] == 'wrong-destination') {
      if (config['testCase'] == 'oversize-record') {
        await send.writeAll([255, 255, 255, 255]);
      } else {
        final raw = encodeRouteFrame(
          {'type': 'message', 'to': 'wrong-machine', 'channel': 'control'},
          Uint8List.fromList(utf8.encode('{}')),
          FrameKind.handshake,
        );
        final prefix = ByteData(4)..setUint32(0, raw.length, Endian.big);
        await send.writeAll([...prefix.buffer.asUint8List(), ...raw]);
      }
      await connection.closed();
      return;
    }
    final activeLink = link = IrohSessionLink(
      connection,
      send,
      recv,
      config['appId'] as String,
      config['machineId'] as String,
    );
    final active = session = MachineSession(
      relay: activeLink,
      machineDeviceId: config['machineId'] as String,
      handshaker: AppSessionHandshaker(
        relay: activeLink,
        crypto: crypto,
        machineDeviceId: config['machineId'] as String,
        phoneDeviceId: config['appId'] as String,
        agentEd25519PubB64: config['machinePublic'] as String,
        phoneEd25519Seed: seed,
        attemptTimeout: const Duration(seconds: 5),
        logger: (level, text, {fields}) => stderr.writeln('handshake: $text'),
      ),
    );
    var establishments = 0;
    final establishedSub = active.established.listen((_) {
      establishments++;
    });
    active.start();
    activeLink.start();
    Future<T> guarded<T>(Future<T> work) => Future.any([
      work,
      activeLink.failure.future.then<T>((_) => throw StateError('LINK_CLOSED')),
    ]);
    if ((config['testCase'] as String).startsWith('client-')) {
      active.ensureEstablished().ignore();
      try {
        await activeLink.failure.future;
        throw StateError('INVALID_PEER_ACCEPTED');
      } on StateError catch (error) {
        final expectedFailure = switch (config['testCase']) {
          'client-oversize-record' => 'INVALID_RECORD_LENGTH',
          'client-wrong-destination' => 'INVALID_ROUTE',
          'client-extra-stream' => 'EXTRA_STREAM',
          _ => throw StateError('UNKNOWN_CASE'),
        };
        if (error.message != expectedFailure) rethrow;
        stdout.writeln(
          jsonEncode({
            'check': 'peer-protocol-rejected',
            'testCase': config['testCase'],
          }),
        );
      }
      await establishedSub.cancel();
      return;
    }
    if (['bad-agent-key', 'bad-app-key'].contains(config['testCase'])) {
      try {
        await guarded(active.ensureEstablished());
        throw StateError('INVALID_IDENTITY_ESTABLISHED');
      } on HandshakeException {
        stdout.writeln(
          jsonEncode({
            'check': 'identity-rejected',
            'testCase': config['testCase'],
          }),
        );
      }
      await establishedSub.cancel();
      return;
    }
    await guarded(active.ensureEstablished());
    stderr.writeln('prototype: E2E established');
    if (config['testCase'] == 'extra-stream') {
      final (extra, _) = await connection.openBi();
      await extra.writeAll([1]);
      await connection.closed();
      await establishedSub.cancel();
      return;
    }
    if (config['testCase'] == 'disconnect') {
      try {
        await active.streamFor('0').request('qualification.drop');
        throw StateError('LOST_RPC_SUCCEEDED');
      } on RpcException catch (error) {
        if (error.code != 'E_SESSION_DOWN' || active.isEstablished) rethrow;
        stdout.writeln(
          jsonEncode({'check': 'pending-failed', 'code': error.code}),
        );
      }
      await establishedSub.cancel();
      return;
    }
    final streams = <String, String>{};
    for (final projectId in ['prototype-a', 'prototype-b']) {
      streams[projectId] = await guarded(
        active.bindProject(
          projectId,
          message('project:start', {'projectId': projectId}),
        ),
      );
      stderr.writeln('prototype: bound $projectId');
    }
    Future<void> terminal(String projectId, bool second) async {
      final transport = active.streamFor(streams[projectId]!);
      final done = Completer<void>();
      final expectedOutput = second ? '17993' : '27047';
      final sub = transport.messages.listen((event) {
        final frame = event.json;
        if (frame['type'] != 'terminal:frame') return;
        if (frame['terminalId'] != projectId) {
          if (!done.isCompleted)
            done.completeError(StateError('CROSS_PROJECT_FRAME'));
          return;
        }
        unawaited(
          transport.send(
            message('terminal:ack', {
              'terminalId': projectId,
              'runId': frame['runId'],
              'attachmentId': frame['attachmentId'],
              'sequence': frame['sequence'],
            }),
          ),
        );
        if ((frame['ansi'] as String).contains(expectedOutput) &&
            !done.isCompleted)
          done.complete();
      });
      try {
        await transport.send(
          message('terminal:subscribe', {
            'terminalId': projectId,
            'version': config['terminalVersion'],
            'requestId': uuid(),
          }),
        );
        final expression = second ? '947*19' : '731*37';
        final input = config['windows'] == true
            ? 'set /a $expression\r'
            : 'echo \$(($expression))\n';
        await transport.send(
          message('terminal:input', {'terminalId': projectId, 'data': input}),
        );
        await guarded(done.future.timeout(const Duration(seconds: 10)));
      } finally {
        await sub.cancel();
      }
    }

    await terminal('prototype-a', false);
    stderr.writeln('prototype: terminal a passed');
    await terminal('prototype-b', false);
    stderr.writeln('prototype: terminal b passed');
    final rebound = await active.bindProject(
      'prototype-a',
      message('project:start', {'projectId': 'prototype-a'}),
    );
    if (rebound != streams['prototype-a']) throw StateError('PROJECT_REDIALED');
    final rekeyed = active.established.first;
    for (var i = 0; i < 3; i++) {
      active.notifyRpcResult(timedOut: true);
    }
    await guarded(rekeyed.timeout(const Duration(seconds: 10)));
    stderr.writeln('prototype: rekeyed');
    await terminal('prototype-a', true);
    stdout.writeln(
      jsonEncode({
        'check': 'encrypted-terminal-pass',
        'establishments': establishments,
        'projects': streams.length,
        'sameConnection': stableId == connection.stableId,
      }),
    );
    await establishedSub.cancel();
  } finally {
    await session?.dispose();
    await link?.dispose();
    seed.fillRange(0, seed.length, 0);
    await endpoint.close();
    RustLib.dispose();
  }
}
