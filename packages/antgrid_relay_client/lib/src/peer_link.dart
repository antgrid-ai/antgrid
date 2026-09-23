import 'dart:async';
import 'dart:typed_data';

enum PeerLinkState { connecting, ready, closed }

enum PeerPath { unknown, direct, relay }

enum PeerSendOutcome { accepted, closed, tooLarge, backpressured, failed }

class IncomingPeerFrame {
  const IncomingPeerFrame({required this.channel, required this.payload});

  final String channel;
  final Uint8List payload;
}

typedef PeerLinkDiagnostic = void Function(Map<String, Object?> event);

class PeerLinkFailure {
  const PeerLinkFailure({required this.code, required this.retryable});

  final String code;
  final bool retryable;
}

/// Payload transport only. Central inventory/presence belongs to its own client.
/// Implementations must bound queued bytes, fence writes by connection generation
/// and complete sends on admission or rejection, never wait for remote delivery.
abstract interface class PeerLink {
  Stream<IncomingPeerFrame> get messageStream;
  Stream<PeerLinkState> get payloadStateStream;
  Stream<PeerPath> get pathStream;
  Stream<PeerLinkFailure> get failureStream;

  PeerLinkDiagnostic? get netTap;

  /// Synchronous authorization/admission fence. Lease wrappers must clear this
  /// before notifying listeners; consumers recheck it after asynchronous work.
  bool get isDispatchAllowed;

  /// Accepted means handed to the local transport, never delivered to the peer.
  /// No failed outcome may be retried by the link itself.
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload);

  Future<void> close();
}
