import 'dart:async';
import 'dart:math';

import '../util/ab_log.dart';
import '../util/detached.dart';
import 'supervisor_state.dart';

class ConnectionAttemptCancelled implements Exception {}

const String _component = 'ConnectionSupervisor';

class ConnCoords {
  const ConnCoords({required this.relayUrl, required this.agentEd25519PubB64});
  final String relayUrl;
  final String agentEd25519PubB64;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnCoords &&
          other.relayUrl == relayUrl &&
          other.agentEd25519PubB64 == agentEd25519PubB64);
  @override
  int get hashCode => Object.hash(relayUrl, agentEd25519PubB64);
  @override
  String toString() => 'ConnCoords($relayUrl, $agentEd25519PubB64)';
}

/// Required native payload contract. Each method performs one bounded attempt;
/// the supervisor is the sole retry authority.
abstract interface class PeerConnectionContract {
  Future<ConnCoords?> resolveCoords();
  Future<void> connectPayload(ConnCoords coords);
  bool get payloadConnected;
  Future<void> establishSession();
  bool get sessionEstablished;
  Future<void> release();
}

/// Central authentication is maintained alongside, never as a payload rung.
abstract interface class CentralControlMechanisms {
  bool get centralControlNeedsReconnect;
  Future<void> reconnectCentral(ConnCoords coords);
}

const int _kMaxInitialHandshakeAttempts = 6;
const int kMaxPayloadFailuresPerCoords = 3;

class _RungBackoff {
  int attempt = 0;
  DateTime? nextAttemptAt;
  void reset() {
    attempt = 0;
    nextAttemptAt = null;
  }
}

/// Level-triggered policy for one machine's native payload.
class ConnectionSupervisor {
  ConnectionSupervisor(
    this._mech, {
    this.backoffBaseMs = 1000,
    this.backoffCapMs = 30000,
    int Function(int maxExclusive)? jitter,
  }) : _jitter = jitter ?? _defaultJitter;

  final PeerConnectionContract _mech;
  final int backoffBaseMs;
  final int backoffCapMs;
  final int Function(int maxExclusive) _jitter;

  static final Random _random = Random();
  static int _defaultJitter(int maxExclusive) =>
      maxExclusive <= 0 ? 0 : _random.nextInt(maxExclusive);

  final StreamController<SupervisorStatus> _statuses =
      StreamController<SupervisorStatus>.broadcast();
  final StreamController<bool> _centralConflicts =
      StreamController<bool>.broadcast();
  final _centralBackoff = _RungBackoff();
  final Map<ConnRung, _RungBackoff> _backoff = {
    for (final rung in ConnRung.values) rung: _RungBackoff(),
  };

  SupervisorStatus _status = const Released();
  ConnCoords? _coords;
  bool _wanted = false;
  bool _disposed = false;
  bool _evaluating = false;
  bool _rerun = false;
  bool _centralInFlight = false;
  bool _centralConflict = false;
  int _payloadFailuresSinceCoords = 0;
  Timer? _timer;
  Timer? _centralTimer;

  SupervisorStatus get status => _status;
  bool get centralConflict => _centralConflict;

  Stream<SupervisorStatus> get statusStream =>
      Stream<SupervisorStatus>.multi((controller) {
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

  Stream<bool> get centralConflictStream => Stream<bool>.multi((controller) {
    controller.add(_centralConflict);
    if (_centralConflicts.isClosed) {
      controller.close();
      return;
    }
    final sub = _centralConflicts.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  }, isBroadcast: true);

  void setWanted(bool wanted) {
    if (_wanted != wanted) {
      _wanted = wanted;
      _clearBlock();
      _resetAllBackoff();
      _payloadFailuresSinceCoords = 0;
    }
    _kick();
  }

  void notePayloadDown() => _kick();

  void noteCentralStateChanged() => _kick();

  /// Presence is only a bounded wake-up hint for a disconnected native peer.
  void notePresence(bool online) {
    if (online && !_mech.payloadConnected) {
      _backoff[ConnRung.payload]!.reset();
      _kick();
    }
  }

  void noteSessionDown() => _kick();

  void notePeerRejected() {
    _block(BlockReason.peerRejected);
    _kick();
  }

  void noteSessionTakenOver() {
    _block(BlockReason.sessionTakenOver);
    _kick();
  }

  /// Central errors do not affect a healthy native payload unless they revoke
  /// the account identity which authorizes its lease.
  void noteRelayError(String code, {required bool retryable}) {
    switch (code) {
      case 'LICENSE_EXPIRED':
        _block(BlockReason.licenseExpired);
      case 'LICENSE_REVOKED':
      case 'LICENSE_INVALID':
        _block(BlockReason.deviceRevoked);
      case 'SUPERSEDED':
        _setCentralConflict(true);
        _centralTimer?.cancel();
        _centralTimer = null;
      default:
        break;
    }
    _kick();
  }

  void noteFreshToken() {
    if (_status == const Blocked(BlockReason.licenseExpired)) {
      _emit(const Climbing(ConnRung.wanted));
    }
    _centralBackoff.reset();
    _kick();
  }

  void noteCoordsChanged() {
    _coords = null;
    _payloadFailuresSinceCoords = 0;
    _backoff[ConnRung.coords]!.reset();
    _kick();
  }

  void noteResume() => _kick();

  /// Explicit Retry is the only operation that clears central supersession.
  void retry() {
    _clearBlock();
    _setCentralConflict(false);
    _resetAllBackoff();
    _centralBackoff.reset();
    _coords = null;
    _payloadFailuresSinceCoords = 0;
    _kick();
  }

  Future<void> evaluate() async {
    if (_disposed) return;
    if (_evaluating) {
      _rerun = true;
      return;
    }
    _evaluating = true;
    try {
      do {
        _rerun = false;
        await _runOnce();
      } while (_rerun && !_disposed);
    } finally {
      _evaluating = false;
    }
  }

  Future<void> _runOnce() async {
    if (_disposed) return;
    if (!_wanted) {
      _cancelTimers();
      _coords = null;
      _resetAllBackoff();
      _payloadFailuresSinceCoords = 0;
      await _mech.release();
      _emit(const Released());
      return;
    }

    _maintainCentral();
    if (_status is Blocked) {
      _timer?.cancel();
      _timer = null;
      return;
    }

    final rung = _lowestBrokenRung();
    if (rung == null) {
      _timer?.cancel();
      _timer = null;
      _resetAllBackoff();
      _emit(const Connected());
      _maintainCentral();
      return;
    }

    _emit(Climbing(ConnRung.values[rung.index - 1]));
    final backoff = _backoff[rung]!;
    final due = backoff.nextAttemptAt;
    if (due != null && due.isAfter(DateTime.now())) {
      _arm(due);
      return;
    }
    backoff.nextAttemptAt = null;

    try {
      switch (rung) {
        case ConnRung.coords:
          _coords = await _mech.resolveCoords();
        case ConnRung.payload:
          final coords = _coords;
          if (coords == null) {
            _rerun = true;
            return;
          }
          await _mech.connectPayload(coords);
        case ConnRung.established:
          await _mech.establishSession();
        case ConnRung.wanted:
          return;
      }
    } on ConnectionAttemptCancelled {
      return;
    } catch (error) {
      AbLog.warn(
        _component,
        '${rung.name} attempt failed: $error',
        fields: {'rung': rung.name, 'error': '$error'},
      );
      _failed(rung);
      return;
    }

    if (_disposed) return;
    if (_isSatisfied(rung)) {
      backoff.reset();
      if (rung == ConnRung.payload) _payloadFailuresSinceCoords = 0;
      await evaluate();
      return;
    }

    AbLog.warn(
      _component,
      'rung step returned without satisfying the rung',
      fields: {'rung': rung.name},
    );
    _failed(rung);
  }

  void _maintainCentral() {
    if (_mech is! CentralControlMechanisms) return;
    final mechanisms = _mech as CentralControlMechanisms;
    if (_centralConflict ||
        !mechanisms.centralControlNeedsReconnect ||
        _centralInFlight ||
        _disposed ||
        !_wanted) {
      return;
    }
    final due = _centralBackoff.nextAttemptAt;
    if (due != null && due.isAfter(DateTime.now())) {
      _centralTimer ??= Timer(due.difference(DateTime.now()), () {
        _centralTimer = null;
        _kick();
      });
      return;
    }
    final coords = _coords;
    if (coords == null) return;
    _centralInFlight = true;
    detached(_component, 'central control maintenance', () async {
      try {
        await mechanisms.reconnectCentral(coords);
        if (mechanisms.centralControlNeedsReconnect) {
          throw StateError('Central reconnect not admitted');
        }
        _centralBackoff.reset();
      } catch (error) {
        if (!_centralConflict) {
          _centralBackoff.nextAttemptAt = DateTime.now().add(
            Duration(milliseconds: _backoffMs(_centralBackoff.attempt++)),
          );
        }
        AbLog.warn(
          _component,
          'central control reconnect failed: $error',
          fields: {'error': '$error'},
        );
      } finally {
        _centralInFlight = false;
        if (!_disposed && _wanted && !_centralConflict) _kick();
      }
    });
  }

  ConnRung? _lowestBrokenRung() {
    if (_coords == null) return ConnRung.coords;
    if (!_mech.payloadConnected) return ConnRung.payload;
    if (!_mech.sessionEstablished) return ConnRung.established;
    return null;
  }

  bool _isSatisfied(ConnRung rung) => switch (rung) {
    ConnRung.wanted => _wanted,
    ConnRung.coords => _coords != null,
    ConnRung.payload => _mech.payloadConnected,
    ConnRung.established => _mech.sessionEstablished,
  };

  void _failed(ConnRung rung) {
    if (_disposed) return;
    final backoff = _backoff[rung]!;
    final delayMs = _backoffMs(backoff.attempt);
    backoff.attempt++;

    if (rung == ConnRung.established &&
        backoff.attempt >= _kMaxInitialHandshakeAttempts) {
      _block(BlockReason.handshakeFailing);
      _timer?.cancel();
      _timer = null;
      return;
    }

    if (rung == ConnRung.payload) {
      _payloadFailuresSinceCoords++;
      if (_payloadFailuresSinceCoords >= kMaxPayloadFailuresPerCoords) {
        _payloadFailuresSinceCoords = 0;
        _coords = null;
        _backoff[ConnRung.coords]!.reset();
      }
    }

    final due = DateTime.now().add(Duration(milliseconds: delayMs));
    backoff.nextAttemptAt = due;
    _arm(due);
  }

  int _backoffMs(int attempt) {
    final window = min(backoffBaseMs << attempt.clamp(0, 30), backoffCapMs);
    if (window <= 0) return 0;
    return window ~/ 2 + _jitter(window) ~/ 2;
  }

  void _kick() {
    scheduleMicrotask(() {
      if (_disposed) return;
      _maintainCentral();
      unawaited(evaluate());
    });
  }

  void _block(BlockReason reason) {
    AbLog.warn(
      _component,
      'climb blocked: ${reason.name}',
      fields: {'reason': reason.name},
    );
    _emit(Blocked(reason));
  }

  void _clearBlock() {
    if (_status is Blocked) _emit(const Climbing(ConnRung.wanted));
  }

  void _resetAllBackoff() {
    for (final backoff in _backoff.values) {
      backoff.reset();
    }
  }

  void _arm(DateTime at) {
    if (_disposed) return;
    _timer?.cancel();
    final delay = at.difference(DateTime.now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      _kick();
    });
  }

  void _cancelTimers() {
    _centralTimer?.cancel();
    _centralTimer = null;
    _timer?.cancel();
    _timer = null;
  }

  void _emit(SupervisorStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statuses.isClosed) _statuses.add(next);
  }

  void _setCentralConflict(bool conflict) {
    if (_centralConflict == conflict) return;
    _centralConflict = conflict;
    if (!_centralConflicts.isClosed) _centralConflicts.add(conflict);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    await _statuses.close();
    await _centralConflicts.close();
  }
}
