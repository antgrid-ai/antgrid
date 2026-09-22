import 'dart:typed_data';
import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Explicit carrier for session tests; central presence never owns its lifecycle.
class FixedPeerConnector implements PeerConnector {
  FixedPeerConnector(PeerLink link) : link = TestPayloadLink(link);
  final PeerLink link;
  @override
  void retain() {}
  @override
  void release() {}
  @override
  void invalidate() {}
  @override
  void notePolicyGeneration(BigInt generation) {}
  @override
  Future<bool> resume() async => true;
  @override
  Future<PeerLink> connect({
    required PeerConnectionAttempt attempt,
    required RelayService relay,
    required String machineDeviceId,
    required String machinePublicKey,
  }) async => link;
}

class TestPayloadLink implements PeerLink {
  TestPayloadLink(this.carrier);
  final PeerLink carrier;
  @override
  bool get isDispatchAllowed => true;
  @override
  Stream<IncomingRouteMessage> get messageStream => carrier.messageStream;
  @override
  Stream<PeerLinkState> get payloadStateStream => carrier.payloadStateStream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<void> get peerRestartStream => carrier.peerRestartStream;
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  PeerLinkDiagnostic? get netTap => carrier.netTap;
  @override
  Future<PeerSendOutcome> sendFrame(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) => carrier.sendFrame(to, channel, payload, kind: kind);
  @override
  Future<void> close() async {}
}
