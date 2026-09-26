import 'dart:async';
import 'dart:math';

import '../providers/seeded_stream.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'supervisor_state.dart';

class ConnectionAttemptCancelled implements Exception {}

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
}

sealed class PeerConnectionEvent {
  const PeerConnectionEvent();
}

class PeerTerminalAuthError extends PeerConnectionEvent {
  const PeerTerminalAuthError(this.code);
  final String code;
}

class PeerTerminalError extends PeerConnectionEvent {
  const PeerTerminalError();
}

class PeerSessionDown extends PeerConnectionEvent {
  const PeerSessionDown();
}

class PeerSessionReplaced extends PeerConnectionEvent {
  const PeerSessionReplaced();
}

enum NativeStopResult { stopped, cleanupIncomplete }

abstract interface class PeerConnectionContract {
  Stream<PeerConnectionEvent> get events;
  Future<ConnCoords?> resolveCoords();
  Future<void> connectPayload(ConnCoords coords);
  bool get payloadConnected;
  Future<void> establishSession();
  bool get sessionEstablished;
  void fenceDispatch();
  Future<void> release();
  Future<void> forceClose();
}

abstract interface class CentralControlContract {
  Stream<String> get authErrorStream;
  bool get needsReconnect;
  Future<void> connect(ConnCoords coords);
  void disconnect();
}

const int _kMaxInitialHandshakeAttempts = 6;
const int kMaxPayloadFailuresPerCoords = 3;
const Duration kPresenceRetryAccelerationCooldown = Duration(seconds: 30);

class _Backoff {
  int attempt = 0;
  DateTime? nextAttemptAt;
  void reset() {
    attempt = 0;
    nextAttemptAt = null;
  }
}

typedef SupervisorTimerFactory =
    Timer Function(Duration duration, void Function() callback);

class NativeConnectionSupervisor {
  NativeConnectionSupervisor(
    this._mech, {
    this.backoffBaseMs = 1000,
    this.backoffCapMs = 30000,
    int Function(int maxExclusive)? jitter,
    DateTime Function()? now,
    SupervisorTimerFactory? timerFactory,
    this.gracefulStopTimeout = const Duration(seconds: 5),
    this.forcedStopTimeout = const Duration(seconds: 5),
    this.onCoordsResolved,
  }) : _jitter = jitter ?? _defaultJitter,
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? _defaultTimerFactory;

  final PeerConnectionContract _mech;
  final int backoffBaseMs;
  final int backoffCapMs;
  final int Function(int maxExclusive) _jitter;
  final DateTime Function() _now;
  final SupervisorTimerFactory _timerFactory;
  final Duration gracefulStopTimeout;
  final Duration forcedStopTimeout;
  final void Function(ConnCoords coords)? onCoordsResolved;

  static final Random _random = Random();
  static int _defaultJitter(int max) => max <= 0 ? 0 : _random.nextInt(max);
  static Timer _defaultTimerFactory(Duration d, void Function() callback) =>
      Timer(d, callback);

  final _statuses = StreamController<SupervisorStatus>.broadcast(sync: true);
  final Map<ConnRung, _Backoff> _backoff = {
    for (final rung in ConnRung.values) rung: _Backoff(),
  };
  SupervisorStatus _status = const Released();
  ConnCoords? _coords;
  bool _wanted = false;
  bool _stopping = false;
  bool _rerun = false;
  bool _presenceOnline = false;
  DateTime? _lastPresenceWakeAt;
  int _payloadFailuresSinceCoords = 0;
  Timer? _timer;
  Future<void>? _evaluation;
  Future<NativeStopResult>? _stopFuture;

  SupervisorStatus get status => _status;
  ConnCoords? get coords => _coords;
  Stream<SupervisorStatus> get statusStream =>
      seededStream(() => _status, _statuses.stream);

  void setWanted(bool wanted) {
    if (_stopping) return;
    if (!wanted) {
      unawaited(stop());
      return;
    }
    if (!_wanted) {
      _wanted = true;
      _clearBlock();
      _resetAllBackoff();
      _payloadFailuresSinceCoords = 0;
    }
    _kick();
  }

  void notePayloadDown() => _kick();

  void notePresence(bool online) {
    final rising = online && !_presenceOnline;
    _presenceOnline = online;
    if (!rising || _mech.payloadConnected || _stopping) return;
    final now = _now();
    final last = _lastPresenceWakeAt;
    if (last != null &&
        now.difference(last) < kPresenceRetryAccelerationCooldown) {
      return;
    }
    _lastPresenceWakeAt = now;
    final payload = _backoff[ConnRung.payload]!;
    if (payload.nextAttemptAt != null) payload.nextAttemptAt = now;
    _timer?.cancel();
    _timer = null;
    _kick();
  }

  void noteSessionDown() => _kick();
  void notePeerRejected() {
    _block(BlockReason.peerRejected);
    _kick();
  }

  void noteAuthError(String code) {
    switch (code) {
      case 'LICENSE_EXPIRED':
        _block(BlockReason.licenseExpired);
      case 'LICENSE_REVOKED':
      case 'LICENSE_INVALID':
        _block(BlockReason.deviceRevoked);
      default:
        break;
    }
    _kick();
  }

  void noteFreshToken() {
    if (_status == const Blocked(BlockReason.licenseExpired)) {
      _emit(const Climbing(ConnRung.wanted));
    }
    _kick();
  }

  void noteCoordsChanged() {
    _coords = null;
    _payloadFailuresSinceCoords = 0;
    _backoff[ConnRung.coords]!.reset();
    _kick();
  }

  void noteResume() => _kick();

  void retry() {
    if (_stopping) return;
    _clearBlock();
    _resetAllBackoff();
    _coords = null;
    _payloadFailuresSinceCoords = 0;
    _kick();
  }

  Future<void> evaluate() {
    if (_stopping) return Future<void>.value();
    final running = _evaluation;
    if (running != null) {
      _rerun = true;
      return running;
    }
    late final Future<void> evaluation;
    evaluation = _evaluateLoop().whenComplete(() {
      if (identical(_evaluation, evaluation)) _evaluation = null;
    });
    _evaluation = evaluation;
    return evaluation;
  }

  Future<void> _evaluateLoop() async {
    do {
      _rerun = false;
      await _runOnce();
    } while (_rerun && !_stopping);
  }

  Future<void> _runOnce() async {
    if (_stopping || !_wanted || _status is Blocked) return;
    final rung = _lowestBrokenRung();
    if (rung == null) {
      _timer?.cancel();
      _timer = null;
      _resetAllBackoff();
      _emit(const Connected());
      return;
    }
    _emit(Climbing(ConnRung.values[rung.index - 1]));
    final backoff = _backoff[rung]!;
    final due = backoff.nextAttemptAt;
    if (due != null && due.isAfter(_now())) {
      _arm(due);
      return;
    }
    backoff.nextAttemptAt = null;
    try {
      switch (rung) {
        case ConnRung.coords:
          final coords = await _mech.resolveCoords();
          if (_stopping) return;
          _coords = coords;
          if (coords != null) onCoordsResolved?.call(coords);
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
      if (_stopping) return;
      AbLog.warn(
        'NativeConnectionSupervisor',
        '${rung.name} attempt failed: $error',
        fields: {'rung': rung.name, 'error': '$error'},
      );
      _failed(rung);
      return;
    }
    if (_stopping) return;
    if (_isSatisfied(rung)) {
      backoff.reset();
      if (rung == ConnRung.payload) _payloadFailuresSinceCoords = 0;
      _rerun = true;
      return;
    }
    _failed(rung);
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
    if (_stopping) return;
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
    final due = _now().add(Duration(milliseconds: delayMs));
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
      if (!_stopping) unawaited(evaluate());
    });
  }

  void _block(BlockReason reason) {
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
    if (_stopping) return;
    _timer?.cancel();
    final delay = at.difference(_now());
    _timer = _timerFactory(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      _kick();
    });
  }

  void _emit(SupervisorStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statuses.isClosed) _statuses.add(next);
  }

  Future<NativeStopResult> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    _stopping = true;
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    _mech.fenceDispatch();
    return _stopFuture = _stop(_evaluation);
  }

  Future<NativeStopResult> _stop(Future<void>? evaluation) async {
    final graceful = Future.wait<void>([_mech.release(), ?evaluation]);
    if (await _completesSuccessfullyWithin(graceful, gracefulStopTimeout)) {
      _emit(const Released());
      unawaited(_statuses.close());
      return NativeStopResult.stopped;
    }
    final forced = _mech.forceClose();
    if (await _completesSuccessfullyWithin(
      Future.wait<void>([graceful, forced]),
      forcedStopTimeout,
    )) {
      _emit(const Released());
      unawaited(_statuses.close());
      return NativeStopResult.stopped;
    }
    AbLog.error(
      'NativeConnectionSupervisor',
      'native cleanup did not confirm ownership release',
    );
    unawaited(_statuses.close());
    return NativeStopResult.cleanupIncomplete;
  }

  static Future<bool> _completesSuccessfullyWithin(
    Future<void> future,
    Duration timeout,
  ) => Future.any<bool>([
    future.then<bool>((_) => true, onError: (_, _) => false),
    Future<bool>.delayed(timeout, () => false),
  ]);

  Future<void> dispose() async {
    await stop();
  }
}

class CentralControlSupervisor {
  CentralControlSupervisor(
    this._mech, {
    this.backoffBaseMs = 1000,
    this.backoffCapMs = 30000,
    int Function(int maxExclusive)? jitter,
    DateTime Function()? now,
    SupervisorTimerFactory? timerFactory,
  }) : _jitter = jitter ?? NativeConnectionSupervisor._defaultJitter,
       _now = now ?? DateTime.now,
       _timerFactory =
           timerFactory ?? NativeConnectionSupervisor._defaultTimerFactory;

  final CentralControlContract _mech;
  final int backoffBaseMs;
  final int backoffCapMs;
  final int Function(int maxExclusive) _jitter;
  final DateTime Function() _now;
  final SupervisorTimerFactory _timerFactory;
  final _backoff = _Backoff();
  final _conflicts = StreamController<bool>.broadcast(sync: true);
  ConnCoords? _coords;
  bool _wanted = false;
  bool _conflict = false;
  bool _inFlight = false;
  bool _stopping = false;
  int _generation = 0;
  Timer? _timer;
  Future<void>? _stopFuture;

  bool get conflict => _conflict;
  Stream<bool> get conflictStream =>
      seededStream(() => _conflict, _conflicts.stream);

  void setWanted(bool wanted) {
    if (_stopping) return;
    _wanted = wanted;
    if (!wanted) {
      unawaited(stop());
      return;
    }
    _kick();
  }

  void noteCoords(ConnCoords coords) {
    if (_coords != coords) {
      final previous = _coords;
      if (previous != null && previous.relayUrl != coords.relayUrl) {
        _mech.disconnect();
      }
      _coords = coords;
      _backoff.reset();
    }
    _kick();
  }

  void noteStateChanged() => _kick();
  void noteRelayError(String code) {
    if (code != 'SUPERSEDED') return;
    _setConflict(true);
    _timer?.cancel();
    _timer = null;
  }

  void retry() {
    if (_stopping) return;
    _setConflict(false);
    _backoff.reset();
    _kick();
  }

  void _kick() {
    if (_stopping ||
        !_wanted ||
        _conflict ||
        _inFlight ||
        !_mech.needsReconnect) {
      return;
    }
    final coords = _coords;
    if (coords == null) return;
    final due = _backoff.nextAttemptAt;
    if (due != null && due.isAfter(_now())) {
      _timer ??= _timerFactory(due.difference(_now()), () {
        _timer = null;
        _kick();
      });
      return;
    }
    _backoff.nextAttemptAt = null;
    _inFlight = true;
    final generation = _generation;
    detached(
      'CentralControlSupervisor',
      'central control maintenance',
      () async {
        try {
          await _mech.connect(coords);
          if (_stopping || generation != _generation) return;
          if (_mech.needsReconnect) {
            throw StateError('Central reconnect not admitted');
          }
          _backoff.reset();
        } catch (error) {
          if (!_stopping && !_conflict && generation == _generation) {
            _backoff.nextAttemptAt = _now().add(
              Duration(milliseconds: _backoffMs(_backoff.attempt++)),
            );
          }
          AbLog.warn(
            'CentralControlSupervisor',
            'central control reconnect failed: $error',
            fields: {'error': '$error'},
          );
        } finally {
          _inFlight = false;
          if (!_stopping && _wanted && !_conflict) _kick();
        }
      },
    );
  }

  int _backoffMs(int attempt) {
    final window = min(backoffBaseMs << attempt.clamp(0, 30), backoffCapMs);
    if (window <= 0) return 0;
    return window ~/ 2 + _jitter(window) ~/ 2;
  }

  void _setConflict(bool value) {
    if (_conflict == value) return;
    _conflict = value;
    if (!_conflicts.isClosed) _conflicts.add(value);
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    _stopping = true;
    _wanted = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _mech.disconnect();
    unawaited(_conflicts.close());
    return _stopFuture = Future<void>.value();
  }

  Future<void> dispose() => stop();
}
