import 'dart:async';
import 'dart:typed_data';

import 'models/stream_open.dart';

enum PeerLinkState { connecting, ready, closed }

enum PeerPath { unknown, direct, relay }

enum PeerSendOutcome { accepted, closed, tooLarge, backpressured, failed }

/// One decoded record off the session stream: either a session frame
/// (`session:hello`/`established`/`ping`/`pong`/`takeover`) or a bare
/// control-plane `AbMessage`. The two are told apart by the JSON `type`
/// alone (`isSessionFrameType`, `frame.dart`); a record has no header.
class IncomingSessionRecord {
  const IncomingSessionRecord({required this.payload});

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
  Stream<IncomingSessionRecord> get messageStream;
  Stream<PeerLinkState> get payloadStateStream;
  Stream<PeerPath> get pathStream;
  Stream<PeerLinkFailure> get failureStream;

  PeerLinkDiagnostic? get netTap;

  /// Synchronous authorization/admission fence. Lease wrappers must clear this
  /// before notifying listeners; consumers recheck it after asynchronous work.
  bool get isDispatchAllowed;

  /// Accepted means handed to the local transport, never delivered to the peer.
  /// No failed outcome may be retried by the link itself. [payload] is the
  /// exact JSON body of one session frame or one control-plane `AbMessage`,
  /// with no header.
  Future<PeerSendOutcome> sendRecord(Uint8List payload);

  /// Opens one stream and writes [open] as its first record: a fresh native
  /// stream is invisible to the peer until something is written on it.
  /// Throws if the link may not dispatch or the open frame cannot be sent.
  /// A bridge refusal arrives later, in-band, as a `stream:refused` record
  /// on [PeerStream.records]. The bounds differ by stream kind, so neither
  /// has a default.
  ///
  /// [rawAfterRecords], when set (>= 1), switches the stream to raw reads
  /// after that many decoded records have been delivered on [PeerStream.records]:
  /// every later event is an unframed chunk, a FIN closes the stream cleanly,
  /// and a reset delivers one [PeerStreamReset] before closing it. Used by the
  /// upload and tunnel-http streams, whose bodies carry no per-record framing.
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  });

  Future<void> close();
}

/// Delivered as an error on [PeerStream.records] in the raw phase only: the
/// peer reset its send half, or the connection went, before FIN. Record mode
/// cannot distinguish a reset from a FIN (both just close [PeerStream.records]),
/// so this is raised only once a stream has moved into raw reads
/// ([PeerLink.openStream]'s `rawAfterRecords`).
final class PeerStreamReset implements Exception {
  const PeerStreamReset();
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

  /// [bytes] with no length prefix, queued and bounded exactly as [send] is.
  /// Completes `accepted` only once every byte has been written to the
  /// native stream — there is no ack, so a caller measuring progress reads it
  /// off this future settling, not off anything the peer sends back.
  Future<PeerSendOutcome> sendRaw(Uint8List bytes);

  /// Abandons the send half. Required on every error path: the native
  /// binding FINs a send half that is dropped without a reset, which the
  /// peer reads as a clean end.
  Future<void> reset();

  /// Writes what is already queued, then ends the send half cleanly.
  Future<void> finish();
}
