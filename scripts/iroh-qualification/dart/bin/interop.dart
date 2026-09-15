import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:iroh_quic/iroh_quic.dart';
import 'package:iroh_quic/src/rust/frb_generated.dart' show RustLib;

Future<void> main() async {
  await Iroh.init();
  final alpn = utf8.encode('antgrid/peer/1');
  final endpoint = await Endpoint.bindWithAddressLookup(
    resolve: (_) => null,
    relayMode: RelayMode.disabled,
  );
  Connection? connection;
  try {
    stdout.writeln(jsonEncode({'endpointId': endpoint.id.toHex()}));
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final peer = jsonDecode(line) as Map<String, dynamic>;
    final expectedId = PublicKey.fromHex(peer['endpointId'] as String);
    stderr.writeln('Dart: connecting to ${peer['addresses']}');
    connection = await endpoint.connect(
      EndpointAddr(
        expectedId,
        ipAddrs: (peer['addresses'] as List).cast<String>(),
      ),
      alpn,
    );
    if (connection.remoteId != expectedId ||
        utf8.decode(connection.alpn) != 'antgrid/peer/1') {
      throw StateError('Authenticated peer or ALPN mismatch');
    }
    final (send, recv) = await connection.openBi();
    stderr.writeln('Dart: stream opened');
    final prefix = ByteData(4)..setUint32(0, 4096, Endian.big);
    final payload = Uint8List.fromList(List.generate(4096, (i) => i % 251));
    // Split the length prefix to exercise a byte stream rather than record reads.
    await send.writeAll(prefix.buffer.asUint8List(0, 1));
    await send.writeAll(prefix.buffer.asUint8List(1, 3));
    await send.writeAll(payload);
    final responsePrefix = await recv.readExact(4);
    stderr.writeln('Dart: echo prefix received');
    final length = ByteData.sublistView(
      responsePrefix,
    ).getUint32(0, Endian.big);
    if (length != payload.length) throw StateError('Unexpected record length');
    final response = await recv.readExact(length);
    stderr.writeln('Dart: echo payload received');
    for (var i = 0; i < length; i++) {
      if (response[i] != payload[i]) throw StateError('Echo mismatch at $i');
    }
    await send.finish();
    stdout.writeln(jsonEncode({'check': 'echo-pass'}));
  } finally {
    stderr.writeln('Dart: closing');
    connection?.close();
    await endpoint.close();
    RustLib.dispose();
    stderr.writeln('Dart: closed');
  }
}
