// Hand mirror of `packages/antgrid-wire/src/stream-open.ts`, including which
// frames it rejects. Nothing but the shared fixture spans both languages, so
// every kind, refusal code and rejection case needs a vector there
// (`peer_transport_vectors_test.dart`).

import 'dart:convert';
import 'dart:typed_data';

/// Wire cap on a serialized open frame, checked before decoding — a
/// `{kind, projectId, ...}` record needs a few hundred bytes at most.
const int kStreamOpenMaxBytes = 4096;

/// Per-id length bound, in UTF-16 code units (Zod's `.max()` counts the same).
const int kStreamOpenMaxIdLength = 200;

// iroh 1.0's own keep-alive/idle defaults, recorded here rather than set:
// neither the bridge's napi binding nor the app's `iroh_quic` exposes a
// transport config to set them with. Both endpoints apply the same defaults,
// so the negotiated idle timeout is the minimum of both sides' values (here,
// itself). Mirror `PEER_QUIC_KEEP_ALIVE_INTERVAL_MS`/
// `PEER_QUIC_MAX_IDLE_TIMEOUT_MS` (`packages/antgrid-wire/src/stream-open.ts`)
// by hand, pinned by `peer-transport-vectors.json`.
const Duration kPeerQuicKeepAliveInterval = Duration(seconds: 5);
const Duration kPeerQuicMaxIdleTimeout = Duration(seconds: 30);

// Only the bridge can set the QUIC bidi limit; Dart has no setter. The app's
// open semaphores sit at the per-peer caps so an over-cap open fails locally
// instead of stalling on `openBi`.
const int kStreamMaxBidiStreamsPerConnection = 256;
const int kStreamMaxProjectsPerPeer = 32;
const int kStreamMaxTerminalAttachmentsPerPeer = 64;
const int kStreamMaxTunnelStreamsPerPeer = 128;
const int kStreamMaxUploadStreamsPerPeer = 4;
const int kStreamMaxPendingOpensPerPeer = 16;

/// Largest single `AbMessage` JSON the bridge writes on any stream
/// (`packages/antgrid-wire/src/stream-open.ts`).
const int kMaxTransferBytes = 33554432;

/// App → bridge: the bridge's read cap on a project-stream record, and the
/// app's send-refusal threshold on both the project and the session stream
/// (payload bytes).
const int kStreamProjectAppRecordMaxBytes = 1500000;

/// Bridge → app: the app's `maxRecordBytes` for a project-stream open. Equal
/// to [kMaxTransferBytes] — the asymmetry is by direction, not by stream.
const int kStreamProjectBridgeRecordMaxBytes = kMaxTransferBytes;

/// The app's write-queue bound for its session stream (`PeerLink.sendFrame`).
/// Sized for the app side, which only ever sends small control-plane
/// records — well under the bridge's matching `SESSION_STREAM_MAX_QUEUED_BYTES`.
/// Over it, `sendFrame` returns `PeerSendOutcome.backpressured`.
const int kSessionStreamMaxQueuedBytes = 4194304;

/// Payload cap on one WS tunnel data record, after its tag byte
/// ([kTunnelRecordTagWsText] etc.), in both directions. An HTTP tunnel body
/// carries no tag and is bounded by `bodyLength` instead.
const int kStreamTunnelDataMaxBytes = 1048576;

/// [kStreamTunnelDataMaxBytes] plus the tag byte — the bridge reader's cap for
/// a tunnel-stream record.
const int kStreamTunnelRecordMaxBytes = 1048577;

/// Caps an HTTP tunnel request's `bodyLength`. Equal to `MAX_TRANSFER_BYTES`:
/// a preview upload is bounded exactly as the session path bounded it.
const int kStreamTunnelRequestBodyMaxBytes = 33554432;

/// Tunnel-ws data record tags: the first byte after the JSON/data
/// discriminator (see `tunnel_stream.dart`'s `decodeTunnelRecord`). `0x00` and
/// `0x01` are unassigned now that HTTP bodies ride raw (no tag, no record
/// framing) — a stray one decodes to nothing rather than aliasing a WS frame.
const int kTunnelRecordTagWsText = 0x02;
const int kTunnelRecordTagWsBinary = 0x03;

/// Upload stream constants (`packages/antgrid-wire/src/stream-open.ts`).
const int kStreamUploadBridgeRecordMaxBytes = 16384;
const int kStreamUploadMaxFileNameLength = 255;
const int kStreamUploadMaxMimeTypeLength = 127;

/// Bridge reader's cap for the four small app-to-bridge terminal verbs
/// (subscribe, ack, unsubscribe, history:request).
const int kStreamTerminalAppRecordMaxBytes = 16384;

/// App reader's cap for a terminal-stream record from the bridge — twice
/// `TERMINAL_VIEWER_MAX_BYTES` (1 MiB), the largest frame delivery ever hands
/// over (see `bridge/src/peer/terminal-streams.ts`, across the licence
/// boundary this package cannot import).
const int kStreamTerminalBridgeRecordMaxBytes = 2097152;

bool _onlyKeys(Map<String, dynamic> json, Set<String> allowed) =>
    json.keys.every(allowed.contains);

bool _isId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= kStreamOpenMaxIdLength;

/// The first record written on every native peer stream, the session stream
/// included.
sealed class StreamOpen {
  const StreamOpen();

  String get kind;

  Map<String, dynamic> toJson();

  static StreamOpen? fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'session':
        return SessionStreamOpen.fromJson(json);
      case 'project':
        return ProjectStreamOpen.fromJson(json);
      case 'terminal':
        return TerminalStreamOpen.fromJson(json);
      case 'tunnel-http':
        return TunnelHttpStreamOpen.fromJson(json);
      case 'tunnel-ws':
        return TunnelWsStreamOpen.fromJson(json);
      case 'upload':
        return UploadStreamOpen.fromJson(json);
      default:
        return null;
    }
  }
}

final class SessionStreamOpen extends StreamOpen {
  const SessionStreamOpen();

  @override
  String get kind => 'session';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};

  static SessionStreamOpen? fromJson(Map<String, dynamic> json) {
    if (!_onlyKeys(json, {'kind'})) return null;
    return const SessionStreamOpen();
  }

  @override
  bool operator ==(Object other) => other is SessionStreamOpen;

  @override
  int get hashCode => kind.hashCode;
}

/// No `checkoutId`: a project stream is per PROJECT, and checkout routing
/// stays per message on it.
final class ProjectStreamOpen extends StreamOpen {
  final String projectId;

  const ProjectStreamOpen(this.projectId);

  @override
  String get kind => 'project';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'projectId': projectId};

  static ProjectStreamOpen? fromJson(Map<String, dynamic> json) {
    if (!_onlyKeys(json, {'kind', 'projectId'})) return null;
    final projectId = json['projectId'];
    if (!_isId(projectId)) return null;
    return ProjectStreamOpen(projectId as String);
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectStreamOpen && other.projectId == projectId;

  @override
  int get hashCode => Object.hash(kind, projectId);
}

/// `requestId` is what the terminal stream binds by BEFORE the bridge has
/// minted an `attachmentId` — `terminal:subscribe`'s reply and any
/// `UPGRADE_REQUIRED` refusal both carry only `requestId`. `checkoutId` is
/// optional for the same reason it is on `terminal:subscribe`: absent means
/// the main checkout.
final class TerminalStreamOpen extends StreamOpen {
  final String projectId;
  final String? checkoutId;
  final String requestId;

  const TerminalStreamOpen({
    required this.projectId,
    required this.requestId,
    this.checkoutId,
  });

  @override
  String get kind => 'terminal';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'projectId': projectId,
    if (checkoutId != null) 'checkoutId': checkoutId,
    'requestId': requestId,
  };

  static TerminalStreamOpen? fromJson(Map<String, dynamic> json) {
    if (!_onlyKeys(json, {'kind', 'projectId', 'checkoutId', 'requestId'})) {
      return null;
    }
    final projectId = json['projectId'];
    final requestId = json['requestId'];
    // `containsKey`, not a null check: Zod's `.optional()` rejects an explicit
    // null, so `{"checkoutId": null}` must be refused here too.
    final checkoutId = json['checkoutId'];
    if (json.containsKey('checkoutId') && !_isId(checkoutId)) return null;
    if (!_isId(projectId)) return null;
    if (!_isId(requestId)) return null;
    return TerminalStreamOpen(
      projectId: projectId as String,
      requestId: requestId as String,
      checkoutId: checkoutId as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalStreamOpen &&
      other.projectId == projectId &&
      other.checkoutId == checkoutId &&
      other.requestId == requestId;

  @override
  int get hashCode => Object.hash(kind, projectId, checkoutId, requestId);
}

/// One stream per HTTP request/response pair; `requestId` is the same id the
/// app already mints for `tunnel:http-request`.
final class TunnelHttpStreamOpen extends StreamOpen {
  final String projectId;
  final String requestId;

  const TunnelHttpStreamOpen({
    required this.projectId,
    required this.requestId,
  });

  @override
  String get kind => 'tunnel-http';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'projectId': projectId,
    'requestId': requestId,
  };

  static TunnelHttpStreamOpen? fromJson(Map<String, dynamic> json) {
    if (!_onlyKeys(json, {'kind', 'projectId', 'requestId'})) return null;
    final projectId = json['projectId'];
    final requestId = json['requestId'];
    if (!_isId(projectId)) return null;
    if (!_isId(requestId)) return null;
    return TunnelHttpStreamOpen(
      projectId: projectId as String,
      requestId: requestId as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TunnelHttpStreamOpen &&
      other.projectId == projectId &&
      other.requestId == requestId;

  @override
  int get hashCode => Object.hash(kind, projectId, requestId);
}

/// One stream per browser-side WebSocket for the tunnel's lifetime; `wsId`
/// carries the `tunnelId` the app mints for `tunnel:ws-open`.
final class TunnelWsStreamOpen extends StreamOpen {
  final String projectId;
  final String wsId;

  const TunnelWsStreamOpen({required this.projectId, required this.wsId});

  @override
  String get kind => 'tunnel-ws';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'projectId': projectId,
    'wsId': wsId,
  };

  static TunnelWsStreamOpen? fromJson(Map<String, dynamic> json) {
    if (!_onlyKeys(json, {'kind', 'projectId', 'wsId'})) return null;
    final projectId = json['projectId'];
    final wsId = json['wsId'];
    if (!_isId(projectId)) return null;
    if (!_isId(wsId)) return null;
    return TunnelWsStreamOpen(
      projectId: projectId as String,
      wsId: wsId as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TunnelWsStreamOpen &&
      other.projectId == projectId &&
      other.wsId == wsId;

  @override
  int get hashCode => Object.hash(kind, projectId, wsId);
}

/// One stream per uploaded file. `checkoutId` follows [TerminalStreamOpen]:
/// absent means the main checkout. `size` is the declared byte count the app
/// commits to sending; whether it exceeds the bridge's byte cap is a per-file
/// `TOO_LARGE` result, never a schema rejection.
final class UploadStreamOpen extends StreamOpen {
  final String projectId;
  final String? checkoutId;
  final String requestId;
  final String fileName;
  final int size;
  final String? mimeType;

  const UploadStreamOpen({
    required this.projectId,
    required this.requestId,
    required this.fileName,
    required this.size,
    this.checkoutId,
    this.mimeType,
  });

  @override
  String get kind => 'upload';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'projectId': projectId,
    if (checkoutId != null) 'checkoutId': checkoutId,
    'requestId': requestId,
    'fileName': fileName,
    'size': size,
    if (mimeType != null) 'mimeType': mimeType,
  };

  static UploadStreamOpen? fromJson(Map<String, dynamic> json) {
    if (!_onlyKeys(json, {
      'kind',
      'projectId',
      'checkoutId',
      'requestId',
      'fileName',
      'size',
      'mimeType',
    })) {
      return null;
    }
    final projectId = json['projectId'];
    final requestId = json['requestId'];
    // `containsKey`, not a null check: Zod's `.optional()` rejects an explicit
    // null, so `{"checkoutId": null}` (or `{"mimeType": null}`) must be
    // refused here too.
    final checkoutId = json['checkoutId'];
    if (json.containsKey('checkoutId') && !_isId(checkoutId)) return null;
    if (!_isId(projectId)) return null;
    if (!_isId(requestId)) return null;
    final fileName = json['fileName'];
    if (fileName is! String ||
        fileName.isEmpty ||
        fileName.length > kStreamUploadMaxFileNameLength) {
      return null;
    }
    final size = json['size'];
    if (size is! int || size < 0) return null;
    final mimeType = json['mimeType'];
    if (json.containsKey('mimeType')) {
      if (mimeType is! String ||
          mimeType.isEmpty ||
          mimeType.length > kStreamUploadMaxMimeTypeLength) {
        return null;
      }
    }
    return UploadStreamOpen(
      projectId: projectId as String,
      requestId: requestId as String,
      fileName: fileName,
      size: size,
      checkoutId: checkoutId as String?,
      mimeType: mimeType as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UploadStreamOpen &&
      other.projectId == projectId &&
      other.checkoutId == checkoutId &&
      other.requestId == requestId &&
      other.fileName == fileName &&
      other.size == size &&
      other.mimeType == mimeType;

  @override
  int get hashCode =>
      Object.hash(kind, projectId, checkoutId, requestId, fileName, size, mimeType);
}

/// `"0"` for the session stream (which carries no id of its own); `id` for
/// every other stream, mirroring the bridge's `NETWATCH_SESSION_STREAM_LABEL`
/// fallback in `streamLabelOf` (`bridge/src/peer/stream-dispatch.ts`). Hand
/// mirror pinned by the shared `streamOpen.labels` vectors
/// (`peer_transport_vectors_test.dart`).
const String kSessionStreamLabel = '0';

({String kind, String id}) streamLabelOf(StreamOpen open) => switch (open) {
  SessionStreamOpen() => (kind: 'session', id: kSessionStreamLabel),
  ProjectStreamOpen(:final projectId) => (kind: 'project', id: projectId),
  TerminalStreamOpen(:final requestId) => (kind: 'terminal', id: requestId),
  TunnelHttpStreamOpen(:final requestId) => (
    kind: 'tunnel-http',
    id: requestId,
  ),
  TunnelWsStreamOpen(:final wsId) => (kind: 'tunnel-ws', id: wsId),
  UploadStreamOpen(:final requestId) => (kind: 'upload', id: requestId),
};

/// Why a stream open was refused. Dart cannot read a QUIC reset code, so every
/// refusal the app acts on travels as [StreamRefused] followed by FIN.
enum StreamRefusedCode {
  /// The project core this stream would bind to has not finished starting
  /// (hazard J); the app should wait for the session-stream ready notice and
  /// retry, not park the open.
  notReady('NOT_READY'),

  /// Remote access is off, the project is unknown or unsafe, or the peer's
  /// project binding does not authorize this stream.
  notAllowed('NOT_ALLOWED'),

  /// A per-peer stream cap is already at its limit.
  capExceeded('CAP_EXCEEDED'),

  /// The open frame failed to parse or exceeded [kStreamOpenMaxBytes].
  invalid('INVALID');

  final String wireValue;

  const StreamRefusedCode(this.wireValue);

  static StreamRefusedCode? fromWire(String value) {
    for (final code in StreamRefusedCode.values) {
      if (code.wireValue == value) return code;
    }
    return null;
  }
}

class StreamRefused {
  final StreamRefusedCode code;
  final String message;

  const StreamRefused({required this.code, required this.message});

  Map<String, dynamic> toJson() => {
    'type': 'stream:refused',
    'code': code.wireValue,
    'message': message,
  };

  static StreamRefused? fromJson(Map<String, dynamic> json) {
    if (json['type'] != 'stream:refused') return null;
    if (!_onlyKeys(json, {'type', 'code', 'message'})) return null;
    final code = json['code'];
    final message = json['message'];
    if (code is! String || message is! String) return null;
    final parsed = StreamRefusedCode.fromWire(code);
    if (parsed == null) return null;
    return StreamRefused(code: parsed, message: message);
  }

  /// Decodes one stream record's bytes as a [StreamRefused]. Dart cannot read
  /// a QUIC reset code, so every refusal an app-side reader acts on arrives
  /// this way instead — any decode failure (bad UTF-8, bad JSON, not an
  /// object, wrong shape) is `null`, never a thrown exception.
  static StreamRefused? tryDecode(Uint8List record) {
    try {
      final decoded = jsonDecode(utf8.decode(record, allowMalformed: false));
      if (decoded is! Map<String, dynamic>) return null;
      return StreamRefused.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is StreamRefused &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);
}
