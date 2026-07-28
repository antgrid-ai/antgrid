import 'dart:typed_data';

import '../frame.dart';

// --- Client → Relay ---

/// First (and only) auth frame: proof-of-possession over `buildHelloSigBody`
/// (see relay_auth.dart). Replaces the v2 register/challenge/challenge-response
/// round trips — the relay verifies and answers `welcome` or a typed error.
class HelloMessage {
  final String deviceType; // 'agent' | 'app'
  final String deviceId;
  final String name;
  final String publicKey; // base64 Ed25519 public key
  final int epoch; // connection-instance arbitration: highest epoch wins
  final String licenseToken; // REQUIRED for both device types
  final String ts; // ISO-8601
  final String nonce; // base64, ≥16 random bytes
  final String sig; // base64 Ed25519 over buildHelloSigBody

  const HelloMessage({
    required this.deviceType,
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.epoch,
    required this.licenseToken,
    required this.ts,
    required this.nonce,
    required this.sig,
  });

  Map<String, dynamic> toJson() => {
    'type': 'hello',
    'protocolVersion': 3,
    'deviceType': deviceType,
    'deviceId': deviceId,
    'name': name,
    'publicKey': publicKey,
    'epoch': epoch,
    'licenseToken': licenseToken,
    'ts': ts,
    'nonce': nonce,
    'sig': sig,
  };
}

class StreamOpenMessage {
  final String streamId;

  const StreamOpenMessage({required this.streamId});

  Map<String, dynamic> toJson() => {
    'type': 'stream-open',
    'streamId': streamId,
  };
}

class StreamCloseMessage {
  final String streamId;

  const StreamCloseMessage({required this.streamId});

  Map<String, dynamic> toJson() => {
    'type': 'stream-close',
    'streamId': streamId,
  };
}

// --- Relay → Client ---

/// Terminal success frame for the `hello` handshake (replaces v2
/// `authenticated`). Carries the relay-echoed deviceId, the arbitration epoch,
/// and the server clock for skew detection.
class WelcomeMessage {
  final String deviceId;
  final int epoch;
  final String serverTime;

  const WelcomeMessage({
    required this.deviceId,
    required this.epoch,
    required this.serverTime,
  });

  static WelcomeMessage? fromJson(Map<String, dynamic> json) {
    final deviceId = json['deviceId'];
    final epoch = json['epoch'];
    final serverTime = json['serverTime'];
    if (deviceId is! String || epoch is! int || serverTime is! String) {
      return null;
    }
    return WelcomeMessage(
      deviceId: deviceId,
      epoch: epoch,
      serverTime: serverTime,
    );
  }
}

class StreamOpenedMessage {
  final String streamId;

  const StreamOpenedMessage({required this.streamId});

  static StreamOpenedMessage? fromJson(Map<String, dynamic> json) {
    final streamId = json['streamId'];
    if (streamId is! String) return null;
    return StreamOpenedMessage(streamId: streamId);
  }
}

class StreamClosedMessage {
  final String streamId;

  const StreamClosedMessage({required this.streamId});

  static StreamClosedMessage? fromJson(Map<String, dynamic> json) {
    final streamId = json['streamId'];
    if (streamId is! String) return null;
    return StreamClosedMessage(streamId: streamId);
  }
}

class ErrorMessage {
  final String code;
  final String message;

  /// The error contract is law: every error states whether the client may
  /// retry the same action unchanged. Terminal-vs-retryable classification
  /// lives on the wire, not in per-client code lists.
  final bool retryable;

  /// Echoes the streamId the error refers to.
  final String? ref;

  /// Server clock, present on clock-skew AUTH_FAILED only.
  final String? serverTime;

  const ErrorMessage({
    required this.code,
    required this.message,
    required this.retryable,
    this.ref,
    this.serverTime,
  });

  static ErrorMessage? fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    final message = json['message'];
    final retryable = json['retryable'];
    if (code is! String || message is! String || retryable is! bool) {
      return null;
    }
    final ref = json['ref'];
    final serverTime = json['serverTime'];
    return ErrorMessage(
      code: code,
      message: message,
      retryable: retryable,
      ref: ref is String ? ref : null,
      serverTime: serverTime is String ? serverTime : null,
    );
  }
}

class PeerOnlineMessage {
  final String peerId;

  const PeerOnlineMessage({required this.peerId});

  static PeerOnlineMessage? fromJson(Map<String, dynamic> json) {
    final peerId = json['peerId'];
    if (peerId is! String) return null;
    return PeerOnlineMessage(peerId: peerId);
  }
}

class PeerOfflineMessage {
  final String peerId;

  const PeerOfflineMessage({required this.peerId});

  static PeerOfflineMessage? fromJson(Map<String, dynamic> json) {
    final peerId = json['peerId'];
    if (peerId is! String) return null;
    return PeerOfflineMessage(peerId: peerId);
  }
}

class IncomingRouteMessage {
  final String from;
  final String channel;
  final Uint8List payload;
  final int? ts;

  /// The route-frame kind byte (v3 §3.1). `handshake` (0x01) carries plaintext
  /// client/agent-hello; `sealed` (0x00) carries every ciphertext payload
  /// (session frames and stream traffic). Endpoints dispatch on this instead of
  /// try-parsing the payload as plaintext JSON.
  final FrameKind kind;

  const IncomingRouteMessage({
    required this.from,
    required this.channel,
    required this.payload,
    required this.kind,
    this.ts,
  });

  /// Build from a decoded frame header + payload bytes + kind byte.
  static IncomingRouteMessage? fromFrameHeader(
    Map<String, dynamic> header,
    Uint8List payload,
    FrameKind kind,
  ) {
    final from = header['from'];
    final channel = header['channel'];
    if (from is! String || channel is! String) return null;
    return IncomingRouteMessage(
      from: from,
      channel: channel,
      payload: payload,
      kind: kind,
      ts: header['ts'] as int?,
    );
  }
}

/// Parses a relay message JSON map into the appropriate typed message.
/// Returns null if the type is unrecognized or the message is malformed.
///
/// Returning null (rather than throwing) is the tolerance contract: an
/// un-upgraded relay still sending the deleted pairing frames — `pair-connected`,
/// `grant-revoked`, `pair-*` — must be ignorable by a v3 app, not fatal to its
/// socket.
Object? parseRelayMessage(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  switch (type) {
    case 'welcome':
      return WelcomeMessage.fromJson(json);
    case 'stream-opened':
      return StreamOpenedMessage.fromJson(json);
    case 'stream-closed':
      return StreamClosedMessage.fromJson(json);
    case 'error':
      return ErrorMessage.fromJson(json);
    case 'peer-online':
      return PeerOnlineMessage.fromJson(json);
    case 'peer-offline':
      return PeerOfflineMessage.fromJson(json);
    default:
      return null;
  }
}
