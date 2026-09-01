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

/// Why a single [RelayService.connect] attempt did not reach `welcome`.
///
/// Carries the relay's own error contract ([code]/[retryable]) so the caller —
/// the one component that owns retry — can classify without reading WS close
/// codes, which the Dart client cannot see.
class RelayConnectException implements Exception {
  RelayConnectException({this.code, required this.retryable, this.message});

  final String? code;
  final bool retryable;
  final String? message;

  @override
  String toString() =>
      'RelayConnectException(${code ?? 'CLOSED'}, retryable: $retryable)'
      '${message == null ? '' : ': $message'}';
}

enum RelayLogLevel { debug, info, warn, error }

typedef RelayLogger =
    void Function(
      RelayLogLevel level,
      String message, {
      Map<String, Object?>? fields,
    });

/// One machine↔relay WebSocket for one phone identity. v3: authenticates with a
/// single signed `hello` frame (proof-of-possession over `buildHelloSigBody`),
/// the relay answers `welcome` (→ authenticated) or a typed `error`. There is
/// no register/challenge/response round trip and no per-project socket — a
/// single [MachineSession] multiplexes project streams over this one socket.
///
/// ONE attempt per [connect], never a retry: redial timing, backoff and give-up
/// belong to the app's connection supervisor, so there is exactly one component
/// deciding when to try again.
class RelayService {
  final CryptoService _crypto;
  final RelayLogger? _logger;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  int _epoch = 0;

  /// Resolves on `welcome`, rejects on any close/terminal error before it.
  Completer<void>? _connect;
  Timer? _connectTimeout;
  Duration _connectTimeoutDuration = const Duration(seconds: 15);
  Duration _heartbeatInterval = const Duration(seconds: 25);
  Timer? _heartbeatTimer;
  DateTime? _socketOpenedAt;
  DateTime? _lastInboundAt;
  DateTime? _probeSentAt;
  String? _relaySlotId;

  /// The bare machine `deviceUuid` this socket serves. The relay fans
  /// `peer-online`/`peer-offline` out account-wide (all of a user's machines —
  /// `presencePeers` in `relay/src/server.ts`), so this scopes which presence
  /// frames may drive THIS connection's state.
  String? _machineDeviceId;

  /// Hello-nonce source only — not a security control (the relay's replay cache
  /// is keyed on `(deviceId, nonce)`, and a signed hello is what authenticates).
  final Random _rng = Random();

  /// Clock-skew self-heal: an `AUTH_FAILED` carrying `serverTime`
  /// yields an offset that is applied to the NEXT hello's `ts`. Applied at most
  /// once per distinct offset value; a second consecutive skew failure with the
  /// same offset surfaces normally (the reconnect keeps the already-adjusted
  /// `ts` rather than looping on the same correction).
  Duration _clockOffset = Duration.zero;
  int? _appliedSkewMs;

  final _stateController = StreamController<AppState>.broadcast();
  final _messageController = StreamController<IncomingRouteMessage>.broadcast();
  final _errorController = StreamController<ErrorMessage>.broadcast();
  final _peerPresenceController = StreamController<bool>.broadcast();

  AppState _currentState = const AppState();

  Stream<AppState> get stateStream => _stateController.stream;
  Stream<IncomingRouteMessage> get messageStream => _messageController.stream;

  /// Every typed relay `error` frame. The `retryable`/`ref` fields
  /// are the failure-signalling contract the Dart client cannot get from WS
  /// close codes; [MachineSession] and the connection supervisor classify
  /// failures off this.
  Stream<ErrorMessage> get errorStream => _errorController.stream;

  /// Peer-presence transitions derived from `peer-online`/`peer-offline` for
  /// THIS machine (and a socket drop). Drives [MachineSession]'s
  /// online-after-offline rekey trigger, and is the ONLY agent-presence signal —
  /// the connection state tracks the socket, not the peer.
  Stream<bool> get peerPresenceStream => _peerPresenceController.stream;

  AppState get currentState => _currentState;

  RelayService({required CryptoService crypto, RelayLogger? logger})
    : _crypto = crypto,
      _logger = logger;

  /// A dial outlives this object: `connect()` deliberately does not await
  /// `_doConnect`, so a socket that fails (or a `channel.ready` that rejects
  /// because `dispose()` just closed the sink) lands here after the controllers
  /// are closed. That emit throws `Bad state` inside an unawaited future, where
  /// no caller can catch it — keep the last state, drop the notification.
  void _setState(AppState state) {
    _currentState = state;
    if (_stateController.isClosed) return;
    _stateController.add(state);
  }

  /// ONE dial attempt: opens the socket, sends the signed `hello`, and
  /// completes when the relay answers `welcome`. Throws
  /// [RelayConnectException] if the socket closes or the relay rejects us
  /// first. Never retries — see the class doc.
  ///
  /// The returned future must not resolve before [currentState] reads
  /// `authenticated`, because the caller re-reads that flag the instant this
  /// resolves and scores a "successful" dial onto a still-unauthenticated
  /// socket as a failure.
  ///
  /// [licenseToken] is REQUIRED in v3 — apps authenticate with their own account
  /// token. [epoch] is a per-device monotonic counter (the app
  /// owns storage) used for connection-instance arbitration.
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
    String? machineDeviceId,
  }) async {
    // dispose() closed the controllers, so a dial from here would open a
    // REAL socket whose every event is silently dropped — and whose fresh
    // epoch could supersede the machine's live replacement connection at
    // the relay. Fail the attempt loudly instead; non-retryable because the
    // owner is gone and no redial can ever succeed on this instance.
    if (_stateController.isClosed) {
      throw RelayConnectException(
        retryable: false,
        message: 'connect() after dispose()',
      );
    }
    _resetHeartbeat();
    _epoch = epoch;
    _machineDeviceId = machineDeviceId;
    _relaySlotId = identity.deviceId;
    // A superseded in-flight attempt must not leave its caller hanging.
    _failConnect(
      RelayConnectException(
        retryable: true,
        message: 'superseded by a new dial',
      ),
    );
    final attempt = _connect = Completer<void>();
    // The caller only attaches to this future once _doConnect below returns, so
    // a failure landing in that window (a disconnect() while the socket is
    // still opening) would have no listener and surface as an unhandled async
    // error. Pre-registering a swallowing one is harmless: the real await still
    // receives the error.
    attempt.future.ignore();
    // Without this the socket can open, the hello go out, and the relay simply
    // never answer — a dial that hangs forever stalls the whole ladder. The
    // relay's own hello-or-die timer is 10s, so this only ever fires when the
    // answer is lost, not when it is slow.
    _connectTimeout = Timer(_connectTimeoutDuration, () {
      _failConnect(
        RelayConnectException(
          code: 'HELLO_TIMEOUT',
          retryable: true,
          message: 'no welcome within 15s',
        ),
      );
      _channel?.sink.close();
    });
    // Not awaited, so the timer above is the ONLY thing that bounds a dial. An
    // await here would let anything slow inside `_doConnect` outlive the
    // watchdog: the timer would fail `attempt` while this method had not yet
    // returned its future, so the caller would still be waiting on a step that
    // can never settle — and the supervisor's single-flight `evaluate()` wedges
    // permanently, never scheduling another attempt. `_doConnect` reports its
    // own failures through `_failConnect`.
    unawaited(_doConnect(relayUrl, identity, licenseToken));
    return attempt.future;
  }

  Future<void> _doConnect(
    String relayUrl,
    DeviceIdentity identity,
    String licenseToken,
  ) async {
    // Two connect() calls can overlap (a redial racing a late close), and the
    // second must supersede the first. Tear down any prior subscription/channel
    // up front and listen the channel via a LOCAL (not the shared `_channel`
    // field re-read after `await ready`); re-reading `_channel` post-await let a
    // concurrent attempt's channel be listened twice.
    _subscription?.cancel();
    _subscription = null;
    final prevChannel = _channel;

    _setState(
      _currentState.copyWith(connectionState: RelayConnectionState.connecting),
    );

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
      _socketOpenedAt = DateTime.now().toUtc();
      _log(
        RelayLogLevel.info,
        'relay socket connecting',
        fields: {'machineSlot': _relaySlotId},
      );
      // Deliberately NOT awaited: a relay killed without a close handshake
      // leaves `sink.close()` waiting for a FIN that never arrives, and this
      // dial would then open its socket, send nothing, and hang — the relay
      // closes it on the 10s hello timer while the ladder waits forever.
      // Retiring the old channel is housekeeping; nothing below reads it.
      unawaited(prevChannel?.sink.close() ?? Future<void>.value());
      await channel.ready;

      // A newer `_doConnect` may have replaced `_channel` while we awaited.
      if (!identical(_channel, channel)) {
        await channel.sink.close();
        return;
      }

      _setState(
        _currentState.copyWith(
          connectionState: RelayConnectionState.authenticating,
        ),
      );

      _subscription = channel.stream.listen(
        (data) {
          if (identical(_channel, channel)) _onMessage(data);
        },
        onDone: () {
          if (identical(_channel, channel)) _onDisconnected();
        },
        onError: (Object error) {
          if (identical(_channel, channel)) _onDisconnected(error);
        },
      );

      final hello = await _buildHello(wsUrl, identity, licenseToken);
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
      _setState(
        _currentState.copyWith(
          connectionState: RelayConnectionState.disconnected,
          error: 'Connection failed: $e',
        ),
      );
      _failConnect(
        RelayConnectException(retryable: true, message: 'connect failed: $e'),
      );
    }
  }

  Future<Map<String, dynamic>> _buildHello(
    String wsUrl,
    DeviceIdentity identity,
    String licenseToken,
  ) async {
    final ts = DateTime.now().toUtc().add(_clockOffset).toIso8601String();
    final nonceBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => _rng.nextInt(256)),
    );
    final nonce = base64.encode(nonceBytes);
    final publicKey = base64.encode(identity.ed25519PublicKey);
    final relayHost = normalizeRelayHost(wsUrl);
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
    final sig = base64.encode(
      await _crypto.ed25519Sign(
        body,
        identity.ed25519PrivateKey,
        identity.ed25519PublicKey,
      ),
    );
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

  /// Test-only seam: set the machine deviceId this socket serves without
  /// driving a real `connect()`/handshake. Not part of the supported API.
  void debugSetMachineDeviceId(String? machineDeviceId) =>
      _machineDeviceId = machineDeviceId;

  /// Test-only seam: shorten the dial watchdog so a test can assert the bound
  /// without waiting out the real 15s. Not part of the supported API.
  void debugSetConnectTimeout(Duration timeout) =>
      _connectTimeoutDuration = timeout;

  /// Test-only seam: shorten the heartbeat without changing production timing.
  void debugSetHeartbeatInterval(Duration interval) =>
      _heartbeatInterval = interval;

  /// Test-only seam: model an OS-frozen periodic timer before a resume event.
  void debugPauseHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Test-only seam: install the channel a subsequent `connect()` will see as
  /// its `prevChannel`, so a test can stand in a socket whose close never
  /// completes. Not part of the supported API.
  void debugSetChannel(WebSocketChannel channel) => _channel = channel;

  void _handleText(String data) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final msg = parseRelayMessage(json);
    if (msg == null) return;

    _markInboundHealthy();

    if (msg is WelcomeMessage) {
      // State first, then the completer: whoever awaits connect() re-reads the
      // connection state the instant it resolves.
      _setState(
        _currentState.copyWith(
          connectionState: RelayConnectionState.authenticated,
          connectedAt: DateTime.now().toUtc(),
        ),
      );
      if (_channel != null) _startHeartbeat();
      _log(
        RelayLogLevel.info,
        'relay socket authenticated',
        fields: {'machineSlot': _relaySlotId},
      );
      _completeConnect();
    } else if (msg is ErrorMessage) {
      _handleError(msg);
    } else if (msg is PeerOnlineMessage) {
      if (!_isThisMachine(msg.peerId)) return;
      // Presence only — the connection state describes OUR socket, and the agent
      // showing up does not change it.
      if (!_peerPresenceController.isClosed) _peerPresenceController.add(true);
    } else if (msg is PeerOfflineMessage) {
      if (!_isThisMachine(msg.peerId)) return;
      // v3: the machine's socket dropped but ours stays open (no cascade close).
      if (!_peerPresenceController.isClosed) _peerPresenceController.add(false);
      _setState(_currentState.copyWith(error: 'Peer offline'));
    }
  }

  /// The relay's presence fan-out is account-wide; only the machine this
  /// socket serves may drive this connection's presence state. Fail CLOSED when
  /// the machine id is unset (no live connect() supplied one): attribute no
  /// presence rather than fail open and let any sibling machine's frame flip
  /// this socket's state.
  bool _isThisMachine(String peerId) =>
      _machineDeviceId != null && peerId == _machineDeviceId;

  void _handleError(ErrorMessage msg) {
    if (!_errorController.isClosed) _errorController.add(msg);

    // Clock-skew AUTH_FAILED (retryable): record the offset and let the socket
    // close → the caller's next dial re-sends the hello with the adjusted `ts`.
    if (msg.code == 'AUTH_FAILED' && msg.serverTime != null) {
      _maybeApplySkew(msg.serverTime!);
      return;
    }

    // LICENSE_* verdicts are fatal regardless of the relay's `retryable` flag
    // (device/config state, not a transient failure), so they must be
    // classified and closed here, ahead of the generic `!msg.retryable`
    // branch below.
    final licenseCode = RelayLicenseErrorCode.fromWire(msg.code);
    if (licenseCode != null) {
      _setState(
        _currentState.copyWith(
          connectionState: RelayConnectionState.disconnected,
          errorCode: msg.code,
          error: '${msg.code}: ${msg.message}',
        ),
      );
      _failConnect(
        RelayConnectException(
          code: msg.code,
          retryable: false,
          message: msg.message,
        ),
      );
      _channel?.sink.close();
      return;
    }

    // Terminal-vs-retryable is the error contract: a
    // `retryable:false` frame precedes an intentional close, so the caller must
    // not dial again. SUPERSEDED/PROTOCOL_VIOLATION/NOT_AUTHORIZED land here —
    // none is a license error.
    if (!msg.retryable) {
      _setState(
        _currentState.copyWith(
          connectionState: RelayConnectionState.disconnected,
          errorCode: msg.code,
          error: '${msg.code}: ${msg.message}',
        ),
      );
      _failConnect(
        RelayConnectException(
          code: msg.code,
          retryable: false,
          message: msg.message,
        ),
      );
      _channel?.sink.close();
      return;
    }

    // Retryable application error (stream / routing): the socket stays open and
    // the connection state is unchanged — only the error fields move.
    _setState(
      _currentState.copyWith(
        errorCode: msg.code,
        error: '${msg.code}: ${msg.message}',
      ),
    );
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
    _markInboundHealthy();
    if (_messageController.isClosed) return;
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
    _log(
      RelayLogLevel.info,
      'relay socket disconnected',
      fields: {
        'machineSlot': _relaySlotId,
        'socketAgeMs': _ageMs(_socketOpenedAt),
        if (error != null) 'error': '$error',
      },
    );
    _cleanup();
    // Retire the dead channel: left here it becomes the `prevChannel` of the
    // NEXT dial, which would then tidy up a socket the peer already abandoned
    // on a path where any delay costs the whole attempt. Only on the DROP path
    // — `disconnect()` calls `_cleanup()` too, and still needs the handle to
    // close the socket itself.
    _channel = null;
    // A socket drop makes the peer unreachable regardless of the grant — feed
    // presence=false so consumers (ControlPlaneClient advert, MachineSession
    // rekey arming) react without waiting for a peer-offline frame that a
    // network drop never delivers.
    if (!_peerPresenceController.isClosed) _peerPresenceController.add(false);
    _setState(
      _currentState.copyWith(
        connectionState: RelayConnectionState.disconnected,
        clearConnectedAt: true,
        // Carry forward a deliberate errorCode across the close it caused (a
        // terminal error sets errorCode then closes → onDone fires here, and
        // copyWith does NOT preserve fields). A fresh _doConnect resets it.
        errorCode: _currentState.errorCode,
        error: error != null ? 'Socket error: $error' : null,
      ),
    );
    _failConnect(
      RelayConnectException(
        code: _currentState.errorCode,
        // A bare close carries no verdict, so it is retryable by default; a
        // terminal frame already failed the attempt with retryable:false above
        // and _failConnect only honours the FIRST failure.
        retryable: true,
        message: 'socket closed before welcome',
      ),
    );
  }

  void _completeConnect() {
    _connectTimeout?.cancel();
    _connectTimeout = null;
    final c = _connect;
    _connect = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _failConnect(RelayConnectException e) {
    _connectTimeout?.cancel();
    _connectTimeout = null;
    final c = _connect;
    _connect = null;
    if (c != null && !c.isCompleted) c.completeError(e);
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

  /// Drop the socket. Idempotent; callers own whether/when to dial again.
  void disconnect() {
    _failConnect(
      RelayConnectException(retryable: true, message: 'disconnected by caller'),
    );
    _cleanup();
    _channel?.sink.close();
    _channel = null;
    _setState(const AppState());
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void _cleanup() {
    _resetHeartbeat();
    _subscription?.cancel();
    _subscription = null;
  }

  /// Re-check a possibly frozen socket when the app returns to the foreground.
  /// Retry remains the supervisor's job: this method only proves or closes the
  /// socket it already owns.
  void onResume() {
    if (_currentState.connectionState != RelayConnectionState.authenticated) {
      return;
    }
    final now = DateTime.now().toUtc();
    final probe = _probeSentAt;
    if (probe != null) {
      if (now.difference(probe) >= _heartbeatInterval) {
        _closeForHeartbeatTimeout(now);
      }
      return;
    }
    final inbound = _lastInboundAt;
    if (inbound != null && now.difference(inbound) < _heartbeatInterval) return;
    _sendHeartbeatProbe(now);
    _scheduleHeartbeat();
  }

  void _startHeartbeat() {
    _probeSentAt = null;
    _lastInboundAt = DateTime.now().toUtc();
    _scheduleHeartbeat();
  }

  void _scheduleHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_currentState.connectionState != RelayConnectionState.authenticated) {
        return;
      }
      final now = DateTime.now().toUtc();
      final probe = _probeSentAt;
      if (probe != null) {
        if (now.difference(probe) >= _heartbeatInterval) {
          _closeForHeartbeatTimeout(now);
        }
        return;
      }
      _sendHeartbeatProbe(now);
    });
  }

  void _sendHeartbeatProbe(DateTime now) {
    _probeSentAt = now;
    _log(
      RelayLogLevel.debug,
      'relay heartbeat probe sent',
      fields: {'machineSlot': _relaySlotId},
    );
    _send(const PingMessage().toJson());
  }

  void _markInboundHealthy() {
    _lastInboundAt = DateTime.now().toUtc();
    _probeSentAt = null;
  }

  void _closeForHeartbeatTimeout(DateTime now) {
    final channel = _channel;
    if (channel == null) return;
    _log(
      RelayLogLevel.warn,
      'relay heartbeat timed out',
      fields: {
        'machineSlot': _relaySlotId,
        'socketAgeMs': _ageMs(_socketOpenedAt, now),
        'lastInboundAgeMs': _ageMs(_lastInboundAt, now),
        'outstandingProbeAgeMs': _ageMs(_probeSentAt, now),
      },
    );
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // Publish the drop synchronously. A half-open peer may never complete the
    // WebSocket close handshake, and waiting for onDone would strand the
    // supervisor behind the dead socket it is responsible for replacing.
    _onDisconnected();
    unawaited(channel.sink.close());
  }

  void _resetHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastInboundAt = null;
    _probeSentAt = null;
    _socketOpenedAt = null;
  }

  int? _ageMs(DateTime? at, [DateTime? now]) => at == null
      ? null
      : (now ?? DateTime.now().toUtc()).difference(at).inMilliseconds;

  void _log(
    RelayLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  }) {
    _logger?.call(level, message, fields: fields);
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _messageController.close();
    _errorController.close();
    _peerPresenceController.close();
  }
}
