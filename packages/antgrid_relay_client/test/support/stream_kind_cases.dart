// Not a `_test.dart` file - the DSA table `stream_admission_test.dart` drives.
// One entry per `_StreamExchange` subclass in `machine_session.dart`
// (terminal, tunnel-tcp, upload); the project stream keeps its
// own bind machinery (unchanged) and its admission rows live directly in
// `stream_admission_test.dart` instead of here.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// One kind's shape, generalized enough that every admission rule in
/// `stream_admission_test.dart` runs once per entry instead of once per kind.
class StreamKindCase {
  const StreamKindCase({
    required this.kind,
    required this.cap,
    required this.failsFastAtCap,
    required this.maxRecordBytes,
    required this.maxQueuedBytes,
    required this.open,
    required this.failureCode,
    required this.cancel,
    required this.sendsFirstRecord,
  });

  final String kind;
  final int cap;
  final bool failsFastAtCap;
  final int maxRecordBytes;
  final int maxQueuedBytes;

  /// Opens the [i]th handle of this kind on [transport]. Every call must mint
  /// a distinct id (`'$kind-$i'` style) so concurrent opens never collide.
  final Object Function(StreamTransport transport, int i) open;

  /// Awaits [handle]'s own end and returns the failure code it settled with,
  /// or `null` once it ended cleanly (a peer FIN/close with nothing to
  /// blame) — never for a `cancel()`, which several kinds still code as a
  /// real failure (`CANCELLED`); callers that drive a cancel assert on the
  /// resulting `code` directly rather than through this null convention.
  final Future<String?> Function(Object handle) failureCode;

  final void Function(Object handle) cancel;

  /// False only for upload: its metadata rides the open frame itself, so it
  /// never sends a first record for a SEND_FAILED test to target — that kind
  /// resends failures through its first raw slice instead.
  final bool sendsFirstRecord;
}

List<StreamKindCase> streamKindCases() => [
  StreamKindCase(
    kind: 'terminal',
    cap: kStreamMaxTerminalAttachmentsPerPeer,
    failsFastAtCap: true,
    maxRecordBytes: kStreamTerminalBridgeRecordMaxBytes,
    maxQueuedBytes: kTerminalAttachmentMaxQueuedBytes,
    sendsFirstRecord: true,
    open: (t, i) => t.openTerminalAttachment(
      requestId: 'term-$i',
      checkoutId: 'main',
      subscribe: {'type': 'terminal:subscribe', 'requestId': 'term-$i'},
    ),
    failureCode: (h) async {
      final end = await (h as TerminalAttachment).done;
      return switch (end) {
        TerminalAttachmentFailed(:final code) => code,
        TerminalAttachmentRefused() => 'REFUSED',
        TerminalAttachmentTransportClosed() => 'TRANSPORT_CLOSED',
        TerminalAttachmentPeerEnded() => null,
        TerminalAttachmentClosedLocally() => null,
      };
    },
    cancel: (h) => unawaited((h as TerminalAttachment).close()),
  ),
  StreamKindCase(
    kind: 'tunnel-tcp',
    cap: kStreamMaxTunnelStreamsPerPeer,
    failsFastAtCap: false,
    maxRecordBytes: kStreamTunnelTcpRecordMaxBytes,
    maxQueuedBytes: kTunnelStreamMaxQueuedBytes,
    sendsFirstRecord: true,
    open: (t, i) => t.openTunnelTcp(connId: 'tcp-$i', port: 3000),
    failureCode: (h) async {
      try {
        await (h as TunnelTcpChannel).ready;
        return null;
      } on TunnelExchangeFailure catch (e) {
        return e.code;
      }
    },
    cancel: (h) => (h as TunnelTcpChannel).abort(),
  ),
  StreamKindCase(
    kind: 'upload',
    cap: kStreamMaxUploadStreamsPerPeer,
    failsFastAtCap: false,
    maxRecordBytes: kStreamUploadBridgeRecordMaxBytes,
    maxQueuedBytes: kUploadStreamMaxQueuedBytes,
    sendsFirstRecord: false,
    open: (t, i) => t.openUpload(
      requestId: 'up-$i',
      projectId: 'proj-a',
      checkoutId: 'main',
      fileName: 'f$i.bin',
      bytes: Uint8List.fromList([1, 2, 3]),
    ),
    failureCode: (h) async {
      try {
        await (h as UploadExchange).result;
        return null;
      } on UploadFailure catch (e) {
        return e.code;
      }
    },
    cancel: (h) => (h as UploadExchange).cancel(),
  ),
];
