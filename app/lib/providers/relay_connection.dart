import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_supervisor.dart';
import '../connection/relay_mechanisms.dart';
import '../connection/supervisor_state.dart';
import '../util/device_id.dart';
import 'providers.dart';

/// Owns exactly one relay socket (one [RelayService]) and its single
/// [MachineSession] for one bare machine `deviceUuid`. v3: there is ONE socket
/// per machine — the control plane and every project ride sealed streams inside
/// the one E2E session (design §2). No sub-deviceId, no socket-per-project.
///
/// The connection is not opened by its callers: a [ConnectionSupervisor] owns
/// dial, redial and give-up, and callers only declare that they want it
/// ([ensureStarted]) and wait for the result ([awaitSession]).
class RelayConnection {
  final String machineDeviceId;
  final RelayService relay;

  RelayConnection({
    required this.machineDeviceId,
    required CryptoService crypto,
    // Test seam: inject a fake RelayService. Production passes null.
    RelayService? relayOverride,
  }) : relay = relayOverride ?? RelayService(crypto: crypto);

  RelayMechanisms? _mechanisms;
  ConnectionSupervisor? _supervisor;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;

  final StreamController<SupervisorStatus?> _statuses =
      StreamController<SupervisorStatus?>.broadcast();
  SupervisorStatus? _status;

  final StreamController<void> _sessionReplacements =
      StreamController<void>.broadcast();

  /// Fires when this machine's [MachineSession] is swapped for a fresh one
  /// (the agent re-provisioned its Ed25519 identity, so the coords step
  /// returned a new pin). Every project bound to this machine must rebuild its
  /// transport: the swap disposed the [StreamTransport] each of them holds.
  ///
  /// Deliberately NOT emitted on [dispose] — a released connection already has
  /// the reaper and the registry's `onEvict` invalidating its transports.
  Stream<void> get sessionReplacements => _sessionReplacements.stream;

  /// The live [MachineSession] once a dial has created it, else null.
  MachineSession? get session => _mechanisms?.session;

  /// The policy engine driving this machine, or null before [ensureStarted].
  ConnectionSupervisor? get supervisor => _supervisor;

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
  /// connection that no longer has a socket.
  Stream<SupervisorStatus?> get statusStream =>
      Stream<SupervisorStatus?>.multi((controller) {
        controller.add(_status);
        if (_statuses.isClosed) {
          controller.close();
          return;
        }
        final sub = _statuses.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      }, isBroadcast: true);

  void _publishStatus(SupervisorStatus? status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }

  /// Declare that this machine's connection is wanted, constructing the
  /// supervisor on the first call. Later calls are no-ops: the supervisor is
  /// per-machine and every project on the machine rides the same one, so the
  /// second project to resolve must not restart the ladder.
  ///
  /// [mechanisms] is typed concretely because the connection exposes the
  /// adapter's [MachineSession] — the streams every project binds to.
  void ensureStarted({required RelayMechanisms mechanisms}) {
    if (_disposed || _supervisor != null) return;
    _mechanisms = mechanisms;
    final supervisor = _supervisor = ConnectionSupervisor(mechanisms);
    mechanisms.onTerminalAuthError = (code) =>
        supervisor.noteRelayError(code, retryable: false);
    mechanisms.onSessionTakenOver = supervisor.noteSessionTakenOver;
    mechanisms.onSessionDown = supervisor.noteSessionDown;
    mechanisms.onSessionReplaced = () {
      if (!_sessionReplacements.isClosed) _sessionReplacements.add(null);
    };
    // Level-triggered inputs: each one only tells the supervisor that something
    // changed, never what to do about it.
    _subs.add(
      relay.stateStream.listen((s) {
        supervisor.noteSocketState(
          authenticated:
              s.connectionState.index >=
              RelayConnectionState.authenticated.index,
        );
        if (s.connectionState == RelayConnectionState.disconnected) {
          supervisor.noteSessionDown();
        }
      }),
    );
    _subs.add(
      relay.errorStream.listen(
        (e) => supervisor.noteRelayError(e.code, retryable: e.retryable),
      ),
    );
    // One listener, mechanism first: the supervisor re-derives the ladder
    // synchronously inside notePresence and reads `mechanisms.agentOnline`
    // while doing it. Two separate subscriptions would let it read the level
    // one microtask stale and charge a full routable stall to every return of
    // an agent that is already back.
    _subs.add(
      relay.peerPresenceStream.listen((online) {
        mechanisms.notePresence(online);
        supervisor.notePresence(online);
      }),
    );
    // Replays the supervisor's current status first, so subscribers that were
    // already listening to [statusStream] pick the ladder up here.
    _subs.add(supervisor.statusStream.listen(_publishStatus));
    supervisor.setWanted(true);
  }

  /// Waits for this machine's E2E session to be usable.
  ///
  /// Throws [ConnectionBlockedException] the moment the supervisor stops
  /// climbing (agent offline, license, superseded…) so the caller surfaces the
  /// reason instead of spinning, and [TimeoutException] if neither happens.
  Future<MachineSession> awaitSession({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final supervisor = _supervisor;
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
      // timeout waiting for a machine that no longer has a socket.
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

  /// App resume: hand the supervisor a plain re-evaluate so a connection that
  /// was sitting on a long backoff while the app was in the background climbs
  /// now instead of waiting out a timer the OS may have frozen.
  void noteResume() => _supervisor?.noteResume();

  /// Terminal teardown: disposes the [MachineSession] (which fails its pending
  /// RPCs, cancels subscriptions, zeroizes keys) and the underlying
  /// [RelayService]. Only called when dropping a machine for good.
  ///
  /// Everything observable synchronously — status, streams, supervisor — is gone
  /// the moment this returns, but the socket itself drops only when the returned
  /// future completes: releasing the E2E session is asynchronous, and the
  /// supervisor cannot do it for us (`setWanted(false)` only schedules its
  /// evaluation, and the `dispose()` below cancels it). Fire-and-forget callers
  /// may ignore the future; anyone who must not touch the [RelayService] until
  /// it is really gone has to await it.
  Future<void> dispose() {
    _disposed = true;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    // The supervisor's own Released never reaches anyone here: `dispose()`
    // closes its controller before the release evaluation queued below can
    // emit. Say it ourselves, or every consumer keeps rendering this machine's
    // last live status — including Connected — for a socket that is gone.
    _publishStatus(const Released());
    unawaited(_statuses.close());
    // Closed before the teardown below: a subscriber that outlived this
    // connection must not be handed a replacement it would rebuild a transport
    // onto, when the connection it belongs to is already gone.
    unawaited(_sessionReplacements.close());
    final supervisor = _supervisor;
    _supervisor = null;
    // `ConnectionSupervisor.dispose` deliberately does NOT release, so disposing
    // alone would leave an authenticated socket and a live E2E session with
    // nothing managing them — still holding this machine's relay slot. Release
    // explicitly (it is idempotent, so a release the supervisor already ran is
    // harmless).
    supervisor?.setWanted(false);
    final mechanisms = _mechanisms;
    _mechanisms = null;
    return _teardown(supervisor, mechanisms);
  }

  /// Release BEFORE disposing the relay: release closes the E2E session and
  /// drops the socket through the live [RelayService], and doing that after
  /// `dispose()` closed its controllers throws on the state emit.
  Future<void> _teardown(
    ConnectionSupervisor? supervisor,
    RelayMechanisms? mechanisms,
  ) async {
    if (supervisor != null) await supervisor.dispose();
    if (mechanisms != null) await mechanisms.release();
    relay.dispose();
  }

  bool get isDisposed => _disposed;
}

/// Holds the app's live relay sockets, one [RelayConnection] per bare machine
/// `deviceUuid`. Every machine gets exactly one socket; project streams
/// multiplex inside it.
class RelayConnectionManager {
  final CryptoService _crypto;
  final Map<String, RelayConnection> _connections = {};
  final _changesController = StreamController<int>.broadcast();
  int _changeSeq = 0;

  RelayConnectionManager({required CryptoService crypto}) : _crypto = crypto;

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

  RelayConnection connectionFor(String machineDeviceId) {
    // Normalize here, not at call sites: the map key IS the v3 invariant (one
    // connection per machine), so a compound `<uuid>.<projectId>` id must land
    // on the same slot as its bare machine uuid no matter who dials.
    final key = baseDeviceUuid(machineDeviceId);
    final existing = _connections[key];
    if (existing != null) return existing;
    final conn = RelayConnection(machineDeviceId: key, crypto: _crypto);
    _connections[key] = conn;
    _notifyChanged();
    return conn;
  }

  RelayConnection? peek(String machineDeviceId) =>
      _connections[baseDeviceUuid(machineDeviceId)];

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
  /// `RelayMechanisms.mintToken()`, which runs as part of a rung step and
  /// would reset that rung's backoff before the dial it belongs to is scored
  /// (see `ConnectionSupervisor.noteFreshToken`'s doc comment).
  void noteFreshTokenEverywhere() {
    for (final c in _connections.values) {
      if (c.supervisor?.status == const Blocked(BlockReason.licenseExpired)) {
        c.supervisor?.noteFreshToken();
      }
    }
  }

  /// Bare deviceUuids of every currently-open machine socket. In v3 every
  /// connection is a machine socket (the control plane and its projects share
  /// it), so this is just the live key set.
  List<String> openControlPlaneIds() =>
      _connections.keys.toList(growable: false);

  void release(String machineDeviceId) {
    final removed = _connections.remove(baseDeviceUuid(machineDeviceId));
    if (removed != null) {
      unawaited(removed.dispose());
      _notifyChanged();
    }
  }

  void disposeAll() {
    for (final c in _connections.values) {
      unawaited(c.dispose());
    }
    _connections.clear();
    _changesController.close();
  }
}

final relayConnectionManagerProvider = Provider<RelayConnectionManager>((ref) {
  final mgr = RelayConnectionManager(crypto: ref.read(cryptoServiceProvider));
  ref.onDispose(mgr.disposeAll);
  return mgr;
});

/// Rebuild trigger for `peek()`-based consumers: emits on every connection
/// add/remove so a provider that watches this alongside `peek(uuid)` reacts to
/// a machine coming online/offline.
final relayConnectionChangesProvider = StreamProvider<int>((ref) {
  return ref.watch(relayConnectionManagerProvider).connectionChanges;
});
