import 'dart:async';
import 'dart:math';

import 'supervisor_state.dart';

/// Where a machine lives right now: relay endpoint plus the agent identity the
/// handshake pins against.
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

/// One step per broken rung; the supervisor decides WHETHER, mechanisms know HOW.
///
/// Every member is a single attempt with no retry logic of its own — retry
/// timing, ordering and give-up are the supervisor's, so there is exactly one
/// place in the app that decides when to try again.
abstract class ConnMechanisms {
  /// null → coords rung broken, retry later.
  Future<ConnCoords?> resolveCoords();

  /// MUST be fresh per call (no caching here).
  Future<String> mintToken();

  /// One attempt; completes on welcome, throws otherwise.
  ///
  /// MUST NOT complete before [socketAuthenticated] reads true. The supervisor
  /// re-reads the rung the instant this future resolves, and scores a step that
  /// "succeeded" onto a still-broken rung as a failure — that is what stops a
  /// dial which silently no-ops from hot-looping. So resolving even one
  /// microtask ahead of the flag turns every healthy dial into a backed-off
  /// failure and the connection never reports Connected.
  Future<void> dial(ConnCoords coords, String token);

  /// welcome received, socket open.
  bool get socketAuthenticated;

  /// presence for THIS machine.
  bool get agentOnline;

  /// One E2E handshake attempt; throws on failure.
  ///
  /// MUST NOT complete before [sessionEstablished] reads true — same scoring
  /// rule as [dial], with a worse penalty: six attempts that resolve ahead of
  /// the flag land on Blocked(handshakeFailing) over a perfectly healthy
  /// session, and only an explicit user retry() gets out of it.
  Future<void> establishSession();

  bool get sessionEstablished;

  /// Tear everything down (wanted == false).
  ///
  /// MUST be idempotent: this runs on EVERY evaluation while `wanted == false`,
  /// so any late input arriving after a teardown calls it again on an already
  /// released connection.
  Future<void> release();
}

/// Mirrors the app handshake driver's initial-attempt ceiling: past this many
/// consecutive failures the peer is not going to complete a handshake for
/// reasons a retry cannot fix, so surface it instead of looping.
const int _kMaxInitialHandshakeAttempts = 6;

/// The routable rung has no step of its own — presence is pushed by the peer.
/// After this many evaluations still stuck there with the socket up, stop
/// pretending we are climbing and say the agent is offline.
const int _kMaxRoutableStalls = 3;

/// Consecutive `SUPERSEDED` rejections tolerated before the connection is
/// declared lost to another holder.
///
/// On current relays (design §6.3 equal-epoch rule) a redial presenting this
/// launch's own epoch under the same key evicts its zombie and admits, so
/// consecutive rejections can only come from a genuinely newer holder — a
/// later launch of this install. The tolerance is kept for relays predating
/// that rule, which reject a hello whose epoch is lower OR EQUAL to the live
/// holder's: there, a phone whose socket died without the relay noticing
/// (Wi-Fi→cellular, no FIN) rejects its own redial until the relay's
/// liveness sweep drops the stale entry. That sweep runs on `pingIntervalMs`
/// (30s) and closes a socket silent for `pingIntervalMs + pongTimeoutMs`
/// (40s), so the stale entry can survive ~70s.
///
/// Sized off the FLOOR of the socket rung's backoff, not its mean: the N-th
/// rejection is preceded by N-1 delays, and equal jitter makes every delay at
/// least half its window, so the nine delays before the tenth rejection are
/// worth at least 500 + 1000 + 2000 + 4000 + 8000 + 15000x4 ms = 75.5s (1s
/// base, 30s cap). One fewer would floor at 60.5s and clear the sweep window
/// only on average. A genuinely newer holder simply keeps rejecting and lands
/// on the block.
///
/// A count rather than a wall-clock deadline on purpose: OS timers freeze
/// while the app is backgrounded, so an elapsed-time give-up would block on
/// the first rejection after a long suspend having made exactly one attempt.
/// "Ten dials lost" is a claim about the peer; "90 seconds passed" is not.
///
/// The epoch is deliberately NOT bumped on `SUPERSEDED`: the same code fires
/// when a real newer instance of this install holds the id, and out-epoching
/// it would let the older instance steal it back, forever.
const int kMaxSupersededRetries = 10;

/// Consecutive socket-rung failures tolerated before the coordinates are
/// re-resolved.
///
/// The coords step answers "where does this machine live", and a host that
/// moved relay or re-provisioned its Ed25519 identity makes every dial at the
/// old answer unwinnable. Nothing else invalidates the cached answer, so the
/// socket rung's own failures are the signal. Kept small because re-resolving
/// is cheap next to a dial, and large enough that an ordinary relay blip is
/// absorbed by backoff alone.
const int kMaxSocketFailuresPerCoords = 3;

class _RungBackoff {
  int attempt = 0;
  DateTime? nextAttemptAt;

  void reset() {
    attempt = 0;
    nextAttemptAt = null;
  }
}

/// Level-triggered connection policy for ONE machine.
///
/// Every input does the same two things: update state, then [evaluate]. No
/// input reacts to its own event — [evaluate] re-derives the whole ladder from
/// current mechanism state, so a missed edge costs at most one late evaluation
/// instead of a permanently dead connection.
class ConnectionSupervisor {
  ConnectionSupervisor(
    this._mech, {
    this.backoffBaseMs = 1000,
    this.backoffCapMs = 30000,
    this.routableStallMs = 2000,
    int Function(int maxExclusive)? jitter,
  }) : _jitter = jitter ?? _defaultJitter;

  final ConnMechanisms _mech;
  final int backoffBaseMs;
  final int backoffCapMs;

  /// How long a routable stall waits before counting the next one.
  ///
  /// The routable rung runs no step, so nothing it does can re-arm the ladder:
  /// without a timer here the stall count only advances when some unrelated
  /// input happens to evaluate, and an agent that is simply not running leaves
  /// the UI on [Climbing] forever instead of reaching
  /// `Blocked(agentOffline)` — the one status that tells the user why.
  final int routableStallMs;
  final int Function(int maxExclusive) _jitter;

  static final Random _random = Random();
  static int _defaultJitter(int maxExclusive) =>
      maxExclusive <= 0 ? 0 : _random.nextInt(maxExclusive);

  final StreamController<SupervisorStatus> _statuses =
      StreamController<SupervisorStatus>.broadcast();

  final Map<ConnRung, _RungBackoff> _backoff = <ConnRung, _RungBackoff>{
    for (final rung in ConnRung.values) rung: _RungBackoff(),
  };

  SupervisorStatus _status = const Released();
  ConnCoords? _coords;
  bool _wanted = false;
  bool _disposed = false;
  bool _evaluating = false;
  bool _rerun = false;
  int _routableStalls = 0;
  int _supersededRejections = 0;
  int _socketFailuresSinceCoords = 0;
  bool _lastSocketErrorSuperseded = false;

  /// One timer for the whole ladder, re-armed each time. Only the lowest broken
  /// rung ever runs, so only its backoff can be pending.
  Timer? _timer;

  SupervisorStatus get status => _status;

  /// Broadcast, and replays the current status to every new listener so a
  /// widget that subscribes late still renders the real state.
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

  // ---------------------------------------------------------------- inputs

  void setWanted(bool wanted) {
    if (_wanted != wanted) {
      _wanted = wanted;
      // A deliberate stop/start is a clean slate: nothing about the previous
      // lifetime should still be blocking or backing off.
      _clearBlock();
      _resetAllBackoff();
      _resetSocketAdmissionCounters();
    }
    _kick();
  }

  void noteSocketState({required bool authenticated}) {
    if (!authenticated) {
      // Presence only means anything while the socket is up.
      _routableStalls = 0;
    } else {
      _noteSocketAdmitted();
    }
    _kick();
  }

  /// The relay admitted this epoch, so whatever the socket rung collected on
  /// the way here was transient by definition.
  void _noteSocketAdmitted() => _resetSocketAdmissionCounters();

  /// Everything the socket rung accumulates on its way to being admitted.
  void _resetSocketAdmissionCounters() {
    _supersededRejections = 0;
    _socketFailuresSinceCoords = 0;
    _lastSocketErrorSuperseded = false;
  }

  void notePresence(bool online) {
    if (online) {
      _unblockOn(<BlockReason>{
        BlockReason.agentOffline,
        BlockReason.handshakeFailing,
      });
      _routableStalls = 0;
      // The peer just came back — the handshake that kept failing against an
      // absent agent deserves an immediate attempt, not the old backoff.
      _backoff[ConnRung.established]!.reset();
    }
    _kick();
  }

  void noteSessionDown() => _kick();

  void noteSessionTakenOver() {
    // Sticky by design: another device holds the session. Re-establishing on
    // presence would make the two devices evict each other forever, so only an
    // explicit user retry() reclaims it.
    _block(BlockReason.sessionTakenOver);
    _kick();
  }

  /// Classification is by [code] alone. `retryable` describes whether the RELAY
  /// will accept more frames, which is orthogonal to whether the ladder can
  /// climb: the codes below are terminal for this supervisor whatever the flag
  /// says, and everything else is already paced by the failing rung's own
  /// backoff. It stays in the signature because the relay error contract always
  /// carries it and callers forward it verbatim.
  void noteRelayError(String code, {required bool retryable}) {
    switch (code) {
      case 'LICENSE_EXPIRED':
        _block(BlockReason.licenseExpired);
      case 'LICENSE_REVOKED':
      case 'LICENSE_INVALID':
        _block(BlockReason.deviceRevoked);
      case 'SUPERSEDED':
        // Not terminal on sight: the commonest source is this app's OWN stale
        // relay-side entry after a network change, which the relay's liveness
        // sweep clears on its own — the same epoch is then admitted. Only
        // persistence proves a genuinely newer holder. The socket rung's
        // backoff paces the retries; see [kMaxSupersededRetries].
        _supersededRejections++;
        // Consumed by the next socket failure: a relay that answers with
        // SUPERSEDED is reachable AT these coordinates and recognises this
        // deviceId, so re-resolving them cannot help. See [_failed].
        _lastSocketErrorSuperseded = true;
        if (_supersededRejections >= kMaxSupersededRetries) {
          _block(BlockReason.superseded);
        }
      default:
        // Retryable or not, an unclassified error has no terminal meaning here;
        // the failing step's own backoff already paces the retry.
        break;
    }
    _kick();
  }

  /// Producer: `RelayConnectionManager.noteFreshTokenEverywhere`, called from
  /// `AppShell._reconnectRelay` after an out-of-band re-mint on app resume.
  /// Never call this from the socket rung's own `mintToken` step — that would
  /// reset the rung's backoff before the dial it belongs to is scored.
  void noteFreshToken() {
    _unblockOn(<BlockReason>{BlockReason.licenseExpired});
    // A new token is new information — dial now rather than serving out the
    // backoff earned by the stale one.
    _backoff[ConnRung.socket]!.reset();
    _kick();
  }

  /// Producers: [retry], and the socket rung itself once it has failed
  /// [kMaxSocketFailuresPerCoords] times in a row — nothing outside the ladder
  /// watches the account inventory, so the dials that cannot succeed are the
  /// only evidence that the cached answer went stale.
  void noteCoordsChanged() {
    _coords = null;
    _socketFailuresSinceCoords = 0;
    _backoff[ConnRung.coords]!.reset();
    _unblockOn(<BlockReason>{BlockReason.agentOffline});
    // Without this the stall count carried over from the block that just
    // cleared, so the first routable check at the new endpoint tripped
    // straight back into agentOffline before presence had any chance to land.
    _routableStalls = 0;
    _kick();
  }

  /// App resume — pure re-evaluate.
  void noteResume() => _kick();

  /// User action: clears Blocked + backoff, re-resolves coords, evaluate.
  ///
  /// Retry deliberately drops the cached coordinates too. It is the user's
  /// "something out there changed" input, and a machine that moved relay or
  /// re-provisioned its identity is unreachable at the cached answer no matter
  /// how many times the dial is repeated.
  void retry() {
    _clearBlock();
    _resetAllBackoff();
    _routableStalls = 0;
    _coords = null;
    _resetSocketAdmissionCounters();
    _kick();
  }

  // ------------------------------------------------------------- evaluation

  /// Idempotent; single-flight with a rerun flag.
  ///
  /// Concurrent callers do not each drive the ladder: the first one runs, the
  /// rest raise [_rerun] so exactly one extra pass happens after it. That makes
  /// "an input arrived mid-step" cost one more pass, never a spin.
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
      _cancelTimer();
      _coords = null;
      _resetAllBackoff();
      _routableStalls = 0;
      _resetSocketAdmissionCounters();
      await _mech.release();
      _emit(const Released());
      return;
    }

    if (_status is Blocked) {
      _cancelTimer();
      return;
    }

    final rung = _lowestBrokenRung();
    if (rung == null) {
      _cancelTimer();
      _resetAllBackoff();
      _routableStalls = 0;
      _emit(const Connected());
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

    if (rung == ConnRung.routable) {
      _stallOnRoutable();
      return;
    }

    try {
      switch (rung) {
        case ConnRung.coords:
          _coords = await _mech.resolveCoords();
        case ConnRung.socket:
          // Minted per attempt and never stored: a cached token outlives its
          // TTL across a long backoff and every later dial fails on a token
          // that was valid when the first one was made.
          final token = await _mech.mintToken();
          final coords = _coords;
          if (coords == null) {
            // noteCoordsChanged() landed mid-mint: the endpoint this dial was
            // built for no longer exists. Falling through would charge the
            // SOCKET backoff for a coords event and delay the connection for a
            // reason that has nothing to do with the socket.
            _rerun = true;
            return;
          }
          await _mech.dial(coords, token);
        case ConnRung.established:
          await _mech.establishSession();
        case ConnRung.wanted:
        case ConnRung.routable:
          return;
      }
    } catch (_) {
      _failed(rung);
      return;
    }

    if (_disposed) return;

    if (_isSatisfied(rung)) {
      backoff.reset();
      if (rung == ConnRung.socket) _noteSocketAdmitted();
      // Climb: under the single-flight guard this schedules one more pass.
      await evaluate();
      return;
    }

    // The step reported success but the rung is still down (dial completed
    // without a welcome, handshake returned without a session). Treat it as a
    // failure so it backs off instead of hot-looping.
    _failed(rung);
  }

  void _stallOnRoutable() {
    // Nothing to run — routing comes back when the agent announces presence.
    _routableStalls++;
    if (_routableStalls >= _kMaxRoutableStalls) {
      _block(BlockReason.agentOffline);
      _cancelTimer();
      return;
    }
    _arm(DateTime.now().add(Duration(milliseconds: routableStallMs)));
  }

  ConnRung? _lowestBrokenRung() {
    if (_coords == null) return ConnRung.coords;
    if (!_mech.socketAuthenticated) return ConnRung.socket;
    if (!_mech.agentOnline) return ConnRung.routable;
    if (!_mech.sessionEstablished) return ConnRung.established;
    return null;
  }

  bool _isSatisfied(ConnRung rung) => switch (rung) {
    ConnRung.wanted => _wanted,
    ConnRung.coords => _coords != null,
    ConnRung.socket => _mech.socketAuthenticated,
    ConnRung.routable => _mech.agentOnline,
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
      _cancelTimer();
      return;
    }

    if (rung == ConnRung.socket) {
      // A supersede storm is not evidence of stale coordinates — the relay at
      // those coordinates answered, and by name. Counting it would spend an
      // /account/agents fetch and a coords rebuild every third rejection on a
      // condition no address can fix.
      final superseded = _lastSocketErrorSuperseded;
      _lastSocketErrorSuperseded = false;
      if (!superseded) {
        _socketFailuresSinceCoords++;
        if (_socketFailuresSinceCoords >= kMaxSocketFailuresPerCoords) {
          // Drop the cached endpoint so the next pass runs the coords step
          // again. The socket backoff is deliberately left standing: it is what
          // paces this, and a host that keeps refusing must not be re-dialled
          // faster just because the coords were re-asked.
          _socketFailuresSinceCoords = 0;
          _coords = null;
          _backoff[ConnRung.coords]!.reset();
        }
      }
    }

    final due = DateTime.now().add(Duration(milliseconds: delayMs));
    backoff.nextAttemptAt = due;
    _arm(due);
  }

  /// Equal jitter over the doubling window: the injected function receives the
  /// window itself (`min(base * 2^attempt, cap)`), which is what tests assert
  /// on, and half of it is always waited so a jitter of 0 can never produce a
  /// zero-delay retry storm.
  int _backoffMs(int attempt) {
    final window = min(backoffBaseMs << attempt.clamp(0, 30), backoffCapMs);
    if (window <= 0) return 0;
    return window ~/ 2 + _jitter(window) ~/ 2;
  }

  // ---------------------------------------------------------------- helpers

  /// Defers the evaluation to a fresh microtask instead of running
  /// [evaluate]'s synchronous prefix on the input's own call stack. Inputs
  /// arrive from arbitrary stacks — including Riverpod notification listeners
  /// firing inside the provider flush pass (ControlPlaneReaper's reconcile →
  /// [setWanted]) — and the ladder's first step can synchronously mutate
  /// providers (the coords rung's inventory refresh invalidates
  /// accountAgentsProvider). A provider mutation mid-flush trips Riverpod's
  /// reentrant-build guard ("Tried to rebuild ... multiple times in the same
  /// frame"; seen live on a drawer expand while a revoked machine's ladder was
  /// mid-retry). The supervisor is level-triggered, so evaluating one
  /// microtask later is semantically free — keep every side effect off the
  /// caller's stack.
  void _kick() {
    scheduleMicrotask(() {
      if (_disposed) return;
      unawaited(evaluate());
    });
  }

  void _block(BlockReason reason) {
    _emit(Blocked(reason));
  }

  /// Leaving a block is itself a transition listeners must see, so it is
  /// emitted rather than silently assigned — the next evaluation may land on a
  /// status equal to the one before the block and emit nothing.
  void _clearBlock() {
    if (_status is Blocked) {
      _emit(const Climbing(ConnRung.wanted));
    }
  }

  void _unblockOn(Set<BlockReason> reasons) {
    final current = _status;
    if (current is Blocked && reasons.contains(current.reason)) {
      _clearBlock();
    }
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

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _emit(SupervisorStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statuses.isClosed) {
      _statuses.add(next);
    }
  }

  /// Stops the policy engine. Deliberately does NOT tear the connection down:
  /// [ConnMechanisms.release] runs only from the `wanted == false` evaluation,
  /// which this skips.
  ///
  /// So a caller that wires lifetime the obvious way — `ref.onDispose(dispose)`
  /// — leaves an authenticated relay socket and a live E2E session with nothing
  /// left to manage them, and that orphaned socket holds the machine's relay
  /// slot (blocking a clean reconnect on it) until the process exits. To tear
  /// down, call `setWanted(false)` and let the release land first.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimer();
    await _statuses.close();
  }
}
