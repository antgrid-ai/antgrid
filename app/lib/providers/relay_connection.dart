import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_supervisor.dart';
import '../connection/peer_connection.dart';
import '../connection/supervisor_state.dart';
import '../util/ab_log.dart';
import '../util/device_id.dart';
import '../util/netwatch.dart';
import 'seeded_stream.dart';
import 'device_revocation.dart';
import 'providers.dart';

/// Owns one machine's independent central-control [RelayService], required
/// native payload, and peer [MachineSession]. Projects share host-owned streams
/// on that native session; the central socket carries authentication, presence,
/// policy and revocation only. There is one [MachineConnection] per bare machine
/// `deviceUuid`, never one per project.
///
/// Callers do not establish either path directly. Independent supervisors own
/// central control and native retry policy.
class MachineConnection {
  final String machineDeviceId;
  final RelayService relay;

  MachineConnection({
    required this.machineDeviceId,
    required CryptoService crypto,
    this.onDeviceRevoked,
    // Test seam: inject a fake RelayService. Production passes null.
    RelayService? relayOverride,
  }) : relay =
           relayOverride ??
           RelayService(
             crypto: crypto,
             logger: _logRelayService,
             // PeerRuntime forwards native diagnostics through this per-machine
             // hook, keeping central and payload observations on one recorder.
             // Gate on the environment flag, not recorder existence: a remote
             // arm installs its own tap for this connection, and reading that
             // recorder here would make later connections born-tapped.
             netTap: netwatchEnabled ? ensureNetwatch().tap : null,
           );

  /// Fires when the relay tells us this device has been revoked from the
  /// account. Distinct from the supervisor's `Blocked(deviceRevoked)`, which
  /// only stops this machine's ladder: revocation is an ACCOUNT verdict, so the
  /// app has to sign out, and only the provider layer can do that.
  final void Function()? onDeviceRevoked;

  PeerConnectionMechanisms? _mechanisms;
  NativeConnectionSupervisor? _nativeSupervisor;
  CentralControlSupervisor? _centralSupervisor;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;
  Future<NativeStopResult>? _disposePending;
  NativeStopResult? _disposeResult;

  final StreamController<SupervisorStatus?> _statuses =
      StreamController<SupervisorStatus?>.broadcast();
  SupervisorStatus? _status;
  final StreamController<bool> _centralConflicts =
      StreamController<bool>.broadcast();
  bool _centralConflict = false;

  final StreamController<void> _sessionReplacements =
      StreamController<void>.broadcast();

  /// Fires when this machine's [MachineSession] is swapped for a fresh one (a
  /// redial produced a new payload link). Every project bound to this machine
  /// must rebuild its transport: the swap disposed the [StreamTransport] each
  /// of them holds.
  ///
  /// Deliberately NOT emitted on [dispose] — a released connection already has
  /// the reaper and the registry's `onEvict` invalidating its transports.
  Stream<void> get sessionReplacements => _sessionReplacements.stream;

  /// The live native [MachineSession] once payload establishment creates it.
  MachineSession? get session => _mechanisms?.session;

  /// The policy engine driving this machine, or null before [ensureStarted].
  NativeConnectionSupervisor? get nativeSupervisor => _nativeSupervisor;
  CentralControlSupervisor? get centralSupervisor => _centralSupervisor;
  NativeConnectionSupervisor? get supervisor => _nativeSupervisor;

  /// Connection-owned status surface, valid to subscribe to from construction —
  /// BEFORE [ensureStarted] has built a supervisor.
  ///
  /// Subscribing to `supervisor.statusStream` directly cannot work for the UI:
  /// a machine's connection is created the moment its transport starts
  /// resolving, and the supervisor only appears after the epoch read and the
  /// token mint have both awaited (see `agent_transport.dart`). A subscriber
  /// that peeked in that window would see no supervisor and never hear about
  /// the one created a few turns later. This stream replays the current status
  /// to every new listener, forwards every later one, and ends with a terminal
  /// [Released] on [dispose] so nothing retains a live-looking status for a
  /// connection whose central and native resources have been released.
  Stream<SupervisorStatus?> get statusStream =>
      seededStream(() => _status, _statuses.stream);

  void _publishStatus(SupervisorStatus? status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }

  Stream<bool> get centralConflictStream =>
      seededStream(() => _centralConflict, _centralConflicts.stream);

  void _publishCentralConflict(bool conflict) {
    _centralConflict = conflict;
    if (!_centralConflicts.isClosed) _centralConflicts.add(conflict);
  }

  /// `LICENSE_REVOKED` ONLY. `LICENSE_INVALID` reaches the same supervisor
  /// block but is a token/deviceUuid/pk binding mismatch, which a coords or
  /// agent-pin bug produces just as easily as a real revocation — signing the
  /// user out on it would turn a connection bug into a forced re-auth.
  void _noteAuthCode(String? code) {
    if (RelayLicenseErrorCode.fromWire(code) ==
        RelayLicenseErrorCode.licenseRevoked) {
      onDeviceRevoked?.call();
    }
  }

  /// Declare that this machine's connection is wanted, constructing the
  /// supervisor on the first call. Later calls are no-ops: the supervisor is
  /// per-machine and every project shares its native session, so the
  /// second project to resolve must not restart the ladder.
  ///
  /// [mechanisms] is typed concretely because the connection exposes the
  /// adapter's [MachineSession] — the streams every project binds to.
  void ensureStarted({
    required PeerConnectionMechanisms mechanisms,
    CentralControlContract? central,
  }) {
    if (_disposed || _nativeSupervisor != null) return;
    _mechanisms = mechanisms;
    final centralMechanisms = central ?? _NoopCentralControl();
    final centralSupervisor = _centralSupervisor = CentralControlSupervisor(
      centralMechanisms,
    );
    final supervisor = _nativeSupervisor = NativeConnectionSupervisor(
      mechanisms,
      onCoordsResolved: centralSupervisor.noteCoords,
    );
    _subs.add(
      mechanisms.events.listen((event) {
        switch (event) {
          case PeerTerminalAuthError(:final code):
            _noteAuthCode(code);
            supervisor.noteAuthError(code);
          case PeerTerminalError():
            supervisor.notePeerRejected();
          case PeerSessionTakenOver():
            supervisor.noteSessionTakenOver();
          case PeerSessionDown():
            supervisor.noteSessionDown();
          case PeerSessionReplaced():
            if (!_sessionReplacements.isClosed) {
              _sessionReplacements.add(null);
            }
        }
      }),
    );
    _subs.add(
      centralMechanisms.authErrorStream.listen((code) {
        _noteAuthCode(code);
        supervisor.noteAuthError(code);
      }),
    );
    // Level-triggered inputs: each one only tells the supervisor that something
    // changed, never what to do about it.
    _subs.add(
      relay.stateStream.listen((_) => centralSupervisor.noteStateChanged()),
    );
    _subs.add(
      relay.errorStream.listen((e) {
        _noteAuthCode(e.code);
        if (!e.retryable && e.code.startsWith('LICENSE_')) {
          mechanisms.peerRuntime.invalidate();
        }
        if (e.code.startsWith('LICENSE_')) supervisor.noteAuthError(e.code);
        centralSupervisor.noteRelayError(e.code);
      }),
    );
    _subs.add(
      relay.peerPresenceStream.listen((online) {
        supervisor.notePresence(online);
      }),
    );
    _subs.add(
      relay.policyGenerationStream.listen((generation) {
        mechanisms.peerRuntime.notePolicyGeneration(generation);
      }),
    );
    // Replays the supervisor's current status first, so subscribers that were
    // already listening to [statusStream] pick the ladder up here.
    _subs.add(supervisor.statusStream.listen(_publishStatus));
    _subs.add(centralSupervisor.conflictStream.listen(_publishCentralConflict));
    centralSupervisor.setWanted(true);
    supervisor.setWanted(true);
  }

  /// Waits for this machine's peer session to be usable.
  ///
  /// Throws [ConnectionBlockedException] the moment the supervisor stops
  /// climbing (license, revocation, handshake, or peer rejection) so the caller surfaces the
  /// reason instead of spinning, and [TimeoutException] if neither happens.
  Future<MachineSession> awaitSession({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final supervisor = _nativeSupervisor;
    if (supervisor == null) {
      throw StateError('awaitSession before ensureStarted');
    }
    final live = session;
    if (supervisor.status is Connected && live != null) return live;

    final done = Completer<MachineSession>();
    final sub = supervisor.statusStream.listen(
      (status) {
        if (done.isCompleted) return;
        if (status is Connected) {
          final s = session;
          if (s != null) done.complete(s);
        } else if (status is Blocked) {
          done.completeError(ConnectionBlockedException(status.reason));
        }
      },
      // The reaper disposes the supervisor without ever emitting a terminal
      // status, so a caller parked here would otherwise sit out the whole
      // timeout waiting for a machine connection that has been released.
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(
            StateError('connection released while awaiting its session'),
          );
        }
      },
    );
    try {
      return await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  /// App resume: revalidate native authorization and the independent central
  /// control path, then re-evaluate the native ladder so a frozen background
  /// timer does not delay its next bounded attempt.
  void noteResume() {
    _mechanisms?.noteResume();
    relay.onResume();
    _centralSupervisor?.noteStateChanged();
    _nativeSupervisor?.noteResume();
  }

  void retry() {
    _centralSupervisor?.retry();
    _nativeSupervisor?.retry();
  }

  Future<NativeStopResult> dispose() {
    final existing = _disposePending;
    if (existing != null) return existing;
    _disposed = true;
    final native = _nativeSupervisor;
    final central = _centralSupervisor;
    return _disposePending = _teardown(native, central);
  }

  Future<NativeStopResult> _teardown(
    NativeConnectionSupervisor? native,
    CentralControlSupervisor? central,
  ) async {
    final nativeStop =
        native?.stop() ??
        Future<NativeStopResult>.value(NativeStopResult.stopped);
    await Future.wait([for (final sub in _subs) sub.cancel()]);
    _subs.clear();
    await central?.stop();
    final result = await nativeStop;
    _disposeResult = result;
    if (result == NativeStopResult.stopped) {
      _nativeSupervisor = null;
      _centralSupervisor = null;
      _mechanisms = null;
      _publishStatus(const Released());
      relay.dispose();
      unawaited(_statuses.close());
      unawaited(_centralConflicts.close());
      unawaited(_sessionReplacements.close());
    }
    return result;
  }

  bool get isDisposed => _disposed;
  bool get cleanupIncomplete =>
      _disposeResult == NativeStopResult.cleanupIncomplete;
}

class _NoopCentralControl implements CentralControlContract {
  @override
  Stream<String> get authErrorStream => const Stream.empty();
  @override
  bool get needsReconnect => false;
  @override
  Future<void> connect(ConnCoords coords) async {}
  @override
  void disconnect() {}
}

void _logRelayService(
  RelayLogLevel level,
  String message, {
  Map<String, Object?>? fields,
}) {
  const component = 'RelayService';
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

/// Holds one [MachineConnection] per bare machine `deviceUuid`. Each connection
/// maintains its own central-control socket and native payload; project streams
/// multiplex over the machine's peer session on that payload.
class MachineConnectionManager {
  final CryptoService _crypto;
  final Map<String, MachineConnection> _connections = {};
  final _changesController = StreamController<int>.broadcast();
  int _changeSeq = 0;
  bool _newWorkBlocked = false;

  MachineConnectionManager({
    required CryptoService crypto,
    this.onDeviceRevoked,
  }) : _crypto = crypto;

  /// Handed to every connection this manager builds — see
  /// [MachineConnection.onDeviceRevoked]. Any machine's central control can carry the
  /// verdict, since it is our own device that was revoked, not theirs.
  final void Function()? onDeviceRevoked;

  /// Fires whenever a connection is added to or removed from [_connections].
  ///
  /// Carries a monotonic sequence rather than `void` because consumers reach it
  /// through a `StreamProvider`, whose `AsyncData(null) == AsyncData(null)`:
  /// with a valueless event only the very first add would ever notify, and a
  /// machine reaped and re-dialed later would leave every peek-based provider
  /// serving its pre-reap value.
  Stream<int> get connectionChanges => _changesController.stream;

  void _notifyChanged() {
    if (!_changesController.isClosed) _changesController.add(++_changeSeq);
  }

  MachineConnection connectionFor(String machineDeviceId) {
    // Normalize here, not at call sites: the map key IS the v3 invariant (one
    // connection per machine), so a compound `<uuid>.<projectId>` id must land
    // on the same slot as its bare machine uuid no matter who dials.
    final key = baseDeviceUuid(machineDeviceId);
    final existing = _connections[key];
    if (existing != null) return existing;
    if (_newWorkBlocked) {
      throw StateError('Machine connection manager is blocking new work');
    }
    final conn = MachineConnection(
      machineDeviceId: key,
      crypto: _crypto,
      onDeviceRevoked: onDeviceRevoked,
    );
    _connections[key] = conn;
    _notifyChanged();
    return conn;
  }

  MachineConnection? peek(String machineDeviceId) =>
      _connections[baseDeviceUuid(machineDeviceId)];

  void blockNewWork() {
    _newWorkBlocked = true;
  }

  bool get newWorkBlocked => _newWorkBlocked;

  Set<String> get cleanupIncompleteIds => {
    for (final entry in _connections.entries)
      if (entry.value.cleanupIncomplete) entry.key,
  };

  /// App resume: re-evaluate every live machine's ladder. Level-triggered, so
  /// this only says "something may have changed", never what to do about it.
  void noteResume() {
    for (final c in _connections.values) {
      c.noteResume();
    }
  }

  /// True if at least one live machine's ladder is actually
  /// `Blocked(licenseExpired)` — the gate for `AppShell._reconnectRelay`'s
  /// out-of-band re-mint, so a resume with nothing stuck never costs a
  /// network request.
  bool get hasLicenseExpiredBlock => _connections.values.any(
    (c) => c.supervisor?.status == const Blocked(BlockReason.licenseExpired),
  );

  /// Pings only the machines actually `Blocked(licenseExpired)`, after a token
  /// mint that happened OUTSIDE the connection ladder (see
  /// `AppShell._reconnectRelay`) — `noteFreshToken()` unconditionally resets
  /// its rung's backoff, so pinging an unblocked machine would erase backoff
  /// it never earned back. Never call this from inside
  /// the central control reconnect path, which mints a fresh token for each attempt and
  /// would reset that rung's backoff before the dial it belongs to is scored
  /// (see [NativeConnectionSupervisor.noteFreshToken]).
  void noteFreshTokenEverywhere() {
    for (final c in _connections.values) {
      if (c.supervisor?.status == const Blocked(BlockReason.licenseExpired)) {
        c.supervisor?.noteFreshToken();
      }
    }
  }

  /// Bare deviceUuids of every live per-machine connection. Central control and
  /// native payload remain separate inside each connection, so this is the
  /// connection key set rather than a payload-stream inventory.
  List<String> openControlPlaneIds() =>
      _connections.keys.toList(growable: false);

  Future<NativeStopResult?> release(String machineDeviceId) async {
    final key = baseDeviceUuid(machineDeviceId);
    final connection = _connections[key];
    if (connection != null) {
      final result = await connection.dispose();
      if (result == NativeStopResult.stopped &&
          identical(_connections[key], connection)) {
        _connections.remove(key);
        _notifyChanged();
      }
      return result;
    }
    return null;
  }

  Future<Map<String, NativeStopResult>> disposeAll() async {
    blockNewWork();
    final ids = _connections.keys.toList(growable: false);
    final outcomes = await Future.wait([
      for (final id in ids) release(id).then((result) => (id, result)),
    ]);
    final results = <String, NativeStopResult>{
      for (final outcome in outcomes)
        if (outcome.$2 != null) outcome.$1: outcome.$2!,
    };
    if (_connections.isEmpty && !_changesController.isClosed) {
      await _changesController.close();
    }
    return results;
  }
}

final relayConnectionManagerProvider = Provider<MachineConnectionManager>((
  ref,
) {
  final mgr = MachineConnectionManager(
    crypto: ref.read(cryptoServiceProvider),
    // `ref.container`, not `ref`: the sign-out teardown outlives this callback
    // and reads providers across several awaits.
    onDeviceRevoked: () => unawaited(handleDeviceRevoked(ref.container)),
  );
  ref.onDispose(() => unawaited(mgr.disposeAll().then<void>((_) {})));
  return mgr;
});

/// Rebuild trigger for `peek()`-based consumers: emits on every connection
/// add/remove so a provider that watches this alongside `peek(uuid)` reacts to
/// a machine coming online/offline.
final relayConnectionChangesProvider = StreamProvider<int>((ref) {
  return ref.watch(relayConnectionManagerProvider).connectionChanges;
});
