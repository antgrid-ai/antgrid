import 'dart:typed_data';
import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Explicit carrier for session tests; central presence never owns its lifecycle.
class FixedPeerConnector implements PeerConnector {
  FixedPeerConnector(PeerLink link) : link = TestPayloadLink(link);
  FixedPeerConnector.stub() : link = _NoopPayloadLink();
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
    PeerLinkDiagnostic? diagnostic,
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
  Stream<IncomingSessionRecord> get messageStream => carrier.messageStream;
  @override
  Stream<PeerLinkState> get payloadStateStream => carrier.payloadStateStream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  PeerLinkDiagnostic? get netTap => carrier.netTap;
  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) =>
      carrier.sendRecord(payload);
  @override
  Future<void> close() async {}

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) => carrier.openStream(
    open,
    maxRecordBytes: maxRecordBytes,
    maxQueuedBytes: maxQueuedBytes,
    rawAfterRecords: rawAfterRecords,
  );
}

class _NoopPayloadLink implements PeerLink {
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
  PeerLinkDiagnostic? get netTap => null;
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
