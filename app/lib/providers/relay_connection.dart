import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../relay/connection_handshake.dart';
import '../util/device_id.dart';
import 'providers.dart';

/// Caller-supplied step that drives [RelayConnection.relay] to `paired` — i.e.
/// creates the relay grant (first pair / trusted reconnect / same-account
/// autoOpen). Awaited by [RelayConnection.open] before the E2E session's
/// `ready` is awaited.
typedef PairFlow = Future<void> Function();

/// Owns exactly one relay socket (one [RelayService]) and its single
/// [MachineSession] for one bare machine `deviceUuid`. v3: there is ONE socket
/// per machine — the control plane and every project ride sealed streams inside
/// the one E2E session (design §2). No sub-deviceId, no socket-per-project.
class RelayConnection {
  final String machineDeviceId;
  final RelayService relay;

  RelayConnection({
    required this.machineDeviceId,
    required CryptoService crypto,
    // Test seam: inject a fake RelayService. Production passes null.
    RelayService? relayOverride,
  }) : relay = relayOverride ?? RelayService(crypto: crypto);

  MachineSession? _session;
  Future<MachineSession>? _openFuture;
  bool _disposed = false;

  /// The live [MachineSession] once [open] has run, else null.
  MachineSession? get session => _session;

  /// Drives connect → pair (grant) → E2E handshake and resolves this machine's
  /// [MachineSession]. Idempotent: a second call returns the same future.
  ///
  /// [pairFlow] is the caller's grant-establishment step (it must drive [relay]
  /// to `paired`). Once paired, the session's own listener runs the handshake
  /// and, on `established`, [MachineSession.ready] completes.
  Future<MachineSession> open({
    required PairFlow pairFlow,
    required CryptoService crypto,
    required String phoneDeviceId,
    required String agentEd25519PubB64,
    required List<int> phoneEd25519Seed,
  }) {
    return _openFuture ??= _open(
      pairFlow: pairFlow,
      crypto: crypto,
      phoneDeviceId: phoneDeviceId,
      agentEd25519PubB64: agentEd25519PubB64,
      phoneEd25519Seed: phoneEd25519Seed,
    );
  }

  Future<MachineSession> _open({
    required PairFlow pairFlow,
    required CryptoService crypto,
    required String phoneDeviceId,
    required String agentEd25519PubB64,
    required List<int> phoneEd25519Seed,
  }) async {
    final handshaker = AppSessionHandshaker(
      relay: relay,
      crypto: crypto,
      machineDeviceId: machineDeviceId,
      phoneDeviceId: phoneDeviceId,
      agentEd25519PubB64: agentEd25519PubB64,
      phoneEd25519Seed: phoneEd25519Seed,
    );
    final session = _session = MachineSession(
      relay: relay,
      machineDeviceId: machineDeviceId,
      handshaker: handshaker,
    );
    session.start();
    try {
      await pairFlow(); // grant creation → paired → session runs the handshake
    } catch (e, st) {
      session.failReady(e, st);
      rethrow;
    }
    await session.ready;
    return session;
  }

  /// Sever the relay grant when currently paired. Call before [dispose] for an
  /// INTENTIONAL unpair (agent removed / cancelled) — NOT a focus switch or
  /// reconnect, which must keep the grant alive.
  void unpair() {
    if (relay.currentState.connectionState == RelayConnectionState.paired) {
      relay.unpair();
    }
  }

  /// Terminal teardown: disposes the [MachineSession] (which fails its pending
  /// RPCs, cancels subscriptions, zeroizes keys) and the underlying
  /// [RelayService]. Only called when dropping a machine for good.
  void dispose() {
    _disposed = true;
    final session = _session;
    if (session != null) unawaited(session.dispose());
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
  final _changesController = StreamController<void>.broadcast();

  RelayConnectionManager({required CryptoService crypto}) : _crypto = crypto;

  /// Fires whenever a connection is added to or removed from [_connections].
  Stream<void> get connectionChanges => _changesController.stream;

  RelayConnection connectionFor(String machineDeviceId) {
    // Normalize here, not at call sites: the map key IS the v3 invariant (one
    // connection per machine), so a compound `<uuid>.<projectId>` id must land
    // on the same slot as its bare machine uuid no matter who dials.
    final key = baseDeviceUuid(machineDeviceId);
    final existing = _connections[key];
    if (existing != null) return existing;
    final conn = RelayConnection(
      machineDeviceId: key,
      crypto: _crypto,
    );
    _connections[key] = conn;
    _changesController.add(null);
    return conn;
  }

  RelayConnection? peek(String machineDeviceId) =>
      _connections[baseDeviceUuid(machineDeviceId)];

  /// Bare deviceUuids of every currently-open machine socket. In v3 every
  /// connection is a machine socket (the control plane and its projects share
  /// it), so this is just the live key set.
  List<String> openControlPlaneIds() =>
      _connections.keys.toList(growable: false);

  void release(String machineDeviceId) {
    final removed = _connections.remove(baseDeviceUuid(machineDeviceId));
    if (removed != null) {
      removed.dispose();
      _changesController.add(null);
    }
  }

  void disposeAll() {
    for (final c in _connections.values) {
      c.dispose();
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
final relayConnectionChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(relayConnectionManagerProvider).connectionChanges;
});

/// Read-only connection phase for [bareDeviceUuid]'s machine socket — `peek`
/// only, NEVER dials. Null when nothing has been dialed for this machine yet.
final machineConnectionPhaseProvider = StreamProvider.autoDispose
    .family<RelayConnectionState?, String>((ref, bareDeviceUuid) async* {
      ref.watch(relayConnectionChangesProvider);
      final conn = ref
          .read(relayConnectionManagerProvider)
          .peek(bareDeviceUuid);
      if (conn == null) {
        yield null;
        return;
      }
      yield conn.relay.currentState.connectionState;
      yield* conn.relay.stateStream.map((s) => s.connectionState);
    });
