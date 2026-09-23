import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';

import '../config/native_crypto.dart';
import '../models/ab_message.dart';
import '../services/license_token_minter.dart';
import '../util/ab_log.dart';
import 'connection_supervisor.dart';
import 'supervisor_state.dart';
import 'peer_runtime.dart';
import '../util/detached.dart';

/// Thrown when the supervisor has stopped climbing on purpose, so a caller
/// awaiting the connection fails with the reason instead of hanging.
class ConnectionBlockedException implements Exception {
  ConnectionBlockedException(this.reason);

  final BlockReason reason;

  @override
  String toString() => 'ConnectionBlockedException(${reason.name})';
}

/// Safety net around ONE [MachineSession] handshake attempt (itself bounded by
/// the handshake driver's own attempt timeout). A step runs under the
/// supervisor's single-flight guard, so a wedged attempt would otherwise freeze
/// the whole ladder.
const Duration _kEstablishTimeout = Duration(seconds: 20);

/// Native payload mechanisms and central-control dialer for one machine.
/// A required, enrollment-scoped [PeerConnector] establishes the payload;
/// [MachineSession] owns E2E and host project streams.
///
/// Every member is a single attempt with no retry of its own — the supervisor
/// is the only thing that decides when to try again.
class PeerConnectionMechanisms implements PeerConnectionContract {
  PeerConnectionMechanisms({
    required CryptoService crypto,
    required String machineDeviceId,
    required String phoneDeviceId,
    required List<int> phoneEd25519Seed,
    required Future<ConnCoords?> Function() resolveCoords,
    SessionHandshaker Function(String agentEd25519PubB64)? buildHandshaker,
    this.diagnostic,
    required this.peerRuntime,
  }) : _buildHandshaker = buildHandshaker,
       _crypto = crypto,
       _machineDeviceId = machineDeviceId,
       _phoneDeviceId = phoneDeviceId,
       _phoneEd25519Seed = phoneEd25519Seed,
       _resolveCoords = resolveCoords;

  final PeerConnector peerRuntime;
  final PeerLinkDiagnostic? diagnostic;
  final _attempt = PeerConnectionAttempt();
  final _events = StreamController<PeerConnectionEvent>.broadcast(sync: true);
  Future<void>? _releasePending;
  PeerLink? _payloadLink;
  PeerLink? _closingPayloadLink;

  /// The link [_session] was constructed on. `MachineSession.relay` is fixed,
  /// and every dial returns a new link, so a session kept across a redial
  /// would go on reading and writing the link that redial closed.
  PeerLink? _sessionLink;
  StreamSubscription<PeerLinkFailure>? _peerFailureSub;
  bool _runtimeRetained = false;
  int _dialGeneration = 0;
  PeerLink get payloadLink =>
      _payloadLink ?? (throw StateError("Native payload is not connected"));
  @override
  Stream<PeerConnectionEvent> get events => _events.stream;

  void noteResume() {
    detached('PeerRuntime', 'resume authorization', () async {
      await peerRuntime.resume();
    });
  }

  final CryptoService _crypto;
  final String _machineDeviceId;
  final String _phoneDeviceId;
  final List<int> _phoneEd25519Seed;
  final Future<ConnCoords?> Function() _resolveCoords;

  /// A test seam — production passes nothing and gets [AppSessionHandshaker].
  /// Exists because the handshake is the only way to reach the teardowns that
  /// retire session keys WITHOUT disposing the session, and those are the
  /// majority of them.
  final SessionHandshaker Function(String agentEd25519PubB64)? _buildHandshaker;

  MachineSession? _session;

  /// Watches the native payload for the one key retirement [MachineSession] publishes
  /// no event for. Tied to [_session]'s lifetime, not the relay's: the relay
  /// outlives any single session, so a subscription left behind would go on
  /// retiring keys on behalf of a session that no longer exists.
  StreamSubscription<PeerLinkState>? _payloadDownSub;

  /// The most recent answer the coords step gave. [establishSession] needs the
  /// agent key to build a session when no payload dial has built one yet.
  ConnCoords? _lastCoords;

  /// Reports a relay-shaped error code that no rung failure can express, so the
  /// owner of the policy can block on it. Wired by `MachineConnection` to the
  /// supervisor's `noteRelayError`; unset until then.
  ///
  /// A step that throws is scored as an ordinary rung failure, and rung
  /// failures are only ever backed off. Without this, a verdict raised OUTSIDE
  /// the native ladder (a token mint the account rejected) is retried on the 30s cap
  /// forever and the caller waiting on the session sees only a timeout.

  /// The agent handed this machine's E2E session to another device (sealed
  /// `session-takeover`). Wired by `MachineConnection` to the supervisor's
  /// `noteSessionTakenOver`; unset until then.
  ///
  /// Without it the ladder would see only "session down", re-handshake, and the
  /// two devices would evict each other forever.

  /// The [MachineSession] was REPLACED (not merely torn down) because a redial
  /// produced a new payload link. Wired by `MachineConnection` to its
  /// `sessionReplacements` stream.
  ///
  /// Disposing the old session disposes every [StreamTransport] hanging off it
  /// — exactly the objects the transport provider handed to each project on
  /// this machine. Nothing else observes the swap: the connection is neither
  /// added nor removed, so `connectionChanges` stays silent, and the typed
  /// session-down event goes only to the supervisor. Without this the focused
  /// project recovers on Retry (which invalidates its own family entry) while
  /// every other warm project on the machine keeps a disposed transport whose
  /// RPCs can never complete.

  /// The E2E session died under a still-live native payload (a rekey the agent never
  /// confirmed). Wired by `MachineConnection` to the supervisor's
  /// `noteSessionDown`; unset until then.
  ///
  /// Nothing else reports it: the native payload stays connected, so no
  /// state event fires, and without this the `established` rung would keep
  /// reading satisfied off a session that has already been torn down.

  /// The machine's single E2E session, or null before the first payload connection / after a
  /// [release]. Deliberately survives a central reconnect: the project [StreamTransport]s
  /// handed to services hang off it, and recreating it on every control-plane blip
  /// would orphan them. The one exception is a redial onto a new payload link —
  /// see [_ensureSession].
  MachineSession? get session => _session;

  @override
  Future<ConnCoords?> resolveCoords() async {
    final coords = await _resolveCoords();
    if (coords != null) _lastCoords = coords;
    return coords;
  }

  @override
  Future<void> connectPayload(ConnCoords coords) async {
    final generation = ++_dialGeneration;
    _lastCoords = coords;
    final runtime = peerRuntime;
    if (generation != _dialGeneration) throw ConnectionAttemptCancelled();
    if (!_runtimeRetained) {
      runtime.retain();
      _runtimeRetained = true;
    }
    final prior = _payloadLink;
    _payloadLink = null;
    if (prior != null) await prior.close();
    if (generation != _dialGeneration) throw ConnectionAttemptCancelled();
    {
      try {
        final link = await runtime.connect(
          attempt: _attempt,
          diagnostic: diagnostic,
          machineDeviceId: _machineDeviceId,
          machinePublicKey: coords.agentEd25519PubB64,
        );
        if (generation != _dialGeneration) {
          await link.close();
          throw ConnectionAttemptCancelled();
        }
        _payloadLink = link;
        await _peerFailureSub?.cancel();
        if (generation != _dialGeneration) {
          await link.close();
          throw ConnectionAttemptCancelled();
        }
        _peerFailureSub = link.failureStream.listen((failure) {
          // Only the native payload died, so the central relay's state stream
          // reports nothing and the ladder has to be woken from here.
          if (!failure.retryable) {
            _emit(const PeerTerminalError());
          } else {
            _emit(const PeerSessionDown());
          }
        });
        await _ensureSession(coords.agentEd25519PubB64);
      } on PeerConnectionFailure catch (error) {
        if (error.cancelled || generation != _dialGeneration) {
          throw ConnectionAttemptCancelled();
        }
        if (error.terminal) _emit(const PeerTerminalError());
        rethrow;
      } on PeerAuthorizationDenied {
        _emit(const PeerTerminalError());
        rethrow;
      } on FormatException {
        _emit(const PeerTerminalError());
        rethrow;
      }
    }
  }

  @override
  bool get payloadConnected => _payloadLink?.isDispatchAllowed == true;

  @override
  Future<void> establishSession() async {
    final coords = _lastCoords;
    if (coords == null) {
      throw StateError('establishSession before the coords step ran');
    }
    // Routed through [_ensureSession] rather than reading [_session] directly
    // so this rung can build the session on its own the first time it runs
    // without waiting on [connectPayload] to have done it already.
    final session = await _ensureSession(coords.agentEd25519PubB64);
    // A step runs under the supervisor's single-flight guard, so anything this
    // waits out is time the ladder cannot use to react. Failing the instant the
    // payload dies is what lets a drop mid-handshake reconnect now instead of at
    // the end of the handshake driver's own attempt timeout.
    final dropped = Completer<void>();
    final payloadSub = payloadLink.payloadStateStream.listen((s) {
      if (s != PeerLinkState.closed) return;
      if (!dropped.isCompleted) {
        dropped.completeError(
          StateError('payload dropped before the E2E handshake completed'),
        );
      }
    });
    try {
      // ensureEstablished drives exactly one attempt and resolves only once
      // the session reads established (it throws otherwise) — the contract the
      // supervisor scores this step against.
      await Future.any(<Future<void>>[
        session.ensureEstablished(),
        dropped.future,
      ]).timeout(_kEstablishTimeout);
    } finally {
      await payloadSub.cancel();
      if (!dropped.isCompleted) dropped.complete();
    }
  }

  @override
  bool get sessionEstablished => _session?.isEstablished ?? false;

  void _emit(PeerConnectionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void fenceDispatch() {
    _dialGeneration++;
    _attempt.cancel();
    final payload = _payloadLink;
    if (payload != null) unawaited(payload.close());
  }

  @override
  Future<void> release() => _releasePending ??= _release().whenComplete(() {
    unawaited(_events.close());
  });

  Future<void> _release() async {
    fenceDispatch();
    await _peerFailureSub?.cancel();
    _peerFailureSub = null;
    final payload = _payloadLink;
    _payloadLink = null;
    _closingPayloadLink = payload;
    _sessionLink = null;
    try {
      if (payload != null) await payload.close();
    } finally {
      if (identical(_closingPayloadLink, payload)) {
        _closingPayloadLink = null;
      }
    }
    if (_runtimeRetained) {
      peerRuntime.release();
      _runtimeRetained = false;
    }
    final session = _session;
    _session = null;
    await _payloadDownSub?.cancel();
    _payloadDownSub = null;
    _lastCoords = null;
    if (session != null) {
      await session.dispose();
      // dispose() zeroizes the Dart-side keys; the installed native cipher
      // holds its own copy that nothing else retires.
      retireNativeE2eCipherKeys();
    }
    // Guarded, not merely idempotent: `disconnect()` emits a state event, which
    // feeds another evaluation, which releases again — an unguarded call loops.
  }

  @override
  Future<void> forceClose() async {
    fenceDispatch();
    await (_payloadLink ?? _closingPayloadLink)?.close();
  }

  Future<MachineSession> _ensureSession(String agentEd25519PubB64) async {
    final generation = _dialGeneration;
    final existing = _session;
    if (existing != null) {
      if (identical(_sessionLink, payloadLink)) return existing;
      // Dispose first (which zeroizes the old session keys) so nothing
      // outlives the link it was derived on.
      _session = null;
      _sessionLink = null;
      await _payloadDownSub?.cancel();
      _payloadDownSub = null;
      await existing.dispose();
      retireNativeE2eCipherKeys();
      if (generation != _dialGeneration) {
        throw StateError('Session attempt superseded');
      }
      // After the dispose, so a listener that rebuilds a transport off this
      // signal cannot observe the half-torn-down session it is replacing.
      _emit(const PeerSessionReplaced());
    }
    final session = MachineSession(
      relay: payloadLink,
      machineDeviceId: _machineDeviceId,
      handshaker:
          _buildHandshaker?.call(agentEd25519PubB64) ??
          AppSessionHandshaker(
            relay: payloadLink,
            crypto: _crypto,
            machineDeviceId: _machineDeviceId,
            phoneDeviceId: _phoneDeviceId,
            agentEd25519PubB64: agentEd25519PubB64,
            phoneEd25519Seed: _phoneEd25519Seed,
            logger: _logHandshake,
          ),
      projectStartMessageBuilder: (projectId) =>
          createAbMessage('project:start', {'projectId': projectId}),
      logger: _logMachineSession,
    );
    // A session retires its keys on four paths and is DISPOSED on only two of
    // them, so the dispose sites alone leave the involuntary majority — a
    // dropped payload above all — holding key material in the native cipher.
    // `MachineSession` zeroizes its own buffers on each of these; the cipher's
    // copy is reachable from here or nowhere.
    session.takeoverEvents.listen((_) {
      retireNativeE2eCipherKeys();
      _emit(const PeerSessionTakenOver());
    });
    session.sessionDownEvents.listen((_) {
      retireNativeE2eCipherKeys();
      _emit(const PeerSessionDown());
    });
    // The common one, and the only one with no event of its own: the session
    // tears down on exactly this transition (its `_onState`), so watching the
    // payload here is reading the same signal it does rather than guessing at a
    // proxy for it.
    _payloadDownSub = payloadLink.payloadStateStream.listen((s) {
      if (s == PeerLinkState.closed) {
        retireNativeE2eCipherKeys();
        _emit(const PeerSessionDown());
      }
    });
    session.start();
    _sessionLink = payloadLink;
    return _session = session;
  }
}

class RelayCentralControlDialer implements CentralControlContract {
  RelayCentralControlDialer({
    required this.relay,
    required this.machineDeviceId,
    required this.identity,
    required this.epoch,
    required this.mintToken,
  });

  final RelayService relay;
  final String machineDeviceId;
  final DeviceIdentity identity;
  final int epoch;
  final Future<String> Function() mintToken;
  final _authErrors = StreamController<String>.broadcast(sync: true);
  String? _connectedUrl;

  @override
  Stream<String> get authErrorStream => _authErrors.stream;

  @override
  bool get needsReconnect =>
      relay.currentState.connectionState != RelayConnectionState.authenticated;

  @override
  Future<void> connect(ConnCoords coords) async {
    final String token;
    try {
      token = await mintToken();
    } on DeviceRevokedException {
      if (!_authErrors.isClosed) _authErrors.add('LICENSE_REVOKED');
      rethrow;
    }
    _connectedUrl = coords.relayUrl;
    await relay.connect(
      coords.relayUrl,
      identity,
      licenseToken: token,
      epoch: epoch,
      machineDeviceId: machineDeviceId,
    );
    if (_connectedUrl != coords.relayUrl) {
      throw ConnectionAttemptCancelled();
    }
  }

  @override
  void disconnect() {
    _connectedUrl = null;
    relay.disconnect();
  }
}

/// Route the (Flutter-free) session's diagnostics into `app.log`. Until this
/// existed the app was blind to its own send-gate stalls and dropped frames,
/// so every diagnosis of a wedged connection had to come off the agent's logs.
void _logMachineSession(
  RelayLogLevel level,
  String message, {
  Map<String, Object?>? fields,
}) {
  const component = 'MachineSession';
  switch (level) {
    case RelayLogLevel.debug:
      AbLog.debug(component, message, fields: fields);
    case RelayLogLevel.info:
      AbLog.info(component, message, fields: fields);
    case RelayLogLevel.warn:
      AbLog.warn(component, message, fields: fields);
    case RelayLogLevel.error:
      AbLog.error(component, message, fields: fields);
  }
}

/// Route the (Flutter-free) handshake driver's diagnostics into `app.log` —
/// a connection that won't establish is diagnosed from those lines.
void _logHandshake(
  HandshakeLogLevel level,
  String message, {
  Map<String, Object?>? fields,
}) {
  const component = 'ConnectionHandshake';
  switch (level) {
    case HandshakeLogLevel.debug:
      AbLog.debug(component, message, fields: fields);
    case HandshakeLogLevel.error:
      AbLog.error(component, message, fields: fields);
  }
}
