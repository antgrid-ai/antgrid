import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

const leaseDeviceId = '00000000-0000-4000-8000-000000000001';
const leasePeerId = '00000000-0000-4000-8000-000000000002';

/// The enrollment [leaseSnapshotJson] authorizes.
DeviceRecord leaseRecord() => DeviceRecord(
  userId: 'account',
  deviceUuid: leaseDeviceId,
  clientId: 'credential',
  clientSecret: 'secret',
  ed25519Pub: base64Encode(Uint8List(32)),
  ed25519Priv: base64Encode(Uint8List(32)),
  x25519Pub: '',
  x25519Priv: '',
  endpointSecret: base64Encode(Uint8List(32)),
);

/// An allowed authorization snapshot for [leaseRecord] with [leasePeerId] as
/// its one peer.
final leaseSnapshotJson = jsonEncode({
  'accountId': 'account',
  'deviceId': leaseDeviceId,
  'enrollmentId': 'credential',
  'registrationGeneration': '0',
  'policyGeneration': '1',
  'allowed': true,
  'leaseMs': 60000,
  'endpoint': null,
  'relayUrls': <String>[],
  'peers': [
    {
      'deviceId': leasePeerId,
      'ed25519Pub': base64Encode(List.filled(32, 1)),
      'endpoint': null,
    },
  ],
});

/// Uses each test's in-memory relay as an explicit payload double, without
/// provisioning native libraries or making HTTP authorization requests.
class TestPeerRuntime extends PeerRuntime {
  TestPeerRuntime({PeerLink? payloadLink})
    : _payloadLink = payloadLink,
      super(
        record: DeviceRecord(
          userId: 'test',
          deviceUuid: 'test',
          clientId: 'test',
          clientSecret: 'test',
          ed25519Pub: base64Encode(Uint8List(32)),
          ed25519Priv: base64Encode(Uint8List(32)),
          x25519Pub: '',
          x25519Priv: '',
          endpointSecret: base64Encode(Uint8List(32)),
        ),
        licenseApiUrl: 'https://unused.invalid',
        mintToken: () async => 'test',
        rejectToken: (_) => false,
      );

  final PeerLink? _payloadLink;

  @override
  void retain() {}
  @override
  void release() {}
  @override
  Future<PeerLink> connect({
    required PeerConnectionAttempt attempt,
    PeerLinkDiagnostic? diagnostic,
    required String machineDeviceId,
    required String machinePublicKey,
  }) async => _payloadLink ?? _TestPayloadLink(diagnostic);
}

class _TestPayloadLink implements PeerLink {
  _TestPayloadLink(this.netTap);
  @override
  bool get isDispatchAllowed => true;
  @override
  Stream<IncomingSessionRecord> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  final PeerLinkDiagnostic? netTap;
  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async =>
      PeerSendOutcome.accepted;
  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) => throw UnimplementedError('not exercised by this suite');
  @override
  Future<void> close() async {}
}
