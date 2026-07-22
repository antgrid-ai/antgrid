import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'models/connection_state.dart';
import 'models/device_identity.dart';
import 'models/relay_license_error.dart';
import 'models/relay_message.dart';
import 'crypto_service.dart';
import 'frame.dart';
import 'relay_auth.dart';

/// One machine↔relay WebSocket for one phone identity. v3: authenticates with a
/// single signed `hello` frame (proof-of-possession over `buildHelloSigBody`),
/// the relay answers `welcome` (→ authenticated) or a typed `error`. There is
/// no register/challenge/response round trip and no per-project socket — a
/// single [MachineSession] multiplexes project streams over this one socket.
class RelayService {
  final CryptoService _crypto;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  DeviceIdentity? _identity;
  bool _intentionalDisconnect = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  String? _currentRelayUrl;
  String? _currentLicenseToken;
  int _epoch = 0;

  // Herd mitigation only, not a security control — plain Random per the
  // hardening spec (equal jitter on the scheduled reconnect delay).
  final Random _jitter = Random();

  /// Clock-skew self-heal (design §13.1): an `AUTH_FAILED` carrying `serverTime`
  /// yields an offset that is applied to the NEXT hello's `ts`. Applied at most
  /// once per distinct offset value; a second consecutive skew failure with the
  /// same offset surfaces normally (the reconnect keeps the already-adjusted
  /// `ts` rather than looping on the same correction).
  Duration _clockOffset = Duration.zero;
  int? _appliedSkewMs;

  final _stateController = StreamController<AppState>.broadcast();
  final _messageController = StreamController<IncomingRouteMessage>.broadcast();
  final _licenseErrorController =
      StreamController<RelayLicenseErrorCode>.broadcast();
  final _errorController = StreamController<ErrorMessage>.broadcast();
  final _peerPresenceController = StreamController<bool>.broadcast();
  final _pairApprovalController =
      StreamController<PairApprovalMessage>.broadcast();
  final _pairRejectedController =
      StreamController<PairRejectedMessage>.broadcast();

  AppState _currentState = const AppState();

  Stream<AppState> get stateStream => _stateController.stream;
  Stream<IncomingRouteMessage> get messageStream => _messageController.stream;

  /// Every typed relay `error` frame (design §3.3). The `retryable`/`ref` fields
  /// are the failure-signalling contract the Dart client cannot get from WS
  /// close codes; [MachineSession] and pairing classify failures off this.
  Stream<ErrorMessage> get errorStream => _errorController.stream;

  /// Peer-presence transitions derived from `peer-online`/`peer-offline`/
  /// `pair-connected`/`grant-revoked`. Drives [MachineSession]'s
  /// online-after-offline rekey trigger.
  Stream<bool> get peerPresenceStream => _peerPresenceController.stream;

  /// Inbound `pair-approval` frames (agent approved a phone's pair-request).
  /// Consumers verify the Ed25519 signature before trusting.
  Stream<PairApprovalMessage> get pairApprovalStream =>
      _pairApprovalController.stream;

  /// Inbound `pair-rejected` frames (pairing refused).
  Stream<PairRejectedMessage> get pairRejectedStream =>
      _pairRejectedController.stream;

  /// Fires when the relay rejects the `hello` with a license verdict (M4
  /// close-code 1008 codes). Terminal — the service marks the disconnect
  /// intentional so no auto-reconnect is attempted until re-activation. NOTE:
  /// `SUPERSEDED` is terminal-for-this-socket but is NOT a license error and
  /// never surfaces here (must not render as "re-activate").
  Stream<RelayLicenseErrorCode> get licenseErrorStream =>
      _licenseErrorController.stream;

  AppState get currentState => _currentState;

  RelayService({required CryptoService crypto}) : _crypto = crypto;

  void _setState(AppState state) {
    _currentState = state;
    _stateController.add(state);
  }

  /// Connect to a relay server and authenticate with a signed `hello`.
  ///
  /// [licenseToken] is REQUIRED in v3 — apps authenticate with their own account
  /// token (design §4.2). [epoch] is a per-device monotonic counter (the app
  /// owns storage; see design §6.3) used for connection-instance arbitration.
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
  }) async {
    _identity = identity;
    _currentRelayUrl = relayUrl;
    _currentLicenseToken = licenseToken;
    _epoch = epoch;
    _intentionalDisconnect = false;
    _reconnectAttempt = 0;
    await _doConnect(relayUrl, identity);
  }

  Future<void> _doConnect(String relayUrl, DeviceIdentity identity) async {
    // A manual connect() and a fired reconnect timer can both reach here, and a
    // second attempt must supersede the first. Tear down any prior
    // subscription/timer/channel up front and listen the channel via a LOCAL
    // (not the shared `_channel` field re-read after `await ready`); re-reading
    // `_channel` post-await let a concurrent attempt's channel be listened twice.
    _subscription?.cancel();
    _subscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final prevChannel = _channel;

    _setState(_currentState.copyWith(
      connectionState: RelayConnectionState.connecting,
    ));

    try {
      var wsUrl = relayUrl;
      if (wsUrl.startsWith('http://')) {
        wsUrl = 'ws://${wsUrl.substring(7)}';
      } else if (wsUrl.startsWith('https://')) {
        wsUrl = 'wss://${wsUrl.substring(8)}';
      } else if (!wsUrl.startsWith('ws://') && !wsUrl.startsWith('wss://')) {
        wsUrl = 'ws://$wsUrl';
      }
      if (!wsUrl.endsWith('/ws')) {
        wsUrl = wsUrl.endsWith('/') ? '${wsUrl}ws' : '$wsUrl/ws';
      }

      developer.log('connecting to relay $wsUrl', name: 'antgrid.relay');
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel = channel;
      await prevChannel?.sink.close();
      await channel.ready;

      // A newer `_doConnect` may have replaced `_channel` while we awaited.
      if (!identical(_channel, channel)) {
        await channel.sink.close();
        return;
      }

      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.authenticating,
      ));

      _subscription = channel.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (Object error) => _onDisconnected(error),
      );

      final hello = await _buildHello(wsUrl, identity);
      // Signing is async; a newer attempt may have superseded us meanwhile.
      if (!identical(_channel, channel)) {
        await channel.sink.close();
        return;
      }
      _send(hello);
    } catch (e, st) {
      developer.log(
        'relay connect failed for $relayUrl',
        name: 'antgrid.relay',
        error: e,
        stackTrace: st,
      );
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.disconnected,
        error: 'Connection failed: $e',
      ));
      _scheduleReconnect();
    }
  }

  Future<Map<String, dynamic>> _buildHello(
    String wsUrl,
    DeviceIdentity identity,
  ) async {
    final ts = DateTime.now().toUtc().add(_clockOffset).toIso8601String();
    final nonceBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => _jitter.nextInt(256)),
    );
    final nonce = base64.encode(nonceBytes);
    final publicKey = base64.encode(identity.ed25519PublicKey);
    final relayHost = normalizeRelayHost(wsUrl);
    final licenseToken = _currentLicenseToken ?? '';
    final body = buildHelloSigBody(
      relayHost: relayHost,
      deviceType: 'app',
      deviceId: identity.deviceId,
      publicKey: publicKey,
      epoch: _epoch,
      licenseToken: licenseToken,
      ts: ts,
      nonce: nonce,
    );
    final sig = base64.encode(await _crypto.ed25519Sign(
      body,
      identity.ed25519PrivateKey,
      identity.ed25519PublicKey,
    ));
    return HelloMessage(
      deviceType: 'app',
      deviceId: identity.deviceId,
      name: identity.name,
      publicKey: publicKey,
      epoch: _epoch,
      licenseToken: licenseToken,
      ts: ts,
      nonce: nonce,
      sig: sig,
    ).toJson();
  }

  void _onMessage(dynamic data) {
    if (data is String) {
      _handleText(data);
    } else if (data is Uint8List) {
      _handleBinary(data);
    } else if (data is List<int>) {
      _handleBinary(Uint8List.fromList(data));
    }
  }

  /// Test-only seam: feed a raw relay frame through the same path a socket
  /// message takes, so tests can drive control-message state transitions
  /// without standing up a live WebSocket. Not part of the supported API.
  void debugHandleFrame(dynamic frame) => _onMessage(frame);

  void _handleText(String data) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final msg = parseRelayMessage(json);
    if (msg == null) return;

    if (msg is WelcomeMessage) {
      // Authenticated: reset backoff (only proven auth progress does this).
      _reconnectAttempt = 0;
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.authenticated,
      ));
    } else if (msg is ErrorMessage) {
      _handleError(msg);
    } else if (msg is PairConnectedMessage) {
      _peerPresenceController.add(true);
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.paired,
        peerDeviceId: msg.peerId,
        peerName: msg.peerName,
        connectedAt: _currentState.connectedAt ?? DateTime.now(),
      ));
    } else if (msg is GrantRevokedMessage) {
      _peerPresenceController.add(false);
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.authenticated,
        peerDeviceId: null,
        peerName: null,
      ));
    } else if (msg is PeerOnlineMessage) {
      _peerPresenceController.add(true);
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.paired,
      ));
    } else if (msg is PeerOfflineMessage) {
      // v3: the machine's socket dropped but ours stays open (no cascade close).
      _peerPresenceController.add(false);
      _setState(_currentState.copyWith(
        error: 'Peer offline',
      ));
    } else if (msg is PairApprovalMessage) {
      _pairApprovalController.add(msg);
    } else if (msg is PairRejectedMessage) {
      _pairRejectedController.add(msg);
    }
  }

  void _handleError(ErrorMessage msg) {
    if (!_errorController.isClosed) _errorController.add(msg);

    // Clock-skew AUTH_FAILED (retryable): record the offset and let the socket
    // close → the scheduled reconnect re-sends the hello with the adjusted `ts`.
    if (msg.code == 'AUTH_FAILED' && msg.serverTime != null) {
      _maybeApplySkew(msg.serverTime!);
      return;
    }

    final licenseCode = RelayLicenseErrorCode.fromWire(msg.code);
    if (licenseCode != null) {
      _intentionalDisconnect = true;
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.disconnected,
        errorCode: msg.code,
        error: '${msg.code}: ${msg.message}',
      ));
      _licenseErrorController.add(licenseCode);
      _channel?.sink.close();
      return;
    }

    // Terminal-vs-retryable is the error contract (design §3.3): a
    // `retryable:false` frame precedes an intentional close, so stop
    // reconnecting. SUPERSEDED/PROTOCOL_VIOLATION/NOT_AUTHORIZED land here —
    // none is a license error, so `licenseErrorStream` stays silent.
    if (!msg.retryable) {
      _intentionalDisconnect = true;
      _setState(_currentState.copyWith(
        connectionState: RelayConnectionState.disconnected,
        errorCode: msg.code,
        error: '${msg.code}: ${msg.message}',
      ));
      _channel?.sink.close();
      return;
    }

    // Retryable application error (pairing / stream / routing): socket stays
    // open. Revert an in-flight pairing to authenticated so the flow can retry.
    final revertState =
        _currentState.connectionState == RelayConnectionState.pairing
            ? RelayConnectionState.authenticated
            : null;
    _setState(_currentState.copyWith(
      connectionState: revertState,
      errorCode: msg.code,
      error: '${msg.code}: ${msg.message}',
    ));
  }

  void _maybeApplySkew(String serverTime) {
    final server = DateTime.tryParse(serverTime);
    if (server == null) return;
    final offset = server.toUtc().difference(DateTime.now().toUtc());
    final ms = offset.inMilliseconds;
    if (_appliedSkewMs == ms) return; // already corrected by this amount
    _appliedSkewMs = ms;
    _clockOffset = offset;
  }

  void _handleBinary(Uint8List data) {
    ({Map<String, dynamic> header, Uint8List payload, FrameKind kind}) decoded;
    try {
      decoded = decodeRouteFrame(data);
    } on FrameException catch (_) {
      return;
    }
    final msg = IncomingRouteMessage.fromFrameHeader(
      decoded.header,
      decoded.payload,
      decoded.kind,
    );
    if (msg == null) return;
    _messageController.add(msg);
  }

  void _onDisconnected([Object? error]) {
    if (error != null) {
      developer.log(
        'relay socket closed with error',
        name: 'antgrid.relay',
        error: error,
      );
    }
    _cleanup();
    // A socket drop makes the peer unreachable regardless of the grant — feed
    // presence=false so consumers (ControlPlaneClient advert, MachineSession
    // rekey arming) react without waiting for a peer-offline frame that a
    // network drop never delivers.
    if (!_peerPresenceController.isClosed) _peerPresenceController.add(false);
    _setState(_currentState.copyWith(
      connectionState: RelayConnectionState.disconnected,
      clearConnectedAt: true,
      // Carry forward a deliberate errorCode across the close it caused (a
      // terminal error sets errorCode then closes → onDone fires here, and
      // copyWith does NOT preserve fields). A fresh _doConnect resets it.
      errorCode: _currentState.errorCode,
      error: error != null ? 'Socket error: $error' : null,
    ));
    if (!_intentionalDisconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect ||
        _currentRelayUrl == null ||
        _identity == null) {
      return;
    }

    final delayMs = _delayMsFor(_reconnectAttempt);
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_intentionalDisconnect &&
          _currentRelayUrl != null &&
          _identity != null) {
        _doConnect(_currentRelayUrl!, _identity!);
      }
    });
  }

  int _backoffMs(int attempt) {
    // Clamp the SHIFT at both ends: `1 << negative` throws and a large shift
    // overflows to a zero-delay reconnect storm (both reachable from a public
    // seam). 2^5 * 1000 = 32000, then capped to 30000.
    final shift = attempt.clamp(0, 5);
    final ms = 1000 * (1 << shift);
    return ms > 30000 ? 30000 : ms;
  }

  int _delayMsFor(int attempt) {
    final backoff = _backoffMs(attempt);
    // Equal jitter applied to the SCHEDULED delay only — uniform in
    // [backoff/2, backoff]. `backoff` itself stays deterministic.
    final half = backoff ~/ 2;
    return half + _jitter.nextInt(backoff - half + 1);
  }

  /// Test seam: the jittered reconnect delay that attempt [attempt] would
  /// schedule. Same code path as [_scheduleReconnect].
  int debugBackoffMs(int attempt) => _delayMsFor(attempt);

  /// Send a pair-request to the relay. Consumers should listen on
  /// [pairApprovalStream] / [pairRejectedStream] (or [errorStream]) for the
  /// result.
  void requestPair({
    required String agentDeviceId,
    required String phonePubkey,
    required String phoneDeviceId,
    required String nonce,
    required String requestedAt,
    required int deadline,
    required String phoneSignature,
    String? pairCode,
    String? label,
    String? accountDevicePubkey,
    String? accountMembershipSig,
  }) {
    _setState(_currentState.copyWith(
      connectionState: RelayConnectionState.pairing,
    ));
    _send(PairRequestMessage(
      agentDeviceId: agentDeviceId,
      phonePubkey: phonePubkey,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      requestedAt: requestedAt,
      deadline: deadline,
      phoneSignature: phoneSignature,
      pairCode: pairCode,
      label: label,
      accountDevicePubkey: accountDevicePubkey,
      accountMembershipSig: accountMembershipSig,
    ).toJson());
  }

  /// Send a routed frame to the machine peer. [kind] defaults to `sealed`
  /// (encrypted app traffic); the E2E handshake sends its plaintext
  /// client-hello as `handshake`.
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    if (_channel?.sink == null) return;
    try {
      final frame = encodeRouteFrame(
        {'type': 'message', 'to': to, 'channel': channel},
        payload,
        kind,
      );
      _channel!.sink.add(frame);
    } on FrameException catch (_) {
      // Dropped — caller can retry with a smaller payload.
    }
  }

  /// Sever the grant with [peerDeviceId] (v3 `grant-revoke`, replaces `unpair`).
  void grantRevoke(String peerDeviceId) {
    _send(GrantRevokeMessage(peerDeviceId: peerDeviceId).toJson());
    _setState(_currentState.copyWith(
      connectionState: RelayConnectionState.authenticated,
    ));
  }

  /// Sever the grant with the currently-paired peer, if any.
  void unpair() {
    final peer = _currentState.peerDeviceId;
    if (peer != null) {
      _send(GrantRevokeMessage(peerDeviceId: peer).toJson());
    }
    _setState(_currentState.copyWith(
      connectionState: RelayConnectionState.authenticated,
    ));
  }

  /// Disconnect intentionally (no reconnect).
  void disconnect() {
    _intentionalDisconnect = true;
    _cleanup();
    _channel?.sink.close();
    _channel = null;
    _setState(const AppState());
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void _cleanup() {
    _subscription?.cancel();
    _subscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _messageController.close();
    _licenseErrorController.close();
    _errorController.close();
    _peerPresenceController.close();
    _pairApprovalController.close();
    _pairRejectedController.close();
  }
}
