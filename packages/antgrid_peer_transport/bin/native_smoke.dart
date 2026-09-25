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

/// The session stream's first record must be `{kind:"session"}` per A1; every
/// other read on it stays exactly as it was before the open frame existed.
Future<void> _expectSessionOpen(iroh.RecvStream recv) async {
  final prefix = await recv.readExact(4);
  final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
  final body = jsonDecode(utf8.decode(await recv.readExact(length)));
  if (body is! Map<String, dynamic> ||
      StreamOpen.fromJson(body) is! SessionStreamOpen) {
    throw StateError('session open frame missing');
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
    for (final scenario in [
      'echo',
      'oversize',
      'refused-stream',
      'extra-uni-stream',
      'revoked',
    ]) {
      var allowed = true;
      final accepting = server.accept();
      final link = await client
          .dial(
            endpointId: server.id.toHex(),
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
        kPeerFrameMessage,
        Uint8List.fromList([1, 2, 3]),
      );
      if (sent != PeerSendOutcome.accepted)
        throw StateError('native write failed');
      final (send, recv) = await stream;
      await _expectSessionOpen(recv);
      final prefix = await recv.readExact(4);
      final size = ByteData.sublistView(prefix).getUint32(0, Endian.big);
      final frame = decodePeerFrame(await recv.readExact(size));
      if (frame.header['type'] != kPeerFrameMessage) {
        throw StateError('peer frame mismatch');
      }
      if (scenario == 'echo') {
        final response = encodePeerFrame(
          {'type': kPeerFrameMessage},
          frame.payload,
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
      } else if (scenario == 'refused-stream') {
        final probe = await link.openStream(
          const ProjectStreamOpen('smoke'),
          maxRecordBytes: kStreamOpenMaxBytes,
          maxQueuedBytes: 2 * kStreamOpenMaxBytes,
        );
        final (probeSend, probeRecv) = await remote.acceptBi();
        final openPrefix = await probeRecv.readExact(4);
        final openLength = ByteData.sublistView(
          openPrefix,
        ).getUint32(0, Endian.big);
        final openJson = jsonDecode(
          utf8.decode(await probeRecv.readExact(openLength)),
        );
        if (openJson is! Map<String, dynamic> ||
            StreamOpen.fromJson(openJson) != const ProjectStreamOpen('smoke'))
          throw StateError('project open frame mismatch');
        final refusalBytes = utf8.encode(
          jsonEncode(
            const StreamRefused(
              code: StreamRefusedCode.invalid,
              message: 'smoke',
            ).toJson(),
          ),
        );
        final refusalPrefix = (ByteData(
          4,
        )..setUint32(0, refusalBytes.length, Endian.big)).buffer.asUint8List();
        await probeSend.writeAll(refusalPrefix);
        await probeSend.writeAll(refusalBytes);
        await probeSend.finish();
        final probeRecords = await probe.records.toList().timeout(
          const Duration(seconds: 5),
        );
        if (probeRecords.length != 1)
          throw StateError('expected exactly one refusal record');
        final refused = StreamRefused.tryDecode(probeRecords.single);
        if (refused?.code != StreamRefusedCode.invalid)
          throw StateError('stream refusal decode mismatch');
        await probe.reset();

        // The refusal must cost only the probe stream: the session stream
        // still carries a full round trip, and no failure fires from it.
        final response = encodePeerFrame(
          {'type': kPeerFrameMessage},
          frame.payload,
        );
        final length = (ByteData(
          4,
        )..setUint32(0, response.length, Endian.big)).buffer.asUint8List();
        await send.writeAll(length);
        await send.writeAll(response);
        final message = await incoming.timeout(const Duration(seconds: 5));
        if (message.payload.join(',') != '1,2,3')
          throw StateError('echo mismatch after stream refusal');
        final noFailure = await Future.any([
          failure.then((_) => false),
          Future<bool>.delayed(const Duration(milliseconds: 200), () => true),
        ]);
        if (!noFailure)
          throw StateError('link failed after an in-band stream refusal');
      } else if (scenario == 'extra-uni-stream') {
        final extra = await remote.openUni();
        await extra.writeAll(Uint8List.fromList([1]));
        if ((await failure.timeout(const Duration(seconds: 5))).code !=
            'EXTRA_STREAM')
          throw StateError('extra uni stream accepted');
      } else {
        allowed = false;
        if (await link.sendFrame(kPeerFrameMessage, Uint8List(1)) !=
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
