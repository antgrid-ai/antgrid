import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value! as Map);

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

String _toHex(Uint8List value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final fixture = _map(
    jsonDecode(
      File(
        '../../evals/fixtures/peer-transport-vectors.json',
      ).readAsStringSync(),
    ),
  );

  test(
    'Dart framing and native constants match the shared transport vector',
    () {
      final framing = _map(fixture['framing']);
      expect(peerFrameVersion, framing['version']);
      expect(peerFrameFixedPrefix, framing['fixedPrefixBytes']);
      expect(maxPeerFrameHeaderBytes, framing['maxHeaderBytes']);
      expect(kMaxFramePayload, framing['maxPayloadBytes']);
      expect(maxPeerRecordBytes, framing['maxRecordBytes']);
      expect(FrameKind.message.wireValue, _map(framing['kinds'])['message']);

      final native = _map(fixture['native']);
      expect(peerAlpn, native['alpn']);
      expect(maxPeerLeaseMs, native['leaseMs']);
      expect(maxPeerLeaseMs ~/ 3, native['refreshMs']);
      expect(native['selectionMs'], 5000);
      expect(native['endpointChallengeMs'], 120000);
    },
  );

  test('Dart encodes and decodes every peer-frame golden byte vector', () {
    final samples = (_map(fixture['framing'])['samples'] as List)
        .cast<Map<String, dynamic>>();
    for (final sample in samples) {
      final header = _map(sample['header']);
      final kind = FrameKind.fromWire(sample['kind'] as int)!;
      expect(kind, FrameKind.message, reason: sample['name'] as String);
      final payload = _hex(sample['payloadHex'] as String);
      final encoded = encodePeerFrame(header, payload);
      expect(
        _toHex(encoded),
        sample['frameHex'],
        reason: sample['name'] as String,
      );

      final decoded = decodePeerFrame(_hex(sample['frameHex'] as String));
      expect(decoded.header, header);
      expect(decoded.payload, payload);
      expect(decoded.header.containsKey('to'), isFalse);
      expect(decoded.header.containsKey('from'), isFalse);
    }
  });

  test(
    'Dart flow, fragmentation, and authorization bounds match the vector',
    () {
      final frag = _map(fixture['fragmentation']);
      expect(kFragThreshold, frag['thresholdBytes']);
      expect(kFragDataBudget, frag['dataBudgetBytes']);
      expect(kMaxTransferBytes, frag['maxTransferBytes']);
      expect(kTransferTimeoutMs, frag['transferTimeoutMs']);
      expect(kGlobalReassemblyBudget, frag['globalReassemblyBudgetBytes']);
      expect(kMaxRerequests, frag['maxRerequests']);
      expect(kMaxFragmentCount, frag['maxFragmentCount']);

      final flow = _map(fixture['flowControl']);
      expect(kChannelWindowBytes, flow['channelWindowBytes']);
      expect(kSocketInflightBytes, flow['socketInflightBytes']);
      expect(kCreditBatchBytes, flow['creditBatchBytes']);
      expect(kMaxSendQueueBytes, flow['maxSendQueueBytes']);
      expect(kWindowResyncAgeMs, flow['windowResyncAgeMs']);
      expect(kWindowStallWarnMs, flow['windowStallWarnMs']);

      final authorization = _map(fixture['authorization']);
      expect(peerIdentityMaxChars, authorization['identityMaxChars']);
      expect(maxAuthorizedPeers, authorization['maxAuthorizedPeers']);
      expect(maxPeerRelayUrls, authorization['maxRelayUrls']);
      expect(maxPeerGeneration, authorization['maxGeneration']);
      expect(maxPeerLeaseMs, authorization['maxLeaseMs']);
    },
  );

  test('Dart stream-open caps match the shared transport vector', () {
    final streamOpen = _map(fixture['streamOpen']);
    expect(kStreamOpenMaxBytes, streamOpen['maxOpenBytes']);
    expect(kStreamOpenMaxIdLength, streamOpen['maxIdLength']);
    final caps = _map(streamOpen['caps']);
    expect(kStreamMaxBidiStreamsPerConnection, caps['maxBidiStreamsPerConnection']);
    expect(kStreamMaxProjectsPerPeer, caps['maxProjectsPerPeer']);
    expect(kStreamMaxTerminalAttachmentsPerPeer, caps['maxTerminalAttachmentsPerPeer']);
    expect(kStreamMaxTunnelStreamsPerPeer, caps['maxTunnelStreamsPerPeer']);
    expect(kStreamMaxPendingOpensPerPeer, caps['maxPendingOpensPerPeer']);
  });

  test('Dart parses every stream-open kind golden vector, and round-trips it', () {
    final opens = (_map(fixture['streamOpen'])['opens'] as List)
        .cast<Map<String, dynamic>>();
    expect(opens.map((o) => o['name']), [
      'session',
      'project',
      'terminal',
      'terminal-with-checkout',
      'tunnel-http',
      'tunnel-ws',
    ]);
    for (final sample in opens) {
      final json = _map(sample['json']);
      final parsed = StreamOpen.fromJson(json);
      expect(parsed, isNotNull, reason: sample['name'] as String);
      expect(parsed!.toJson(), json, reason: sample['name'] as String);
      switch (sample['name']) {
        case 'session':
          expect(parsed, isA<SessionStreamOpen>());
        case 'project':
          expect(parsed, isA<ProjectStreamOpen>());
        case 'terminal':
        case 'terminal-with-checkout':
          expect(parsed, isA<TerminalStreamOpen>());
        case 'tunnel-http':
          expect(parsed, isA<TunnelHttpStreamOpen>());
        case 'tunnel-ws':
          expect(parsed, isA<TunnelWsStreamOpen>());
      }
    }
  });

  test('Dart rejects every stream-open frame the schema rejects', () {
    final rejected = (_map(fixture['streamOpen'])['rejectedOpens'] as List)
        .cast<Map<String, dynamic>>();
    expect(rejected, isNotEmpty);
    for (final sample in rejected) {
      expect(
        StreamOpen.fromJson(_map(sample['json'])),
        isNull,
        reason: sample['name'] as String,
      );
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
      'update-required',
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
    // A Dart-only code would pass every other check here.
    expect(
      refusals.map((r) => _map(r['json'])['code']).toList(),
      StreamRefusedCode.values.map((c) => c.wireValue).toList(),
    );
  });

}
