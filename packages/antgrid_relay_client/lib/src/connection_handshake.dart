import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'frame.dart';
import 'machine_session.dart';
import 'peer_link.dart';

/// Severity for [HandshakeLogger]. Only two levels exist because only two
/// things are worth reporting: a rejected frame (debug — routine under an
/// active attacker or a stale pin) and a driver failure (error).
enum HandshakeLogLevel { debug, error }

/// Diagnostic sink for one handshake attempt. Injected rather than hard-wired
/// so this driver stays Flutter-free: the app forwards to `AbLog` (a failed
/// handshake is the first thing read out of `app.log` when a connection won't
/// establish), the eval CLI forwards to its stdout event stream. Null = silent.
typedef HandshakeLogger =
    void Function(
      HandshakeLogLevel level,
      String message, {
      Map<String, Object?>? fields,
    });

/// The app's hello literal. Byte-identical, key for key, to the old
/// `AppReadyMessage.capabilities` — the bridge strips unknown keys, so a
/// newer app capability never fails an older bridge.
///
/// MUST stay in lockstep with `SessionHelloCapabilities`
/// (`bridge/src/protocol.ts`). `sessionBusCarrier` is deliberately absent: it
/// is a loopback-hello key only (`local_transport.dart`), never sent on the
/// native path.
const Map<String, bool> kSessionHelloCapabilities = {
  'checkoutRouting': true,
  'pullsTree': true,
  'terminalFramesV1': true,
};

/// Runs ONE plaintext hello to `session:established` over a single [PeerLink] socket.
/// QUIC/TLS between the two lease-authorized endpoints is the confidentiality
/// layer, so the hello carries no crypto of its own: a phone-generated
/// `attemptId` correlates the exchange, and there is no retransmit — a
/// connection carries at most one hello, and a hello that times out means the
/// caller closes the whole link rather than retrying on it. All per-run state
/// is instance-local.
///
/// Lives in this package, not in the app, so the app and the eval CLI drive the
/// SAME driver: a second copy is what let the eval client sit on a stale
/// protocol conversation for a full protocol revision while its scenarios
/// stayed skipped.
class ConnectionHandshake {
  /// How long one attempt waits for the bridge's `session:established`. Sized for a
  /// phone on a real network; a caller that drives its own retry loop wants a
  /// shorter one, so that the loop's worst case stays inside its budget rather
  /// than being set by this single figure.
  static const Duration defaultAttemptTimeout = Duration(seconds: 10);

  ConnectionHandshake({
    required PeerLink relay,
    HandshakeLogger? logger,
    Duration attemptTimeout = defaultAttemptTimeout,
  }) : _relay = relay,
       _logger = logger,
       _attemptTimeout = attemptTimeout;

  final PeerLink _relay;
  final HandshakeLogger? _logger;
  final Duration _attemptTimeout;

  bool _cancelled = false;
  StreamSubscription<IncomingSessionRecord>? _messageSub;

  void cancel() {
    _cancelled = true;
    _messageSub?.cancel();
    _messageSub = null;
  }

  /// Runs one hello attempt (fresh `attemptId`). Resolves true once the
  /// bridge's `established {attemptId}` arrives, false on timeout,
  /// cancellation, or a link that will not accept the hello.
  Future<bool> run() async {
    if (_cancelled) return false;

    final attemptId = _secureNonceB64();
    var finished = false;
    bool active() => !finished && !_cancelled && _relay.isDispatchAllowed;
    final established = Completer<bool>();

    // Subscribe before sending: the bridge may answer before the send call
    // itself returns.
    final sub = _relay.messageStream.listen((msg) {
      if (!active()) return;
      Map<String, dynamic>? json;
      try {
        json = jsonDecode(utf8.decode(msg.payload)) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      if (json['type'] != kSessionEstablished || json['attemptId'] != attemptId) {
        return;
      }
      if (!established.isCompleted) established.complete(true);
    });
    _messageSub = sub;

    try {
      final hello = <String, dynamic>{
        'type': kSessionHello,
        'attemptId': attemptId,
        'capabilities': kSessionHelloCapabilities,
      };
      final outcome = await _relay.sendRecord(
        Uint8List.fromList(utf8.encode(jsonEncode(hello))),
      );
      if (outcome != PeerSendOutcome.accepted) return false;
      if (!active()) return false;
      return await established.future.timeout(_attemptTimeout);
    } on TimeoutException {
      return false;
    } catch (e, st) {
      _log(
        HandshakeLogLevel.error,
        'run error',
        fields: {'error': '$e', 'stack': '$st'},
      );
      return false;
    } finally {
      finished = true;
      if (identical(_messageSub, sub)) _messageSub = null;
      await sub.cancel();
    }
  }

  void _log(
    HandshakeLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  }) => _logger?.call(level, message, fields: fields);
}

/// A fresh, base64-encoded 16-byte nonce, used as the hello's `attemptId`.
String _secureNonceB64() {
  final r = Random.secure();
  return base64.encode(List<int>.generate(16, (_) => r.nextInt(256)));
}

/// The [SessionHandshaker] a `MachineSession` drives. Each [perform] runs a
/// FRESH [ConnectionHandshake] (new `attemptId`) on the live socket — there is
/// never a second hello on the same link, so a failed attempt's caller closes
/// the link rather than reusing this driver on it.
///
/// "App" is the ROLE, not the Flutter app: every phone-side client (the app,
/// the eval CLI) is the initiating half of the hello.
class AppSessionHandshaker implements SessionHandshaker {
  AppSessionHandshaker({
    required PeerLink relay,
    HandshakeLogger? logger,
    Duration attemptTimeout = ConnectionHandshake.defaultAttemptTimeout,
  }) : _relay = relay,
       _logger = logger,
       _attemptTimeout = attemptTimeout;

  final PeerLink _relay;
  final HandshakeLogger? _logger;
  final Duration _attemptTimeout;

  ConnectionHandshake? _current;
  bool _aborted = false;

  @override
  Future<bool> perform() async {
    if (_aborted) return false;
    final hs = _current = ConnectionHandshake(
      relay: _relay,
      logger: _logger,
      attemptTimeout: _attemptTimeout,
    );
    try {
      return await hs.run();
    } finally {
      if (identical(_current, hs)) _current = null;
    }
  }

  @override
  void abort() {
    _aborted = true;
    _current?.cancel();
    _current = null;
  }
}
