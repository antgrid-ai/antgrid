import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value! as Map);

String _toHex(Uint8List value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

// The app only encodes stream-open frames, so the vectors build each
// [StreamOpen] by hand and pin the wire shape through `toJson()`.
StreamOpen _openFrom(Map<String, dynamic> json) {
  switch (json['kind']) {
    case 'session':
      return const SessionStreamOpen();
    case 'project':
      return ProjectStreamOpen(json['projectId'] as String);
    case 'terminal':
      return TerminalStreamOpen(
        projectId: json['projectId'] as String,
        requestId: json['requestId'] as String,
        checkoutId: json['checkoutId'] as String?,
      );
    case 'tunnel-http':
      return TunnelHttpStreamOpen(
        projectId: json['projectId'] as String,
        requestId: json['requestId'] as String,
      );
    case 'tunnel-ws':
      return TunnelWsStreamOpen(
        projectId: json['projectId'] as String,
        wsId: json['wsId'] as String,
      );
    case 'upload':
      return UploadStreamOpen(
        projectId: json['projectId'] as String,
        requestId: json['requestId'] as String,
        fileName: json['fileName'] as String,
        size: json['size'] as int,
        checkoutId: json['checkoutId'] as String?,
        mimeType: json['mimeType'] as String?,
      );
    default:
      throw StateError('unknown stream-open kind ${json['kind']}');
  }
}

void main() {
  final fixture = _map(
    jsonDecode(
      File(
        '../../evals/fixtures/peer-transport-vectors.json',
      ).readAsStringSync(),
    ),
  );

  test('Dart native constants match the shared transport vector', () {
    final native = _map(fixture['native']);
    expect(peerAlpn, native['alpn']);
    expect(maxPeerLeaseMs, native['leaseMs']);
    expect(maxPeerLeaseMs ~/ 3, native['refreshMs']);
    expect(native['selectionMs'], 5000);
    expect(native['endpointChallengeMs'], 120000);
  });

  test(
    'Dart session-record caps and types match the shared transport vector',
    () {
      final sessionRecords = _map(fixture['sessionRecords']);
      expect(kPeerMaxRecordBytes, sessionRecords['maxAppRecordBytes']);
      expect(kPeerMaxBridgeRecordBytes, sessionRecords['maxBridgeRecordBytes']);
      expect(kPeerMaxBridgeRecordBytes, kMaxTransferBytes);
      expect(
        kSessionFrameTypes,
        unorderedEquals((sessionRecords['types'] as List).cast<String>()),
      );
    },
  );

  test('Dart hashes and frames every session-record golden byte vector', () {
    final samples = (_map(fixture['sessionRecords'])['samples'] as List)
        .cast<Map<String, dynamic>>();
    for (final sample in samples) {
      final json = sample['json'] as String;
      final payload = Uint8List.fromList(utf8.encode(json));
      expect(frameIdOf(payload), sample['frameId'], reason: sample['name'] as String);
      final expectedRecord = Uint8List(4 + payload.length);
      ByteData.sublistView(
        expectedRecord,
      ).setUint32(0, payload.length, Endian.big);
      expectedRecord.setRange(4, expectedRecord.length, payload);
      expect(
        _toHex(expectedRecord),
        sample['recordHex'],
        reason: sample['name'] as String,
      );
      final type = (jsonDecode(json) as Map<String, dynamic>)['type'];
      expect(
        isSessionFrameType(type),
        sample['session'],
        reason: sample['name'] as String,
      );
    }
  });

  test('Dart authorization bounds match the shared transport vector', () {
    final authorization = _map(fixture['authorization']);
    expect(peerIdentityMaxChars, authorization['identityMaxChars']);
    expect(maxAuthorizedPeers, authorization['maxAuthorizedPeers']);
    expect(maxPeerRelayUrls, authorization['maxRelayUrls']);
    expect(maxPeerGeneration, authorization['maxGeneration']);
    expect(maxPeerLeaseMs, authorization['maxLeaseMs']);
  });

  test('Dart stream-open caps match the shared transport vector', () {
    final streamOpen = _map(fixture['streamOpen']);
    expect(kStreamOpenMaxBytes, streamOpen['maxOpenBytes']);
    final caps = _map(streamOpen['caps']);
    expect(kStreamMaxBidiStreamsPerConnection, caps['maxBidiStreamsPerConnection']);
    expect(kStreamMaxProjectsPerPeer, caps['maxProjectsPerPeer']);
    expect(kStreamMaxTerminalAttachmentsPerPeer, caps['maxTerminalAttachmentsPerPeer']);
    expect(kStreamMaxTunnelStreamsPerPeer, caps['maxTunnelStreamsPerPeer']);
    expect(kStreamMaxPendingOpensPerPeer, caps['maxPendingOpensPerPeer']);
    expect(kStreamMaxUploadStreamsPerPeer, caps['maxUploadStreamsPerPeer']);
    final uploadRecords = _map(streamOpen['uploadRecords']);
    expect(kStreamUploadBridgeRecordMaxBytes, uploadRecords['bridgeMaxRecordBytes']);
    expect(kStreamUploadMaxFileNameLength, uploadRecords['maxFileNameLength']);
    expect(kStreamUploadMaxMimeTypeLength, uploadRecords['maxMimeTypeLength']);
    final projectRecords = _map(streamOpen['projectRecords']);
    expect(kStreamProjectAppRecordMaxBytes, projectRecords['appMaxRecordBytes']);
    expect(
      kStreamProjectBridgeRecordMaxBytes,
      projectRecords['bridgeMaxRecordBytes'],
    );
    expect(kMaxTransferBytes, projectRecords['maxTransferBytes']);
    final terminalRecords = _map(streamOpen['terminalRecords']);
    expect(kStreamTerminalAppRecordMaxBytes, terminalRecords['appMaxRecordBytes']);
    expect(kStreamTerminalBridgeRecordMaxBytes, terminalRecords['bridgeMaxRecordBytes']);
    final tunnelRecords = _map(streamOpen['tunnelRecords']);
    expect(kStreamTunnelDataMaxBytes, tunnelRecords['maxDataBytes']);
    expect(kStreamTunnelRecordMaxBytes, tunnelRecords['maxRecordBytes']);
    expect(kStreamTunnelRequestBodyMaxBytes, tunnelRecords['requestBodyMaxBytes']);
    final tags = _map(tunnelRecords['tags']);
    expect(kTunnelRecordTagWsText, tags['wsText']);
    expect(kTunnelRecordTagWsBinary, tags['wsBinary']);
    expect(tags.keys, unorderedEquals(['wsText', 'wsBinary']));
  });

  test('Dart encodes every stream-open kind golden vector', () {
    final opens = (_map(fixture['streamOpen'])['opens'] as List)
        .cast<Map<String, dynamic>>();
    expect(opens.map((o) => o['name']), [
      'session',
      'project',
      'terminal',
      'terminal-with-checkout',
      'tunnel-http',
      'tunnel-ws',
      'upload',
      'upload-with-checkout-and-mime',
    ]);
    for (final sample in opens) {
      final json = _map(sample['json']);
      expect(_openFrom(json).toJson(), json, reason: sample['name'] as String);
    }
  });

  test('Dart stream labels match the shared netwatch label vectors', () {
    final labels = (_map(fixture['streamOpen'])['labels'] as List)
        .cast<Map<String, dynamic>>();
    expect(labels, isNotEmpty);
    for (final sample in labels) {
      final label = streamLabelOf(_openFrom(_map(sample['open'])));
      expect(label.kind, sample['streamKind'], reason: sample['name'] as String);
      expect(label.id, sample['streamId'], reason: sample['name'] as String);
    }
  });

  test('Dart rejects every stream-refused record the schema rejects', () {
    final rejected = (_map(fixture['streamOpen'])['rejectedRefusals'] as List)
        .cast<Map<String, dynamic>>();
    expect(rejected, isNotEmpty);
    for (final sample in rejected) {
      expect(
        StreamRefused.fromJson(_map(sample['json'])),
        isNull,
        reason: sample['name'] as String,
      );
    }
  });

  test('Dart parses every stream-refused code golden vector, and round-trips it', () {
    final refusals = (_map(fixture['streamOpen'])['refusals'] as List)
        .cast<Map<String, dynamic>>();
    expect(refusals.map((r) => r['name']), [
      'not-ready',
      'not-allowed',
      'cap-exceeded',
      'invalid',
    ]);
    for (final sample in refusals) {
      final json = _map(sample['json']);
      final parsed = StreamRefused.fromJson(json);
      expect(parsed, isNotNull, reason: sample['name'] as String);
      expect(parsed!.toJson(), json, reason: sample['name'] as String);
    }
    // A Dart-only code would pass every other check here. Unordered: the
    // fixture's entry order is not required to match enum declaration order.
    expect(
      refusals.map((r) => _map(r['json'])['code']).toList(),
      unorderedEquals(StreamRefusedCode.values.map((c) => c.wireValue)),
    );
  });

  test('Dart QUIC timing constants match the shared transport vector', () {
    final quic = _map(fixture['quic']);
    expect(kPeerQuicKeepAliveInterval.inMilliseconds, quic['keepAliveIntervalMs']);
    expect(kPeerQuicMaxIdleTimeout.inMilliseconds, quic['maxIdleTimeoutMs']);
  });
}
