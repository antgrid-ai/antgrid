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

class PingMessage {
  const PingMessage();

  Map<String, dynamic> toJson() => {'type': 'ping'};
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

class PongMessage {
  const PongMessage();

  static PongMessage? fromJson(Map<String, dynamic> json) {
    return const PongMessage();
  }
}

class ErrorMessage {
  final String code;
  final String message;

  /// The error contract is law: every error states whether the client may
  /// retry the same action unchanged. Terminal-vs-retryable classification
  /// lives on the wire, not in per-client code lists.
  final bool retryable;

  /// Server clock, present on clock-skew AUTH_FAILED only.
  final String? serverTime;

  const ErrorMessage({
    required this.code,
    required this.message,
    required this.retryable,
    this.serverTime,
  });

  static ErrorMessage? fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    final message = json['message'];
    final retryable = json['retryable'];
    if (code is! String || message is! String || retryable is! bool) {
      return null;
    }
    final serverTime = json['serverTime'];
    return ErrorMessage(
      code: code,
      message: message,
      retryable: retryable,
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

class PeerPolicyChangedMessage {
  const PeerPolicyChangedMessage(this.generation);
  final BigInt generation;
  static PeerPolicyChangedMessage? fromJson(Map<String, dynamic> json) {
    final value = json['generation'];
    if (value is! String || !RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(value))
      return null;
    final generation = BigInt.parse(value);
    if (generation > BigInt.parse('9223372036854775807')) return null;
    return PeerPolicyChangedMessage(generation);
  }
}

/// Parses a relay message JSON map into the appropriate typed message.
/// Returns null if the type is unrecognized or the message is malformed.
///
/// Returning null rather than throwing preserves forward compatibility with
/// control messages this client does not yet understand.
Object? parseRelayMessage(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  switch (type) {
    case 'welcome':
      return WelcomeMessage.fromJson(json);
    case 'pong':
      return PongMessage.fromJson(json);
    case 'error':
      return ErrorMessage.fromJson(json);
    case 'peer-policy-changed':
      return PeerPolicyChangedMessage.fromJson(json);
    case 'peer-online':
      return PeerOnlineMessage.fromJson(json);
    case 'peer-offline':
      return PeerOfflineMessage.fromJson(json);
    default:
      return null;
  }
}
