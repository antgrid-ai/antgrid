import 'dart:async';
import 'dart:convert';

import 'agent_transport.dart';
import 'buffered_agent_transport.dart';
import 'e2e/key_schedule.dart';
import 'e2e/transport.dart';
import 'frag.dart';
import 'frame.dart';
import 'models/connection_state.dart';
import 'models/relay_message.dart';
import 'models/stream_envelope.dart';
import 'relay_service.dart';

/// v3 §6.2 liveness constants (mirror `bridge/src/relay-client.ts`).
const int kPingSilenceSeconds = 20;
const int kMaxMissedPongs = 2;
const int _kConsecutiveTimeoutsToRekey = 3;
const int _kMaxInitialHandshakeAttempts = 6;

/// Drives ONE E2E handshake attempt-cycle over a [MachineSession]'s socket,
/// completing only after the agent's sealed `established` (design §6.1 step 5).
/// The app implements this wrapping `ConnectionHandshake`; the package stays
/// Flutter-free. Each [perform] must run a FRESH attempt (new `attemptId`).
abstract class SessionHandshaker {
  /// Runs one full handshake to `established`. Returns the confirmed
  /// [SessionKeys], or null on timeout / verification failure.
  Future<SessionKeys?> perform();

  /// Abort any in-flight [perform] (session teardown / supersession).
  void abort();
}

/// Thrown into [MachineSession.ready] when the initial E2E handshake fails
/// repeatedly while the grant is live. Surfaces as the workspace error screen
/// (whose Retry rebuilds the connection) rather than an indefinite spinner.
class HandshakeException implements Exception {
  final String message;
  HandshakeException(this.message);
  @override
  String toString() => 'HandshakeException: $message';
}

/// Thrown by [MachineSession.bindProject] when the agent rejects the
/// `project:start` (`control:result {ok:false}` — e.g. `NOT_ALLOWED`,
/// `OPEN_FAILED`) so the caller fails with the real reason instead of a
/// blind timeout.
class ProjectBindException implements Exception {
  final String code;
  final String message;
  ProjectBindException(this.code, this.message);
  @override
  String toString() => 'ProjectBindException($code): $message';
}

/// One phone↔machine E2E session multiplexed over a single [RelayService]
/// socket. Owns the single [SessionKeys] set, the handshake/rekey driver, the
/// per-machine fragment reassembler, liveness, and the stream demux. Project
/// traffic rides sealed `{s, m}` envelopes; `s` absent/"0" is the machine
/// control plane. Replaces the v2 socket-per-project `RelayTransport`.
class MachineSession {
  final RelayService relay;

  /// The bare machine deviceUuid — the routing `to` for every outbound frame
  /// and the fragment-id namespace.
  final String machineDeviceId;

  final SessionHandshaker _handshaker;

  MachineSession({
    required this.relay,
    required this.machineDeviceId,
    required SessionHandshaker handshaker,
  }) : _handshaker = handshaker {
    // [ready] is observation-optional: failReady/dispose may completeError
    // before any awaiter attaches (see the getter doc). ignore() pre-registers
    // a swallowing listener so that never trips the unhandled-error zone hook;
    // every real `await ready` still receives the error.
    _readyCompleter.future.ignore();
    _armKeysReady();
  }

  SessionKeys? _keys;
  final Map<String, StreamTransport> _streams = {};

  StreamSubscription<IncomingRouteMessage>? _msgSub;
  StreamSubscription<AppState>? _stateSub;
  StreamSubscription<bool>? _presenceSub;
  Timer? _fragSweep;
  Timer? _livenessTimer;

  bool _disposed = false;
  bool _established = false;
  bool _routable = false;
  bool _handshakeInFlight = false;
  bool _peerWasOffline = false;
  int _missedPongs = 0;
  int _consecutiveTimeouts = 0;
  int _fragCounter = 0;
  DateTime _lastRecv = DateTime.now();

  final _readyCompleter = Completer<void>();

  /// Completes each time [_keys] are installed and is re-armed on socket loss,
  /// so a bind issued across a reconnect can wait for the next establishment
  /// instead of failing on the transient keyless window.
  late Completer<void> _keysReady;

  final _fragAborts = StreamController<FragHint>.broadcast();
  final _fragSendErrors = StreamController<FragSendError>.broadcast();
  final _streamReadyController =
      StreamController<({String projectId, String streamId})>.broadcast();

  /// projectId → streamId, learned from `agent:projects` / `stream-ready`.
  final Map<String, String> _projectStreamIds = {};
  final Map<String, Completer<String>> _streamReadyWaiters = {};

  late final FragReassembler _reassembler = FragReassembler(
    timeoutMs: kTransferTimeoutMs,
    globalBudgetBytes: kGlobalReassemblyBudget,
    onComplete: (json, channel) => _dispatchDecoded(json, channel),
    onAbort: (hint) {
      if (hint != null && !_fragAborts.isClosed) _fragAborts.add(hint);
    },
  );

  /// Completes on first `established`; errors with [HandshakeException] if the
  /// initial handshake exhausts its attempts, or if the session is disposed.
  ///
  /// Errors may land before anyone awaits (e.g. [failReady] when the pair step
  /// throws and the caller rethrows the ORIGINAL error instead of awaiting
  /// [ready], or dispose-before-established) — the `ignore()` in the
  /// constructor keeps those from surfacing as unhandled async errors while
  /// real awaiters still observe them.
  Future<void> get ready => _readyCompleter.future;

  /// `true` once the E2E session is established at least once and still live.
  bool get isEstablished => _established;

  Stream<FragHint> get fragmentAborts => _fragAborts.stream;
  Stream<FragSendError> get fragmentSendErrors => _fragSendErrors.stream;

  /// Emits `(projectId, streamId)` when the agent advertises a project's stream
  /// (`stream-ready`, or an `agent:projects` entry carrying `streamId`).
  Stream<({String projectId, String streamId})> get streamReadyEvents =>
      _streamReadyController.stream;

  /// The streamId the agent has advertised for [projectId], or null if not yet
  /// bound. A non-null result means [streamFor] can bind at 0 RTT.
  String? streamIdForProject(String projectId) => _projectStreamIds[projectId];

  /// Begin driving the session: subscribe to the socket, arm the paired→
  /// handshake trigger. Call once, right after construction.
  void start() {
    _msgSub = relay.messageStream.listen(_onRouted);
    _stateSub = relay.stateStream.listen(_onState);
    _presenceSub = relay.peerPresenceStream.listen(_onPresence);
    _fragSweep = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _reassembler.sweep(),
    );
    if (relay.currentState.connectionState == RelayConnectionState.paired) {
      _routable = true;
      unawaited(_runHandshake(rekey: false));
    }
  }

  /// Fail [ready] with [error] — used when the pairing step (grant creation)
  /// fails before a handshake can even start.
  void failReady(Object error, StackTrace st) {
    if (!_readyCompleter.isCompleted) _readyCompleter.completeError(error, st);
  }

  /// Create/return the [AgentTransport] view for [streamId]. `"0"` is the
  /// machine control plane.
  StreamTransport streamFor(String streamId) {
    final existing = _streams[streamId];
    if (existing != null) return existing;
    final st = StreamTransport(session: this, streamId: streamId);
    _streams[streamId] = st;
    // Seed durable state if the session is already live; otherwise the next
    // (re)establish refreshes every attached stream.
    if (_established) unawaited(st.refreshSnapshot());
    return st;
  }

  /// Bind a project to its stream: return a known streamId at 0 RTT, else send
  /// [startMessage] (a `project:start`) on the control plane and await the
  /// agent's `stream-ready` (design §7.4).
  Future<String> bindProject(
    String projectId,
    Map<String, dynamic> startMessage, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final known = _projectStreamIds[projectId];
    if (known != null) return known;
    // One deadline spans both waits below, so a bind can never take 2×[timeout].
    final deadline = DateTime.now().add(timeout);
    // sendOnStream drops silently without keys, so the start message has to
    // wait for them. Keys are per-connection and nulled on every socket blip
    // while the reconnect re-establishes within seconds — treating that window
    // as a hard failure turns a routine blip into a user-visible bind error.
    if (_keys == null) {
      try {
        await _keysReady.future.timeout(_remainingUntil(deadline));
      } on TimeoutException {
        throw StateError('bindProject: E2E session not established');
      }
      // The post-establish `agent:projects` re-advert may have bound the
      // project while we waited — no need to ask the agent to start it again.
      final rebound = _projectStreamIds[projectId];
      if (rebound != null) return rebound;
    }
    final waiter = _streamReadyWaiters.putIfAbsent(projectId, () {
      final c = Completer<String>();
      // A control:result rejection may completeError during the send await gap
      // below, before this method's own await attaches — same pattern as
      // [_readyCompleter] (real awaiters still receive the error).
      c.future.ignore();
      return c;
    });
    await sendOnStream(kControlStreamId, startMessage, 'control');
    // The waiter is shared by every concurrent bind of this project, so one
    // caller's deadline must not evict it: `.timeout()` leaves the completer
    // itself pending, and dropping the map entry would strand the other callers
    // where _recordProjectStream can no longer reach them. dispose() clears it.
    return waiter.future.timeout(_remainingUntil(deadline));
  }

  /// Wrap [message] as a sealed `{s, m}` envelope and send it (fragmenting past
  /// the threshold). Dropped when no keys are installed (pre-establishment /
  /// mid-reconnect) — the bridge replays durable state via `state.snapshot`.
  Future<void> sendOnStream(
    String streamId,
    Map<String, dynamic> message,
    String channel,
  ) async {
    final keys = _keys;
    if (keys == null) return;
    final envelope = <String, dynamic>{
      if (streamId != kControlStreamId) 's': streamId,
      'm': message,
    };
    final plaintext = jsonEncode(envelope);
    final t = E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p);
    final bytes = utf8.encode(plaintext).length;
    try {
      if (bytes <= kFragThreshold) {
        relay.sendMessage(machineDeviceId, channel, await t.seal(plaintext));
        return;
      }
      if (bytes > kMaxTransferBytes) {
        if (!_fragSendErrors.isClosed) {
          _fragSendErrors.add(FragSendError(
            'MESSAGE_TOO_LARGE',
            '${message['type'] ?? 'message'} exceeds kMaxTransferBytes',
          ));
        }
        return;
      }
      final type = message['type'] as String?;
      final path = message['path'] as String?;
      final hint = type == 'file:content' && path != null
          ? FragHint('file:content', path)
          : null;
      // Fragment the ENVELOPE JSON so `s` survives reassembly; the id is unique
      // per (machine, stream, counter) — the agent reassembles by bare id.
      final id = '$machineDeviceId-$streamId-${_fragCounter++}';
      for (final fragment in buildFragments(plaintext, id, hint)) {
        relay.sendMessage(machineDeviceId, channel, await t.seal(fragment));
      }
    } catch (_) {
      // best-effort send
    }
  }

  void notifyRpcResult({required bool timedOut}) {
    if (!timedOut) {
      _consecutiveTimeouts = 0;
      return;
    }
    _consecutiveTimeouts++;
    if (_consecutiveTimeouts >= _kConsecutiveTimeoutsToRekey &&
        _established &&
        !_handshakeInFlight) {
      _consecutiveTimeouts = 0;
      unawaited(_rekey());
    }
  }

  void removeStream(String streamId) => _streams.remove(streamId);

  // --- socket / presence transitions ---------------------------------------

  void _onState(AppState s) {
    final paired = s.connectionState == RelayConnectionState.paired;
    if (paired && !_routable) {
      _routable = true;
      if (!_established && !_handshakeInFlight) {
        unawaited(_runHandshake(rekey: false));
      }
    }
    if (s.connectionState == RelayConnectionState.disconnected) {
      _onSocketDown();
    }
  }

  void _onPresence(bool present) {
    if (!present) {
      _peerWasOffline = true;
      return;
    }
    if (_peerWasOffline) {
      _peerWasOffline = false;
      if (_established && !_handshakeInFlight) unawaited(_rekey());
    }
  }

  void _armKeysReady() {
    _keysReady = Completer<void>();
    // dispose() can fail this before any [bindProject] awaits it — same
    // unobserved-error guard as [_readyCompleter].
    _keysReady.future.ignore();
  }

  void _onSocketDown() {
    // Session keys are per-connection; a socket drop invalidates them. A fresh
    // paired transition on the reconnected socket re-establishes.
    _established = false;
    _routable = false;
    _stopLiveness();
    _keys?.zeroize();
    _keys = null;
    // Re-arm only from the completed state: a second blip before the first
    // establishment would otherwise orphan whoever is already awaiting.
    if (_keysReady.isCompleted) _armKeysReady();
  }

  // --- handshake / rekey ----------------------------------------------------

  Future<void> _rekey() async {
    if (_disposed || !_established) return;
    await _runHandshake(rekey: true);
  }

  Future<void> _runHandshake({required bool rekey}) async {
    if (_disposed || _handshakeInFlight) return;
    _handshakeInFlight = true;
    try {
      var attempt = 0;
      while (!_disposed) {
        final newKeys = await _handshaker.perform();
        if (_disposed) {
          newKeys?.zeroize();
          return;
        }
        if (newKeys != null) {
          // Make-before-break: swap AFTER the new attempt confirmed, then
          // zeroize the superseded keys (no dropped traffic on the old keys).
          final old = _keys;
          _keys = newKeys;
          old?.zeroize();
          if (!_keysReady.isCompleted) _keysReady.complete();
          _established = true;
          _peerWasOffline = false;
          _lastRecv = DateTime.now();
          _missedPongs = 0;
          _consecutiveTimeouts = 0;
          _startLiveness();
          if (!_readyCompleter.isCompleted) _readyCompleter.complete();
          // Re-pull durable state on every (re)establish so late subscribers
          // (a ControlPlaneClient, a just-bound project stream) replay it.
          for (final s in _streams.values) {
            unawaited(s.refreshSnapshot());
          }
          return;
        }
        // Failed attempt. The phone owns retry pacing with jittered backoff.
        attempt++;
        if (!rekey && attempt >= _kMaxInitialHandshakeAttempts) {
          if (!_readyCompleter.isCompleted) {
            _readyCompleter.completeError(
              HandshakeException(
                'E2E handshake failed after $attempt attempts',
              ),
            );
          }
          return;
        }
        await Future<void>.delayed(_handshakeBackoff(attempt));
        if (_disposed || !_routable) return;
      }
    } finally {
      _handshakeInFlight = false;
    }
  }

  Duration _handshakeBackoff(int attempt) {
    final shift = attempt.clamp(0, 5);
    final ms = 500 * (1 << shift);
    final capped = ms > 15000 ? 15000 : ms;
    return Duration(milliseconds: capped);
  }

  // --- liveness -------------------------------------------------------------

  void _startLiveness() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(
      const Duration(seconds: kPingSilenceSeconds),
      (_) => _checkLiveness(),
    );
  }

  void _stopLiveness() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _missedPongs = 0;
  }

  void _checkLiveness() {
    if (_disposed || !_established || _handshakeInFlight) return;
    final silentFor = DateTime.now().difference(_lastRecv).inSeconds;
    if (silentFor < kPingSilenceSeconds) return;
    if (_missedPongs >= kMaxMissedPongs) {
      // Session declared dead at the E2E layer → rekey on the live socket.
      _stopLiveness();
      unawaited(_rekey());
      return;
    }
    _missedPongs++;
    unawaited(_sendSessionFrame({'type': 'ping'}).catchError((_) {}));
  }

  // --- inbound dispatch -----------------------------------------------------

  void _onRouted(IncomingRouteMessage msg) {
    // Kind-1 (handshake) plaintext frames belong to the handshake driver, which
    // subscribes to the same messageStream and does its own dispatch.
    if (msg.kind == FrameKind.handshake) return;
    final keys = _keys;
    if (keys == null) return; // pre-establishment: driver owns sealed frames
    unawaited(_decryptAndDispatch(msg, keys));
  }

  Future<void> _decryptAndDispatch(
    IncomingRouteMessage msg,
    SessionKeys keys,
  ) async {
    final plaintext =
        await E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p)
            .open(msg.payload);
    // A candidate-key handshake frame during rekey (agent-ready/established) or
    // garbage → decrypt-or-drop.
    if (plaintext == null) return;
    _lastRecv = DateTime.now();
    _missedPongs = 0;
    if (_reassembler.accept(plaintext, channel: msg.channel)) return;
    _dispatchDecoded(plaintext, msg.channel);
  }

  void _dispatchDecoded(String plaintext, String channel) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = json['type'];
    // Sealed-payload disambiguation (v3 §7.1): a top-level `type` string is a
    // session/liveness frame; an `m` field is stream/app traffic.
    if (type is String) {
      _handleSessionFrame(type);
      return;
    }
    if (!json.containsKey('m')) return;
    final env = StreamEnvelope.fromJson(json);
    if (env == null) return;
    final sid = (env.s == null || env.s == kControlStreamId)
        ? kControlStreamId
        : env.s!;
    final m = env.m;
    _snoopControl(sid, m);
    final st = _streams[sid];
    if (st != null && m is Map<String, dynamic>) {
      st.dispatchFromSession(m, channel);
    }
  }

  /// Snoop control-plane adverts for project→stream bindings so [bindProject]
  /// can resolve at 0 RTT and drill-in `stream-ready` waiters resolve. Called
  /// for LIVE frames and for `state.snapshot`-replayed frames alike — the
  /// bridge's replay-cache dedup can legally suppress a byte-identical live
  /// re-advert after an app kill+reopen, so the snapshot pull is the reconnect
  /// binding contract (design §7.4), not a cache warm-up.
  void _snoopControl(String sid, Object? m) {
    if (sid != kControlStreamId || m is! Map<String, dynamic>) return;
    final type = m['type'];
    if (type == 'stream-ready') {
      final pid = m['projectId'];
      final streamId = m['streamId'];
      if (pid is String && streamId is String) _recordProjectStream(pid, streamId);
    } else if (type == 'agent:projects') {
      final projects = m['projects'];
      if (projects is List) {
        // The advert is the agent's COMPLETE dialable catalog: an entry without
        // a streamId (or a project absent entirely) is not dialable. Drop stale
        // bindings — after an agent restart the old ids point at dead streams
        // and sends to them vanish with no feedback.
        final next = <String, String>{};
        for (final p in projects) {
          if (p is Map<String, dynamic>) {
            final pid = p['projectId'];
            final streamId = p['streamId'];
            if (pid is String && streamId is String) next[pid] = streamId;
          }
        }
        _projectStreamIds.removeWhere((pid, _) => !next.containsKey(pid));
        next.forEach(_recordProjectStream);
      }
    } else if (type == 'control:result' && m['ok'] == false) {
      // A rejected project:start (NOT_ALLOWED / OPEN_FAILED /
      // SESSION_LIMIT_EXCEEDED) — fail the pending bind with the real reason
      // instead of letting it run out its blind timeout.
      final pid = m['projectId'];
      if (pid is String) {
        final waiter = _streamReadyWaiters.remove(pid);
        if (waiter != null && !waiter.isCompleted) {
          final err = m['error'];
          waiter.completeError(ProjectBindException(
            err is Map && err['code'] is String ? err['code'] as String : 'UNKNOWN',
            err is Map && err['message'] is String ? err['message'] as String : '',
          ));
        }
      }
    }
  }

  void _recordProjectStream(String projectId, String streamId) {
    _projectStreamIds[projectId] = streamId;
    final waiter = _streamReadyWaiters.remove(projectId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(streamId);
    if (!_streamReadyController.isClosed) {
      _streamReadyController.add((projectId: projectId, streamId: streamId));
    }
  }

  void _handleSessionFrame(String type) {
    switch (type) {
      case 'ping':
        unawaited(_sendSessionFrame({'type': 'pong'}).catchError((_) {}));
        break;
      case 'pong':
        _missedPongs = 0;
        break;
      // 'established' / 'handshake:agent-ready' are decrypted under the
      // handshake's candidate keys and owned by the driver; a stale copy here
      // (already-swapped keys) is ignored.
    }
  }

  Future<void> _sendSessionFrame(Map<String, dynamic> obj) async {
    final keys = _keys;
    if (keys == null) return;
    final ct = await E2eTransportDart(sendKey: keys.p2a, recvKey: keys.a2p)
        .seal(jsonEncode(obj));
    relay.sendMessage(machineDeviceId, 'control', ct);
  }

  Future<void> dispose() async {
    _disposed = true;
    _handshaker.abort();
    _stopLiveness();
    _fragSweep?.cancel();
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    await _presenceSub?.cancel();
    for (final s in List<StreamTransport>.of(_streams.values)) {
      await s.dispose();
    }
    _streams.clear();
    for (final w in _streamReadyWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('session disposed'));
    }
    _streamReadyWaiters.clear();
    await _fragAborts.close();
    await _fragSendErrors.close();
    await _streamReadyController.close();
    _keys?.zeroize();
    _keys = null;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(StateError('session disposed'));
    }
    if (!_keysReady.isCompleted) {
      _keysReady.completeError(StateError('session disposed'));
    }
  }
}

/// Time left before [deadline], floored at zero — a negative [Duration] passed
/// to `Future.timeout` is not a meaningful budget.
Duration _remainingUntil(DateTime deadline) {
  final left = deadline.difference(DateTime.now());
  return left.isNegative ? Duration.zero : left;
}

/// The per-project (or per-control-plane) [AgentTransport] view over a
/// [MachineSession] stream. Interface-compatible with the old socket-per-project
/// transport: services and `BufferedAgentTransport` RPC plumbing are unchanged;
/// `send()` delegates to the session tagged with this stream's id, and
/// `dispatchFromSession` receives only this stream's decoded messages.
class StreamTransport extends BufferedAgentTransport {
  final MachineSession session;
  final String streamId;

  StreamTransport({required this.session, required this.streamId});

  @override
  bool get isLocal => false;

  @override
  Future<void> connect() async {
    setState(TransportState.connected);
    // Seed durable state — but only when the session can carry the request:
    // without keys sendOnStream drops it and the RPC would burn its full
    // timeout to report what is already known. Nothing is lost, since every
    // attached stream is refreshed on each (re)establish.
    if (!session.isEstablished) return;
    await _fetchSnapshot(timeout: const Duration(seconds: 10));
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) =>
      session.sendOnStream(streamId, message, channel);

  @override
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final r = await super.request(method, params: params, timeout: timeout);
      session.notifyRpcResult(timedOut: false);
      return r;
    } on RpcException catch (e) {
      // ≥3 consecutive E_TIMEOUTs is a rekey trigger (design §6.2).
      session.notifyRpcResult(timedOut: e.code == 'E_TIMEOUT');
      rethrow;
    }
  }

  /// Deliver a decoded message that the session demuxed to this stream.
  void dispatchFromSession(Map<String, dynamic> json, String channel) =>
      dispatchDecoded(json, channel);

  /// Re-pull the durable-state snapshot now that session keys are (re)installed.
  Future<void> refreshSnapshot() =>
      _fetchSnapshot(timeout: const Duration(seconds: 5));

  Future<void> _fetchSnapshot({required Duration timeout}) async {
    try {
      final snap = await request(
        'state.snapshot',
        params: {
          'types': ['*'],
        },
        timeout: timeout,
      );
      final frames = (snap['frames'] as List?) ?? const [];
      final fresh = <InboundMessage>[];
      for (final raw in frames) {
        if (raw is Map) {
          final m = raw.cast<String, dynamic>();
          // Snapshot-replayed frames must feed the session's stream-binding
          // map exactly like live frames: the bridge's replay-cache dedup can
          // suppress the live re-advert after an app kill+reopen, making this
          // pull the ONLY carrier of `agent:projects{streamId}` (design §7.4).
          // No-op for non-control streams.
          session._snoopControl(streamId, m);
          fresh.add(InboundMessage('control', m));
        }
      }
      snapshotCache
        ..clear()
        ..addAll(fresh);
      if (!outbound.isClosed) {
        for (final m in fresh) {
          outbound.add(m);
        }
      }
    } on RpcException {
      // Pre-RPC agent or timeout — leave the existing cache untouched.
    }
  }

  @override
  Future<void> dispose() async {
    failAllPending();
    snapshotCache.clear();
    session.removeStream(streamId);
    await outbound.close();
    await stateController.close();
  }
}
