import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';
import 'models/stream_open.dart';

enum PeerLinkState { connecting, ready, closed }

enum PeerPath { unknown, direct, relay }

enum PeerSendOutcome { accepted, closed, tooLarge, backpressured, failed }

class IncomingPeerFrame {
  const IncomingPeerFrame({required this.kind, required this.payload});

  /// [kPeerFrameSession] or [kPeerFrameMessage].
  final String kind;
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
  /// No failed outcome may be retried by the link itself. [kind] must be
  /// [kPeerFrameSession] or [kPeerFrameMessage].
  Future<PeerSendOutcome> sendFrame(String kind, Uint8List payload);

  Future<void> close();
}

/// One purpose-specific native stream. The send and receive halves end
/// independently: [reset] and [finish] end only the send half.
abstract interface class PeerStream {
  /// Decoded records in arrival order. Ends when the peer finishes or resets
  /// its send half, when the connection goes, or on a violation that retires
  /// the connection; never because this side called [reset] or [finish]. A
  /// cancelling caller keeps draining here until the peer's own end arrives.
  Stream<Uint8List> get records;

  /// Queues one record. A non-`accepted` outcome is final for this record;
  /// `backpressured` means the stream was reset and must be reopened.
  Future<PeerSendOutcome> send(Uint8List record);

  /// Abandons the send half. Required on every error path: the native
  /// binding FINs a send half that is dropped without a reset, which the
  /// peer reads as a clean end.
  Future<void> reset();

  /// Writes what is already queued, then ends the send half cleanly.
  Future<void> finish();
}

/// A link that can open purpose-specific streams. Separate from [PeerLink]
/// so implementers with a single channel need not grow a stream API.
abstract interface class MultiStreamPeerLink {
  bool get isDispatchAllowed;

  /// Opens one stream and writes [open] as its first record: a fresh native
  /// stream is invisible to the peer until something is written on it.
  /// Throws if the link may not dispatch or the open frame cannot be sent.
  /// A bridge refusal arrives later, in-band, as a `stream:refused` record
  /// on [PeerStream.records]. The bounds differ by stream kind, so neither
  /// has a default.
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
  });
}
