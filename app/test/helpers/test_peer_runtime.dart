import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

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
  Stream<IncomingPeerFrame> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  final PeerLinkDiagnostic? netTap;
  @override
  Future<PeerSendOutcome> sendFrame(
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async => PeerSendOutcome.accepted;
  @override
  Future<void> close() async {}
}
