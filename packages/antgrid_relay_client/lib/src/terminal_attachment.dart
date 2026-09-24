/// Terminal attachment handles: the transport-agnostic surface `terminal_service.dart`
/// drives regardless of whether the attachment rides its own native QUIC
/// stream ([MachineSession]'s `StreamTransport`, see `machine_session.dart`)
/// or the legacy socket path ([SocketTerminalAttachments], used by every
/// [BufferedAgentTransport] and by `FakeAgentTransport`).
library;

import 'dart:async';

import 'models/stream_open.dart';

/// Bounds one socket-path attachment's [TerminalAttachment.messages] buffer.
/// Side-local: the stream path bounds its own queue through
/// `MultiStreamPeerLink.openStream`'s `maxQueuedBytes` instead.
const int kTerminalAttachmentMaxQueuedBytes = 65536;

/// Why a [TerminalAttachment.done] completed.
sealed class TerminalAttachmentEnd {
  const TerminalAttachmentEnd();
}

/// Stream path only: the bridge's half ended (FIN or reset; Dart cannot tell
/// them apart).
final class TerminalAttachmentPeerEnded extends TerminalAttachmentEnd {
  const TerminalAttachmentPeerEnded();
}

/// The bridge refused the attachment in-band, before or instead of
/// `terminal:subscribed`.
final class TerminalAttachmentRefused extends TerminalAttachmentEnd {
  const TerminalAttachmentRefused(this.refusal);
  final StreamRefused refusal;
}

/// A local failure this side could not carry the attachment past.
///
/// [code] is one of `CAP_EXCEEDED`, `NO_PROJECT`, `STREAM_OPEN_FAILED`,
/// `SEND_FAILED`, `INVALID_RECORD`.
final class TerminalAttachmentFailed extends TerminalAttachmentEnd {
  const TerminalAttachmentFailed(this.code, [this.error]);
  final String code;
  final Object? error;
}

/// The underlying transport stopped being established before the attachment
/// ended any other way.
final class TerminalAttachmentTransportClosed extends TerminalAttachmentEnd {
  const TerminalAttachmentTransportClosed();
}

/// This side called [TerminalAttachment.close] and it completed.
final class TerminalAttachmentClosedLocally extends TerminalAttachmentEnd {
  const TerminalAttachmentClosedLocally();
}

/// One `terminal:subscribe` attempt and whatever live attachment it produced.
abstract interface class TerminalAttachment {
  String get requestId;
  String get checkoutId;

  /// True when this attachment rides its own native stream.
  bool get isStream;

  /// Every message for this attachment, in arrival order, exactly once.
  /// Single-subscription, buffered until listened to, closed when [done]
  /// completes.
  Stream<Map<String, dynamic>> get messages;

  /// Never throws. After [done] it is a no-op.
  Future<void> send(Map<String, dynamic> message);

  /// Idempotent. Sends nothing by itself: a caller holding an attachment
  /// sends `terminal:unsubscribe` through [send] first, as today.
  Future<void> close();

  Future<TerminalAttachmentEnd> get done;
}

/// The socket-path implementation used by every [BufferedAgentTransport] and
/// by `FakeAgentTransport`. Diverts a decoded inbound JSON map that belongs to
/// an open attachment away from the transport's ordinary [InboundMessage]
/// stream — see [divert].
class SocketTerminalAttachments {
  SocketTerminalAttachments(this._send);

  final Future<void> Function(Map<String, dynamic> message) _send;

  final Map<String, _SocketTerminalAttachment> _byRequestId = {};
  final Map<String, _SocketTerminalAttachment> _byAttachmentId = {};

  TerminalAttachment open({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> subscribe,
  }) {
    final attachment = _SocketTerminalAttachment(
      requestId: requestId,
      checkoutId: checkoutId,
      send: _send,
      onEnded: () => _forget(requestId),
    );
    _byRequestId[requestId] = attachment;
    // Fire-and-forget like every other outbound verb on this transport: a
    // failure surfaces (if at all) through the transport's own drop
    // reporting, never through this call.
    unawaited(_send(subscribe));
    return attachment;
  }

  void _forget(String requestId) {
    final attachment = _byRequestId.remove(requestId);
    final attachmentId = attachment?.attachmentId;
    if (attachmentId != null) _byAttachmentId.remove(attachmentId);
  }

  /// True when [json] belonged to an open attachment and was delivered to it;
  /// the caller must then not publish it. The lookup table is open
  /// attachments only — a reply to an attachment already [close]d or ended is
  /// never diverted, and reaches the caller's ordinary dispatch instead.
  bool divert(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'terminal:subscribed':
        final requestId = json['requestId'];
        final attachment = requestId is String ? _byRequestId[requestId] : null;
        if (attachment == null) return false;
        final attachmentId = json['attachmentId'];
        if (attachmentId is String && attachment.attachmentId == null) {
          attachment.attachmentId = attachmentId;
          _byAttachmentId[attachmentId] = attachment;
        }
        attachment.deliver(json);
        return true;
      case 'terminal:display:status':
        final attachmentId = json['attachmentId'];
        final requestId = json['requestId'];
        final byAttachment = attachmentId is String
            ? _byAttachmentId[attachmentId]
            : null;
        final attachment =
            byAttachment ?? (requestId is String ? _byRequestId[requestId] : null);
        if (attachment == null) return false;
        attachment.deliver(json);
        return true;
      case 'terminal:frame':
      case 'terminal:history:page':
        final attachmentId = json['attachmentId'];
        final attachment = attachmentId is String
            ? _byAttachmentId[attachmentId]
            : null;
        if (attachment == null) return false;
        attachment.deliver(json);
        return true;
      default:
        return false;
    }
  }

  /// Ends every open attachment [TerminalAttachmentTransportClosed].
  void closeAll() {
    for (final attachment in _byRequestId.values.toList()) {
      attachment.end(const TerminalAttachmentTransportClosed());
    }
  }

  /// Test-only seam: end [requestId]'s attachment as if the transport had.
  /// Not part of the supported API — no `meta` dependency in this package to
  /// mark it with, so callers police this by convention.
  void endAttachment(String requestId, TerminalAttachmentEnd end) {
    _byRequestId[requestId]?.end(end);
  }
}

class _SocketTerminalAttachment implements TerminalAttachment {
  _SocketTerminalAttachment({
    required this.requestId,
    required this.checkoutId,
    required Future<void> Function(Map<String, dynamic>) send,
    required void Function() onEnded,
  }) : _send = send,
       _onEnded = onEnded;

  @override
  final String requestId;
  @override
  final String checkoutId;

  /// Recorded once `terminal:subscribed` names it; null until then. Not
  /// final — [SocketTerminalAttachments] writes it once, from `divert`.
  String? attachmentId;

  final Future<void> Function(Map<String, dynamic>) _send;
  final void Function() _onEnded;

  final _messages = StreamController<Map<String, dynamic>>();
  final _doneCompleter = Completer<TerminalAttachmentEnd>();
  bool _ended = false;
  bool _closed = false;

  @override
  bool get isStream => false;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<TerminalAttachmentEnd> get done => _doneCompleter.future;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_ended) return;
    try {
      await _send(message);
    } catch (_) {
      // Never throws — this transport's own send is already fire-and-forget.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Not awaiting the controller's close: its future waits for a listener to
    // drain, and a caller that never listened to [messages] would hang here.
    end(const TerminalAttachmentClosedLocally());
  }

  void deliver(Map<String, dynamic> json) {
    if (_messages.isClosed) return;
    _messages.add(json);
  }

  void end(TerminalAttachmentEnd end) {
    if (_ended) return;
    _ended = true;
    _onEnded();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete(end);
    unawaited(_messages.close());
  }
}
