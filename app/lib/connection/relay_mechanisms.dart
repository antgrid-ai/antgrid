import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../models/ab_message.dart';
import '../services/license_token_minter.dart';
import '../util/ab_log.dart';
import 'connection_supervisor.dart';
import 'supervisor_state.dart';

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

/// The production [ConnMechanisms] for ONE machine: real relay socket, real
/// [MachineSession], real token minting.
///
/// Every member is a single attempt with no retry of its own — the supervisor
/// is the only thing that decides when to try again.
class RelayMechanisms implements ConnMechanisms {
  RelayMechanisms({
    required RelayService relay,
    required CryptoService crypto,
    required String machineDeviceId,
    required DeviceIdentity identity,
    required String phoneDeviceId,
    required List<int> phoneEd25519Seed,
    required int epoch,
    required Future<ConnCoords?> Function() resolveCoords,
    required Future<String> Function() mintToken,
  }) : _relay = relay,
       _crypto = crypto,
       _machineDeviceId = machineDeviceId,
       _identity = identity,
       _phoneDeviceId = phoneDeviceId,
       _phoneEd25519Seed = phoneEd25519Seed,
       _epoch = epoch,
       _resolveCoords = resolveCoords,
       _mintToken = mintToken;

  final RelayService _relay;
  final CryptoService _crypto;
  final String _machineDeviceId;
  final DeviceIdentity _identity;
  final String _phoneDeviceId;
  final List<int> _phoneEd25519Seed;
  final int _epoch;
  final Future<ConnCoords?> Function() _resolveCoords;
  final Future<String> Function() _mintToken;

  MachineSession? _session;

  /// The agent Ed25519 key [_session]'s handshaker was pinned against. The pin
  /// is fixed at construction, so this is what tells a redial whether the live
  /// session can still verify the identity the coords step just returned.
  String? _sessionPin;

  /// The most recent answer the coords step gave — the agent identity the
  /// session has to be pinned against right now.
  ///
  /// Kept because the ladder does not always pass through [dial] on its way to
  /// a fresh pin: a host that re-provisions its Ed25519 identity without moving
  /// relay leaves the socket authenticated, so the lowest broken rung after the
  /// coords re-resolve is `established`, not `socket`.
  ConnCoords? _lastCoords;
  bool _agentOnline = false;

  /// Reports a relay-shaped error code that no rung failure can express, so the
  /// owner of the policy can block on it. Wired by [RelayConnection] to the
  /// supervisor's `noteRelayError`; unset until then.
  ///
  /// A step that throws is scored as an ordinary rung failure, and rung
  /// failures are only ever backed off. Without this, a verdict raised OUTSIDE
  /// the socket (a token mint the account rejected) is retried on the 30s cap
  /// forever and the caller waiting on the session sees only a timeout.
  void Function(String code)? onTerminalAuthError;

  /// The agent handed this machine's E2E session to another device (sealed
  /// `session-takeover`). Wired by [RelayConnection] to the supervisor's
  /// `noteSessionTakenOver`; unset until then.
  ///
  /// Without it the ladder would see only "session down", re-handshake, and the
  /// two devices would evict each other forever.
  void Function()? onSessionTakenOver;

  /// The [MachineSession] was REPLACED (not merely torn down) because the
  /// coords step came back with a different agent pin. Wired by
  /// [RelayConnection] to its `sessionReplacements` stream; unset until then.
  ///
  /// Disposing the old session disposes every [StreamTransport] hanging off it
  /// — i.e. exactly the objects the transport provider handed to each project
  /// on this machine. Nothing else observes the swap: the connection is neither
  /// added nor removed, so `connectionChanges` stays silent, and
  /// `onSessionDown` goes only to the supervisor. Without this the focused
  /// project recovers on Retry (which invalidates its own family entry) while
  /// every other warm project on the machine keeps a disposed transport whose
  /// RPCs can never complete.
  void Function()? onSessionReplaced;

  /// The E2E session died under a still-live socket (a rekey the agent never
  /// confirmed). Wired by [RelayConnection] to the supervisor's
  /// `noteSessionDown`; unset until then.
  ///
  /// Nothing else reports it: the relay socket stays authenticated, so no
  /// state event fires, and without this the `established` rung would keep
  /// reading satisfied off a session that has already been torn down.
  void Function()? onSessionDown;

  /// The machine's single E2E session, or null before the first dial / after a
  /// [release]. Deliberately survives a redial: the project [StreamTransport]s
  /// handed to services hang off it, and recreating it on every socket blip
  /// would orphan them. The one exception is coords carrying a different agent
  /// Ed25519 pin — see [_ensureSession].
  MachineSession? get session => _session;

  @override
  Future<ConnCoords?> resolveCoords() async {
    final coords = await _resolveCoords();
    if (coords != null) _lastCoords = coords;
    return coords;
  }

  @override
  Future<String> mintToken() async {
    try {
      return await _mintToken();
    } on DeviceRevokedException {
      // Same verdict the relay would return had the token reached it, raised
      // one layer earlier — the mint endpoint rejected the credentials.
      onTerminalAuthError?.call('LICENSE_REVOKED');
      rethrow;
    }
  }

  @override
  Future<void> dial(ConnCoords coords, String token) async {
    _lastCoords = coords;
    // The session must exist before the socket carries traffic: the agent's
    // handshake frames arrive on it, and one constructed later would have
    // missed them.
    await _ensureSession(coords.agentEd25519PubB64);

    // Completes on `welcome`, so `socketAuthenticated` already reads true when
    // this returns — the contract the supervisor scores the step against.
    await _relay.connect(
      coords.relayUrl,
      _identity,
      licenseToken: token,
      epoch: _epoch,
      machineDeviceId: _machineDeviceId,
    );
  }

  @override
  bool get socketAuthenticated =>
      _relay.currentState.connectionState.index >=
      RelayConnectionState.authenticated.index;

  /// Fed by the relay's `peer-online`/`peer-offline` for THIS machine — the
  /// service already filters presence frames to `machineDeviceId`, and a socket
  /// drop feeds `false` even when no peer-offline frame ever arrives.
  @override
  bool get agentOnline => _agentOnline;

  /// Level input, pushed by [RelayConnection] from the relay's presence stream.
  ///
  /// Deliberately not a subscription of our own: the supervisor re-derives the
  /// whole ladder synchronously inside its own `notePresence`, so this value
  /// has to be written by the SAME listener, before that call. A second
  /// subscriber on the broadcast stream is one microtask late, which the
  /// supervisor reads as "still offline" and pays for with a full routable
  /// stall on every agent-return.
  void notePresence(bool online) => _agentOnline = online;

  @override
  Future<void> establishSession() async {
    final coords = _lastCoords;
    if (coords == null) {
      throw StateError('establishSession before the coords step ran');
    }
    // Deliberately routed through [_ensureSession] rather than reading
    // [_session]: this rung, not the socket rung, is where a re-provisioned
    // host is met, because its socket never dropped. Reusing the session here
    // would verify every agent-hello against the retired key and make the
    // user's Retry inert.
    final session = await _ensureSession(coords.agentEd25519PubB64);
    // A step runs under the supervisor's single-flight guard, so anything this
    // waits out is time the ladder cannot use to react. Failing the instant the
    // socket dies is what lets a drop mid-handshake redial now instead of at
    // the end of the handshake driver's own attempt timeout.
    final dropped = Completer<void>();
    final socketSub = _relay.stateStream.listen((s) {
      if (s.connectionState != RelayConnectionState.disconnected) return;
      if (!dropped.isCompleted) {
        dropped.completeError(
          StateError('socket dropped before the E2E handshake completed'),
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
      await socketSub.cancel();
      if (!dropped.isCompleted) dropped.complete();
    }
  }

  @override
  bool get sessionEstablished => _session?.isEstablished ?? false;

  @override
  Future<void> release() async {
    final session = _session;
    _session = null;
    _sessionPin = null;
    _lastCoords = null;
    _agentOnline = false;
    if (session != null) await session.dispose();
    // Guarded, not merely idempotent: `disconnect()` emits a state event, which
    // feeds another evaluation, which releases again — an unguarded call loops.
    if (_relay.currentState.connectionState !=
        RelayConnectionState.disconnected) {
      _relay.disconnect();
    }
  }

  Future<MachineSession> _ensureSession(String agentEd25519PubB64) async {
    final existing = _session;
    if (existing != null) {
      if (_sessionPin == agentEd25519PubB64) return existing;
      // The coords step came back with a different agent identity — the host
      // re-provisioned. [AppSessionHandshaker] pins the key at construction, so
      // keeping this session would verify every agent-hello against a key that
      // no longer exists and the user's Retry would be inert. Dispose first
      // (which zeroizes the old session keys) so nothing outlives the pin it
      // was derived under.
      _session = null;
      _sessionPin = null;
      await existing.dispose();
      // After the dispose, so a listener that rebuilds a transport off this
      // signal cannot observe the half-torn-down session it is replacing.
      onSessionReplaced?.call();
    }
    final session = MachineSession(
      relay: _relay,
      machineDeviceId: _machineDeviceId,
      handshaker: AppSessionHandshaker(
        relay: _relay,
        crypto: _crypto,
        machineDeviceId: _machineDeviceId,
        phoneDeviceId: _phoneDeviceId,
        agentEd25519PubB64: agentEd25519PubB64,
        phoneEd25519Seed: _phoneEd25519Seed,
        logger: _logHandshake,
      ),
      projectStartMessageBuilder: (projectId) =>
          createAbMessage('project:start', {'projectId': projectId}),
    );
    session.takeoverEvents.listen((_) => onSessionTakenOver?.call());
    session.sessionDownEvents.listen((_) => onSessionDown?.call());
    session.start();
    _sessionPin = agentEd25519PubB64;
    return _session = session;
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
