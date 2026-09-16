import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:iroh_quic/src/rust/frb_generated.dart' show RustLib;

class _MemoryKeys implements EndpointKeyStore {
  Uint8List? _value;
  @override
  Future<Uint8List?> read(String enrollmentId) async =>
      _value == null ? null : Uint8List.fromList(_value!);
  @override
  Future<void> write(String enrollmentId, Uint8List secret) async {
    _value = Uint8List.fromList(secret);
  }

  @override
  Future<void> delete(String enrollmentId) async {
    _value?.fillRange(0, _value!.length, 0);
    _value = null;
  }
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError('Usage: native_smoke.dart [native-library-path]');
  }
  await iroh.Iroh.init(libraryPath: args.isEmpty ? null : args.single);
  // This executable tests the production record adapter, not account admission.
  final keys = _MemoryKeys();
  final client = await NativeEndpointOwner.create(
    enrollmentId: 'synthetic-smoke',
    keyStore: keys,
    approvedRelays: [],
  );
  final server = await iroh.Endpoint.bindWithAddressLookup(
    resolve: (_) => null,
    relayMode: iroh.RelayMode.disabled,
    alpns: [utf8.encode(peerAlpn)],
  );
  try {
    var addresses = server.addr.ipAddrs;
    if (addresses.isEmpty) {
      addresses =
          (await server
                  .watchAddr()
                  .firstWhere((value) => value.ipAddrs.isNotEmpty)
                  .timeout(const Duration(seconds: 5)))
              .ipAddrs;
    }
    for (final scenario in ['echo', 'oversize', 'extra-stream', 'revoked']) {
      var allowed = true;
      final accepting = server.accept();
      final link = await client
          .dial(
            endpointId: server.id.toHex(),
            localDeviceId: 'app',
            peerDeviceId: 'machine',
            authorized: () => allowed,
            ipAddresses: addresses,
          )
          .timeout(const Duration(seconds: 10));
      final remote = (await accepting)!;
      final stream = remote.acceptBi();
      final incoming = link.messageStream.first;
      incoming.ignore();
      final failure = link.failureStream.first;
      failure.ignore();
      final sent = await link.sendFrame(
        'machine',
        'control',
        Uint8List.fromList([1, 2, 3]),
        kind: FrameKind.handshake,
      );
      if (sent != PeerSendOutcome.accepted)
        throw StateError('native write failed');
      final (send, recv) = await stream;
      final prefix = await recv.readExact(4);
      final size = ByteData.sublistView(prefix).getUint32(0, Endian.big);
      final frame = decodeRouteFrame(await recv.readExact(size));
      if (frame.header['to'] != 'machine') throw StateError('route mismatch');
      if (scenario == 'echo') {
        final response = encodeRouteFrame(
          {'type': 'message', 'to': 'app', 'channel': 'control'},
          frame.payload,
          FrameKind.handshake,
        );
        final length = (ByteData(
          4,
        )..setUint32(0, response.length, Endian.big)).buffer.asUint8List();
        await send.writeAll(Uint8List.sublistView(length, 0, 1));
        await send.writeAll(Uint8List.sublistView(length, 1));
        await send.writeAll(response);
        final message = await incoming.timeout(const Duration(seconds: 5));
        if (message.payload.join(',') != '1,2,3')
          throw StateError('echo mismatch');
      } else if (scenario == 'oversize') {
        await send.writeAll(
          (ByteData(
            4,
          )..setUint32(0, 0xffffffff, Endian.big)).buffer.asUint8List(),
        );
        if ((await failure.timeout(const Duration(seconds: 5))).code !=
            'INVALID_RECORD_LENGTH')
          throw StateError('length accepted');
      } else if (scenario == 'extra-stream') {
        final (extra, _) = await remote.openBi();
        await extra.writeAll(Uint8List.fromList([1]));
        if ((await failure.timeout(const Duration(seconds: 5))).code !=
            'EXTRA_STREAM')
          throw StateError('extra stream accepted');
      } else {
        allowed = false;
        if (await link.sendFrame('machine', 'control', Uint8List(1)) !=
            PeerSendOutcome.closed)
          throw StateError('revoked write admitted');
      }
      await link.close();
      remote.close();
      stdout.writeln(jsonEncode({'scenario': scenario, 'passed': true}));
    }
  } finally {
    await client.close();
    await server.close();
    await keys.delete('synthetic-smoke');
    RustLib.dispose();
  }
}
