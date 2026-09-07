import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'agent_transport.dart';
import 'buffered_agent_transport.dart';
import 'e2e/key_schedule.dart';
import 'e2e/transport.dart';
import 'flow.dart';
import 'frag.dart';
import 'frame.dart';
import 'models/connection_state.dart';
import 'models/relay_message.dart';
import 'models/stream_envelope.dart';
import 'relay_service.dart';
import 'send_scheduler.dart';

/// Liveness constants; mirror `bridge/src/relay-client.ts`.
/// Spec: docs/protocol/e2e-handshake.md §"Sealed liveness".
const int kPingSilenceSeconds = 20;
const int kMaxMissedPongs = 2;
const int _kConsecutiveTimeoutsToRekey = 3;

/// Drives ONE E2E handshake attempt-cycle over a [MachineSession]'s socket,
/// completing only after the agent's sealed `established`.
/// The app implements this wrapping `ConnectionHandshake`; the package stays
/// Flutter-free. Each [perform] must run a FRESH attempt (new `attemptId`).
abstract class SessionHandshaker {
  /// Runs one full handshake to `established`. Returns the confirmed
  /// [SessionKeys], or null on timeout / verification failure.
  Future<SessionKeys?> perform();

  /// Abort any in-flight [perform] (session teardown / supersession).
  void abort();
}

/// Thrown by [MachineSession.ensureEstablished] when the one handshake attempt
/// it drove did not reach `established`. Retry pacing and give-up belong to the
/// caller (the app's connection supervisor), which is why this reports a single
/// failed attempt rather than an exhausted budget.
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

  /// Builds the `project:start` control message used to re-bind a project the
  /// agent has declared dead (`stream-invalid`). Injected rather than built here
  /// because message construction (uuid ids) lives in the app layer, not in this
  /// pure-Dart package. Omitted → no self-heal, just the forgotten binding.
  final Map<String, dynamic> Function(String projectId)?
  projectStartMessageBuilder;

  /// Base wait for a `state.snapshot` pull. Each retry doubles it — see
  /// [StreamTransport.refreshSnapshot] for why a pull is retried at all.
  final Duration snapshotTimeout;

  /// Silence after which liveness sends a sealed `ping`, and the period the
  /// liveness timer itself runs at. Injectable so a test need not wait out the
  /// real interval.
  final Duration pingSilence;

  /// Bytes consumed on a channel between the credits this side volunteers. A
  /// tick credits both channels regardless, so this only decides how promptly a
  /// bulk transfer's window reopens.
  final int creditBatchBytes;

  MachineSession({
    required this.relay,
    required this.machineDeviceId,
    required SessionHandshaker handshaker,
    this.projectStartMessageBuilder,
    this.snapshotTimeout = const Duration(seconds: 5),
    this.pingSilence = const Duration(seconds: kPingSilenceSeconds),
    int? channelWindowBytes,
    int? socketInflightBytes,
    this.creditBatchBytes = kCreditBatchBytes,
  }) : _handshaker = handshaker,
       _channelWindowBytes = channelWindowBytes ?? kChannelWindowBytes,
       _socketInflightBytes = socketInflightBytes ?? kSocketInflightBytes {
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
  StreamSubscription<ErrorMessage>? _errorSub;
  Timer? _fragSweep;
  Timer? _livenessTimer;

  bool _disposed = false;
  bool _established = false;
  bool _handshakeInFlight = false;
  bool _peerWasOffline = false;
  int _missedPongs = 0;
  int _consecutiveTimeouts = 0;
  int _fragCounter = 0;
  DateTime _lastRecv = DateTime.now();

  /// The attempt [ensureEstablished] joins instead of starting a second one.
  /// Null whenever no handshake is running.
  Future<void>? _handshakeFuture;

  final _readyCompleter = Completer<void>();

  /// Completes each time [_keys] are installed and is re-armed on socket loss,
  /// so a bind issued across a reconnect can wait for the next establishment
  /// instead of failing on the transient keyless window.
  late Completer<void> _keysReady;

  final _established$ = StreamController<void>.broadcast();
  final _takeovers = StreamController<void>.broadcast();
  final _sessionDown = StreamController<void>.broadcast();
  final _fragAborts = StreamController<FragHint>.broadcast();
  final _fragSendErrors = StreamController<FragSendError>.broadcast();
  final _streamReadyController =
      StreamController<({String projectId, String streamId})>.broadcast();

  /// channel → the decrypt-and-dispatch chain currently draining for it. See
  /// [_onRouted]; an entry lives only while that channel has work in flight.
  final Map<String, Future<void>> _inboundTails = {};

  /// Sealed bytes allowed in flight per channel and across the socket before
  /// the agent must credit them.
  final int _channelWindowBytes;
  final int _socketInflightBytes;

  /// Cumulative sealed payload bytes received on each channel this session, and
  /// how much of that has already been credited back to the agent. Both reset at
  /// establishment, which is the same instant the agent's send windows reset.
  final Map<String, int> _consumed = {'control': 0, 'preview': 0};
  final Map<String, int> _creditSent = {'control': 0, 'preview': 0};

  /// Every outbound app frame passes through here: one drain loop, sealed at
  /// dequeue, control ahead of preview. Session frames are written directly and
  /// so overtake any backlog — but they still land behind whatever is already
  /// inside the socket's own sink, and nothing in this stack can read that
  /// sink, so the scheduler's accounting is the only bound on it there is.
  late final SendScheduler _scheduler = SendScheduler(
    sink: _sealAndSend,
    window: _channelWindowBytes,
    socketCap: _socketInflightBytes,
  );

  /// Test-only seam: park the send gate, shrink its limits, release it. Not
  /// part of the supported API.
  SendScheduler get debugScheduler => _scheduler;

  /// projectId → streamId, learned from `agent:projects` / `stream-ready`.
  final Map<String, String> _projectStreamIds = {};
  final Map<String, Completer<String>> _streamReadyWaiters = {};

  /// Stream ids the agent has answered `stream-invalid` for. The binding itself
  /// is deliberately LEFT in [_projectStreamIds]: `_recordProjectStream` needs
  /// the dead id as `prev` to re-point the live [StreamTransport] onto the new
  /// one. This set is what makes every reader treat it as unbound meanwhile.
  final Set<String> _invalidStreamIds = {};

  /// Dead ids whose re-bind is sent and still unanswered. Deliberately NOT the
  /// same set as [_invalidStreamIds]: that one stays marked until a replacement
  /// id arrives, so using it as the send guard would let ONE failed re-bind (a
  /// socket blip before `stream-ready`, a bind timeout, a rejected verb) swallow
  /// every later notice for the id — re-stranding the project on the dead stream
  /// with no way back.
  final Set<String> _rebindInFlight = {};

  late final FragReassembler _reassembler = FragReassembler(
    timeoutMs: kTransferTimeoutMs,
    globalBudgetBytes: kGlobalReassemblyBudget,
    onComplete: (json, channel) => _dispatchDecoded(json, channel),
    onAbort: (hint) {
      if (hint != null && !_fragAborts.isClosed) _fragAborts.add(hint);
    },
  );

  /// Completes on the FIRST `established`; errors if the session is disposed
  /// beforehand. One-shot — never await it to observe a re-establishment (use
  /// [ensureEstablished] or [established]).
  ///
  /// Errors may land before anyone awaits (dispose-before-established) — the
  /// `ignore()` in the constructor keeps those from surfacing as unhandled
  /// async errors while real awaiters still observe them.
  Future<void> get ready => _readyCompleter.future;

  /// `true` once the E2E session is established at least once and still live.
  bool get isEstablished => _established;

  /// Fires on EVERY (re)establishment, including rekeys. [ready] cannot serve
  /// that purpose — it is one-shot, so after the first establishment it can no
  /// longer tell a caller that the session came back.
  Stream<void> get established => _established$.stream;

  /// Fires when the agent hands this machine's E2E session to another device
  /// (sealed `session-takeover`). Report-only: the session is already torn down
  /// when this emits and NOTHING here re-establishes it, because two devices
  /// each reclaiming on takeover would evict each other forever.
  Stream<void> get takeoverEvents => _takeovers.stream;

  /// Fires when a handshake attempt ends with no live session — the E2E layer
  /// died while the socket underneath it stayed up (a rekey the peer never
  /// confirmed).
  ///
  /// Nothing here retries: retry pacing and give-up belong to the caller's
  /// connection supervisor, and a supervisor can only re-drive what it is told
  /// about. Without this signal the socket looks healthy, the `established`
  /// rung reads satisfied off a torn-down session, and the ladder never runs
  /// again. The socket-death and takeover paths have their own signals, so
  /// this one deliberately does not double-report them.
  Stream<void> get sessionDownEvents => _sessionDown.stream;

  Stream<FragHint> get fragmentAborts => _fragAborts.stream;
  Stream<FragSendError> get fragmentSendErrors => _fragSendErrors.stream;

  /// Emits `(projectId, streamId)` when the agent advertises a project's stream
  /// (`stream-ready`, or an `agent:projects` entry carrying `streamId`).
  Stream<({String projectId, String streamId})> get streamReadyEvents =>
      _streamReadyController.stream;

  /// The streamId the agent has advertised for [projectId], or null if not yet
  /// bound. A non-null result means [streamFor] can bind at 0 RTT. An id the
  /// agent has since declared dead reads as unbound, so a transport rebuilt off
  /// this never re-adopts it.
  String? streamIdForProject(String projectId) => _liveStreamFor(projectId);

  String? _liveStreamFor(String projectId) {
    final id = _projectStreamIds[projectId];
    if (id == null || _invalidStreamIds.contains(id)) return null;
    return id;
  }

  /// Begin driving the session: subscribe to the socket, liveness and presence.
  /// Call once, right after construction.
  ///
  /// Deliberately does NOT start a handshake. The connection supervisor climbs
  /// the ladder and calls [ensureEstablished] once the agent is reachable —
  /// having two components decide when to handshake is what the level-triggered
  /// supervisor replaced.
  void start() {
    _msgSub = relay.messageStream.listen(_onRouted);
    _stateSub = relay.stateStream.listen(_onState);
    _presenceSub = relay.peerPresenceStream.listen(_onPresence);
    _errorSub = relay.errorStream.listen(_onRelayError);
    _fragSweep = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _reassembler.sweep(),
    );
  }

  /// Drive ONE handshake attempt unless the session is already established (or
  /// an attempt is already running, in which case this joins it).
  ///
  /// Resolves only once [isEstablished] reads true, and throws
  /// [HandshakeException] otherwise: the caller scores a step that "succeeded"
  /// onto a still-broken rung as a failure, so resolving early would turn a
  /// healthy session into a give-up.
  Future<void> ensureEstablished() async {
    if (_disposed) throw StateError('session disposed');
    if (_established) return;
    await (_handshakeFuture ?? _runHandshake());
    if (!_established) {
      throw HandshakeException('E2E handshake attempt did not establish');
    }
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
  /// agent's `stream-ready`.
  Future<String> bindProject(
    String projectId,
    Map<String, dynamic> startMessage, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final known = _liveStreamFor(projectId);
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
      final rebound = _liveStreamFor(projectId);
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
    // Bounded by the same deadline as the wait below: the send resolves only
    // once the frame reaches the socket, so a control channel that cannot drain
    // would otherwise hold a bind past the "never 2x timeout" bound above and
    // pin the caller's in-flight guard behind it.
    await sendOnStream(
      kControlStreamId,
      startMessage,
      'control',
    ).timeout(_remainingUntil(deadline));
    // The waiter is shared by every concurrent bind of this project, so one
    // caller's deadline must not evict it: `.timeout()` leaves the completer
    // itself pending, and dropping the map entry would strand the other callers
    // where _recordProjectStream can no longer reach them. dispose() clears it.
    return waiter.future.timeout(_remainingUntil(deadline));
  }

  /// Wrap [message] as a sealed `{s, m}` envelope and queue it (fragmenting
  /// past the threshold). Dropped when no keys are installed (pre-establishment
  /// / mid-reconnect) — the bridge replays durable state via `state.snapshot`.
  ///
  /// Resolves when the message's last frame has been handed to the socket or
  /// dropped, never when it has merely been copied into a buffer this layer
  /// cannot measure. A caller that cannot wait for the channel ahead of it must
  /// impose its own timeout.
  Future<void> sendOnStream(
    String streamId,
    Map<String, dynamic> message,
    String channel,
  ) async {
    final type = message['type'] is String ? message['type'] as String : null;
    if (_keys == null) {
      // The phone-side mirror of the bridge's `no-e2e-session` drop. Usually
      // benign (the bridge replays durable state on establishment), but it is
      // also where a session that never comes back shows up first, and nothing
      // else on this path observes it. Dropped rather than queued: the snapshot
      // pull on the next establishment is the reconnect contract, not a backlog
      // of messages the peer has since moved past.
      _dropped(
        'tx',
        'no-e2e-session',
        channel: channel,
        streamId: streamId,
        msgType: type,
      );
      return;
    }
    final envelope = <String, dynamic>{
      if (streamId != kControlStreamId) 's': streamId,
      'm': message,
    };
    final plaintext = jsonEncode(envelope);
    final bytes = utf8ByteLength(plaintext);
    if (bytes > kMaxTransferBytes) {
      _dropped(
        'tx',
        'message-too-large',
        channel: channel,
        streamId: streamId,
        msgType: type,
        detail: {'bytes': bytes},
      );
      if (!_fragSendErrors.isClosed) {
        _fragSendErrors.add(
          FragSendError(
            'MESSAGE_TOO_LARGE',
            '${message['type'] ?? 'message'} exceeds kMaxTransferBytes',
          ),
        );
      }
      return;
    }
    final List<String> frames;
    try {
      if (bytes <= kFragThreshold) {
        frames = [plaintext];
      } else {
        final path = message['path'] as String?;
        final hint = type == 'file:content' && path != null
            ? FragHint('file:content', path)
            : null;
        // Fragment the ENVELOPE JSON so `s` survives reassembly; the id is
        // unique per (machine, stream, counter) — the agent reassembles by bare
        // id.
        final id = '$machineDeviceId-$streamId-${_fragCounter++}';
        frames = buildFragments(plaintext, id, hint);
      }
    } catch (e) {
      // The type alone, as everywhere else a drop names an error: a
      // FormatException or ArgumentError out of the fragmenter prints the
      // plaintext it choked on. `detail` is shipped to the bridge by
      // NetwatchUploader and written into an operator's export file — the app's
      // event has no `body` field precisely so a capture carries no payload,
      // and this is the one door left open to it.
      _dropped(
        'tx',
        'seal-failed',
        channel: channel,
        streamId: streamId,
        msgType: type,
        detail: {'error': '${e.runtimeType}'},
      );
      return;
    }
    final queued = [
      for (final p in frames)
        QueuedAppFrame(
          channel: channel,
          streamId: streamId,
          plaintext: p,
          plaintextBytes: utf8ByteLength(p),
          msgType: type,
        ),
    ];
    if (!_scheduler.enqueue(queued)) {
      _dropped(
        'tx',
        'send-queue-full',
        channel: channel,
        streamId: streamId,
        msgType: type,
        detail: {'frames': frames.length},
      );
      return;
    }
    // A fragment set leaves in order, so the last frame's hand-off is the
    // message's.
    await queued.last.done.future;
  }

  /// Seal one queued frame under the keys live at THIS moment and write it.
  /// Returns the sealed length that reached the wire, or null if nothing did.
  Future<int?> _sealAndSend(QueuedAppFrame f) async {
    final keys = _keys;
    if (keys == null) {
      _dropped(
        'tx',
        'no-e2e-session',
        channel: f.channel,
        streamId: f.streamId,
        msgType: f.msgType,
      );
      return null;
    }
    try {
      final sealed = await E2eTransportDart(
        sendKey: keys.p2a,
        recvKey: keys.a2p,
      ).seal(f.plaintext);
      if (!identical(keys, _keys)) {
        // `seal` holds the key by reference and reads it after its own awaits,
        // and a teardown or rekey swap zeroizes those bytes in place meanwhile.
        // Whatever came out is either under an all-zero key or under keys the
        // agent has already retired — not worth a wire write.
        _dropped(
          'tx',
          'keys-rotated',
          channel: f.channel,
          streamId: f.streamId,
          msgType: f.msgType,
        );
        return null;
      }
      relay.sendMessage(machineDeviceId, f.channel, sealed);
      // Each fragment is sealed on its own, so one message leaves as N frames
      // with N unrelated ids. Naming every one with the parent type is what
      // keeps a large transfer from reading as a burst of anonymous frames.
      // After the send, not before: the tap records the wire event inside
      // sendMessage, and this names the event it just made.
      _annotate(_frameId(sealed), msgType: f.msgType, streamId: f.streamId);
      return sealed.length;
    } catch (e) {
      // The type alone, as everywhere else a drop names an error: an exception
      // out of `seal` prints the plaintext it choked on. `detail` is shipped to
      // the bridge by NetwatchUploader and written into an operator's export
      // file — the app's event has no `body` field precisely so a capture
      // carries no payload, and this is the one door left open to it.
      _dropped(
        'tx',
        'seal-failed',
        channel: f.channel,
        streamId: f.streamId,
        msgType: f.msgType,
        detail: {'error': '${e.runtimeType}'},
      );
      return null;
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

  /// Detach [streamId]'s transport and drop whatever of its traffic is still
  /// queued: a detached stream's backlog must not occupy a window the rest of
  /// the session needs, and anything awaiting one of those frames must not be
  /// left waiting on a stream that no longer exists.
  void removeStream(String streamId) {
    _streams.remove(streamId);
    _scheduler.dropStream(streamId);
  }

  /// The relay dropped a routed frame on this socket (`MESSAGE_RATE_LIMITED`).
  ///
  /// Fanned out to every attached stream because the error names no frame and
  /// no stream — the drop happens before the relay ever sees the sealed
  /// envelope, so it cannot know which stream the frame belonged to.
  void noteFramesDropped() {
    for (final s in _streams.values) {
      s.noteFramesDropped();
    }
  }

  /// A relay error naming a channel and a byte count is a report that a frame
  /// this session had already charged to its send window was discarded before
  /// the agent saw it. Those bytes can never turn up in a credit, so without
  /// giving them back every drop shrinks that channel's window for the rest of
  /// the session. Errors that name no frame are somebody else's business — the
  /// app fans them out to the streams through [noteFramesDropped].
  void _onRelayError(ErrorMessage e) {
    final channel = e.channel;
    final bytes = e.bytes;
    if (bytes == null || (channel != 'control' && channel != 'preview')) return;
    _scheduler.uncharge(channel!, bytes);
  }

  // --- socket / presence transitions ---------------------------------------

  /// Session keys are per-CONNECTION, so only the socket dying invalidates
  /// them. Every other transition is left alone: with pairing gone there is no
  /// grant whose loss could strand an otherwise-live session, and the
  /// supervisor re-drives [ensureEstablished] on whatever it observes.
  void _onState(AppState s) {
    if (s.connectionState == RelayConnectionState.disconnected) {
      _teardownSession();
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

  void _teardownSession() {
    // Drop all session state — called when the socket dies and when the agent
    // hands the session to another device. Session keys are per-connection;
    // either event invalidates them. Clearing `_established` is also what
    // silences every rekey trigger (liveness, RPC timeouts, peer-online), all
    // of which are gated on a live session.
    _established = false;
    _stopLiveness();
    _keys?.zeroize();
    _keys = null;
    // Fail every in-flight RPC now: their replies can never arrive on a dead
    // session, so waiting out each timeout is a pure fail-slow spinner. Tier-3
    // hydration re-drives on the next establishment (streamReadyEvents); tier-2
    // actions surface the failure for the user to retry.
    for (final s in _streams.values) {
      s.failAllPending(code: 'E_SESSION_DOWN', message: 'relay session down');
    }
    // Whatever the send gate was still holding dies with the keys it would have
    // been sealed under. Their futures complete rather than fail: the callers
    // are fire-and-forget, so an error would land in no handler at all.
    for (final f in _scheduler.clear()) {
      _dropped(
        'tx',
        'queue-dropped',
        channel: f.channel,
        streamId: f.streamId,
        msgType: f.msgType,
        detail: {'why': 'session-down'},
      );
    }
    _resetRxFlow();
    // Re-arm only from the completed state: a second blip before the first
    // establishment would otherwise orphan whoever is already awaiting.
    if (_keysReady.isCompleted) _armKeysReady();
  }

  // --- handshake / rekey ----------------------------------------------------

  Future<void> _rekey() async {
    if (_disposed || !_established) return;
    await _runHandshake();
  }

  /// Runs a single attempt and publishes it as [_handshakeFuture] so a
  /// concurrent [ensureEstablished] joins it instead of racing a second one.
  Future<void> _runHandshake() {
    if (_disposed || _handshakeInFlight) return Future<void>.value();
    _handshakeInFlight = true;
    late final Future<void> attempt;
    attempt = _handshakeAttempt().whenComplete(() {
      _handshakeInFlight = false;
      if (identical(_handshakeFuture, attempt)) _handshakeFuture = null;
      // Reported only after the in-flight flags clear, so the supervisor's
      // immediate re-drive starts a genuinely fresh attempt instead of joining
      // the one that just failed and scoring it a second time.
      if (!_disposed && !_established && !_sessionDown.isClosed) {
        _sessionDown.add(null);
      }
    });
    _handshakeFuture = attempt;
    return attempt;
  }

  /// ONE attempt, no retry: the app's connection supervisor owns backoff and
  /// give-up, so a loop here would nest inside its backoff and multiply it.
  Future<void> _handshakeAttempt() async {
    final newKeys = await _handshaker.perform();
    if (_disposed) {
      newKeys?.zeroize();
      return;
    }
    if (newKeys == null) {
      // A rekey only ever runs because the session already looks dead
      // (missed pongs, repeated RPC timeouts, a peer that bounced), so keeping
      // the old keys after a failed attempt preserves a session the peer has
      // most likely already dropped — and, with `_established` still true,
      // leaves nothing able to notice.
      _teardownSession();
      return;
    }
    // Make-before-break: swap AFTER the new attempt confirmed, then zeroize
    // the superseded keys (no dropped traffic on the old keys).
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
    if (!_established$.isClosed) _established$.add(null);
    // A new session credits from zero. The QUEUE deliberately survives a rekey:
    // frames dequeued from here on seal under the new keys, and the agent
    // swapped before it confirmed, so nothing straddles the change in this
    // direction — where dropping them would strand every pending RPC until its
    // timeout.
    _scheduler.resetWindows();
    _resetRxFlow();
    _scheduler.kick();
    // Re-pull durable state on every (re)establish so late subscribers
    // (a ControlPlaneClient, a just-bound project stream) replay it.
    for (final s in _streams.values) {
      unawaited(s.refreshSnapshot());
    }
  }

  // --- inbound flow control -------------------------------------------------

  void _resetRxFlow() {
    for (final ch in const ['control', 'preview']) {
      _consumed[ch] = 0;
      _creditSent[ch] = 0;
    }
  }

  /// Count sealed payload bytes the agent charged to its window. Every kind-0
  /// frame that arrives on a live session counts, whether or not it decrypted:
  /// the agent charged it either way, so skipping the ones that failed would
  /// leak its window a frame at a time and let a single corrupt frame wedge a
  /// channel for the session.
  void _noteConsumed(String channel, int bytes) {
    final total = _consumed[channel];
    // A channel this session keeps no window for; the agent keeps none either.
    if (total == null) return;
    _consumed[channel] = total + bytes;
    if (total + bytes - _creditSent[channel]! >= creditBatchBytes) {
      _sendCredit(channel);
    }
  }

  /// Hand the agent this channel's cumulative consumed count. Cumulative rather
  /// than incremental so a credit lost in transit costs nothing — the next one
  /// carries the same ground truth.
  void _sendCredit(String channel) {
    if (!_established) return;
    final consumed = _consumed[channel]!;
    _creditSent[channel] = consumed;
    unawaited(
      _sendSessionFrame({
        'type': 'credit',
        'channel': channel,
        'consumed': consumed,
      }).catchError((_) {}),
    );
  }

  // --- liveness -------------------------------------------------------------

  void _startLiveness() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(pingSilence, (_) => _checkLiveness());
  }

  void _stopLiveness() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _missedPongs = 0;
  }

  void _checkLiveness() {
    if (_disposed || !_established) return;
    // Unconditional, both channels, every tick. A credit the relay discarded
    // would otherwise wedge the agent's window until the session ended, and
    // there is no state here that could go stale: the count is cumulative. It
    // doubles as the proof of life the agent's own liveness timers read, which
    // on a slow uplink is what keeps a session up while bulk drains.
    for (final ch in const ['control', 'preview']) {
      _sendCredit(ch);
    }
    // The flush above is deliberately ahead of this: a rekey keeps the old keys
    // live until the new ones confirm, so skipping it would stretch the
    // lost-credit floor by a whole handshake.
    if (_handshakeInFlight) return;
    final silentFor = DateTime.now().difference(_lastRecv);
    if (silentFor < pingSilence) return;
    if (_missedPongs >= kMaxMissedPongs) {
      // Session declared dead at the E2E layer → rekey on the live socket.
      _stopLiveness();
      unawaited(_rekey());
      return;
    }
    _missedPongs++;
    unawaited(_sendSessionFrame({'type': 'ping'}).catchError((_) {}));
  }

  // --- frame capture --------------------------------------------------------

  /// Read off the socket rather than injected, so a capture is wired in exactly
  /// one place (`app/lib/providers/relay_connection.dart`) and the two layers
  /// can never disagree about whether one is armed.
  RelayNetTap? get _tap => relay.netTap;

  String? _frameId(Uint8List payload, [FrameKind kind = FrameKind.sealed]) =>
      _tap == null ? null : frameIdOf(payload, kind);

  /// Name a frame this layer can type but not identify. [RelayService] records
  /// the wire event synchronously as the frame crosses the socket, so by the
  /// time this runs the event it is naming is always already buffered.
  void _annotate(String? frameId, {String? msgType, String? streamId}) {
    final tap = _tap;
    if (tap == null || frameId == null) return;
    tap({
      'op': 'annotate',
      'frameId': frameId,
      'msgType': msgType,
      'streamId': streamId,
    });
  }

  void _dropped(
    String dir,
    String reason, {
    String? channel,
    String? streamId,
    String? msgType,
    String? frameId,
    Map<String, Object?>? detail,
  }) {
    _tap?.call({
      'op': 'frame',
      'dir': dir,
      'kind': 'drop',
      'channel': channel,
      'streamId': streamId,
      'msgType': msgType,
      'frameId': frameId,
      'reason': reason,
      'detail': detail,
    });
  }

  // --- inbound dispatch -----------------------------------------------------

  void _onRouted(IncomingRouteMessage msg) {
    // Kind-1 (handshake) plaintext frames belong to the handshake driver, which
    // subscribes to the same messageStream and does its own dispatch.
    if (msg.kind == FrameKind.handshake) return;
    final keys = _keys;
    if (keys == null) return; // pre-establishment: driver owns sealed frames
    // Chained per channel, never fired independently: `open()` is async and the
    // platform AES-GCM implementation dispatches by payload size, so a small
    // frame otherwise overtakes a large one — a `{"type":6}` ping ahead of the
    // 30 KB render batch it acknowledges, one `terminal:output` chunk ahead of
    // another, or a fragment ahead of its predecessor in [_reassembler]. The
    // relay delivers a channel in order; this is what keeps that true through
    // decryption. Channels stay independent of each other.
    final ahead = _inboundTails[msg.channel] ?? Future<void>.value();
    final next = ahead.then((_) => _decryptAndDispatch(msg, keys));
    // A rejection must not strand every frame queued behind it.
    final chained = next.catchError((Object _) {});
    _inboundTails[msg.channel] = chained;
    unawaited(
      chained.whenComplete(() {
        // Only the tail retires the entry — a later frame has already replaced
        // it, and dropping that would let the next frame race this one.
        if (identical(_inboundTails[msg.channel], chained)) {
          _inboundTails.remove(msg.channel);
        }
      }),
    );
  }

  Future<void> _decryptAndDispatch(
    IncomingRouteMessage msg,
    SessionKeys keys,
  ) async {
    // Captured before the open: the nonce that identifies this frame is only
    // readable while the payload is still sealed, and the type that makes it
    // legible only exists after. The two meet by id, not by threading — this
    // path is chained through `_inboundTails` and is genuinely async, so a
    // field would start mis-attributing under any concurrency.
    final frameId = _frameId(msg.payload, msg.kind);
    _noteConsumed(msg.channel, msg.payload.length);
    var plaintext = await E2eTransportDart(
      sendKey: keys.p2a,
      recvKey: keys.a2p,
    ).open(msg.payload);
    if (plaintext == null) {
      final current = _keys;
      if (current != null && !identical(current, keys)) {
        // This chain captured the keys as the frame arrived and a rekey swaps
        // them several awaits later, so everything the agent writes right
        // behind `established` — the adverts a fresh session needs first — is
        // sealed under the new set and would otherwise be read under the
        // retired one.
        plaintext = await E2eTransportDart(
          sendKey: current.p2a,
          recvKey: current.a2p,
        ).open(msg.payload);
      }
    }
    // A candidate-key handshake frame during rekey (agent-ready/established) or
    // garbage → decrypt-or-drop.
    if (plaintext == null) {
      _dropped(
        'rx',
        'decrypt-failed',
        channel: msg.channel,
        frameId: frameId,
        detail: {'kind': msg.kind.name},
      );
      return;
    }
    _lastRecv = DateTime.now();
    _missedPongs = 0;
    if (_reassembler.accept(plaintext, channel: msg.channel)) {
      // The reassembler consumes a fragment before any type is visible, so this
      // is the only chance to say what it was. Matches the bridge's `__frag`.
      _annotate(frameId, msgType: '__frag');
      return;
    }
    _dispatchDecoded(plaintext, msg.channel, frameId);
  }

  /// [frameId] is absent for a reassembled message: it arrived as N frames with
  /// N ids, and no single one of them carried it.
  void _dispatchDecoded(String plaintext, String channel, [String? frameId]) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (_) {
      _dropped(
        'rx',
        'plaintext-not-json',
        channel: channel,
        frameId: frameId,
      );
      return;
    }
    final type = json['type'];
    // Sealed-payload disambiguation: a top-level `type` string is a
    // session/liveness frame; an `m` field is stream/app traffic.
    if (type is String) {
      _annotate(frameId, msgType: type);
      _handleSessionFrame(json);
      return;
    }
    if (!json.containsKey('m')) {
      _dropped('rx', 'unrecognized-plaintext', channel: channel, frameId: frameId);
      return;
    }
    final env = StreamEnvelope.fromJson(json);
    if (env == null) {
      _dropped('rx', 'bad-envelope', channel: channel, frameId: frameId);
      return;
    }
    final sid = (env.s == null || env.s == kControlStreamId)
        ? kControlStreamId
        : env.s!;
    final m = env.m;
    final mType = m is Map<String, dynamic> && m['type'] is String
        ? m['type'] as String
        : null;
    _annotate(frameId, msgType: mType, streamId: sid);
    _snoopControl(sid, m);
    final st = _streams[sid];
    if (st != null && m is Map<String, dynamic>) {
      st.dispatchFromSession(m, channel);
      return;
    }
    // A project frame for a streamId we hold no transport for is dropped. This
    // is the phone-side mirror of the bridge's "unknown streamId" warn — once a
    // symptom-only silent hole (a host restart changed the id and the transport
    // wasn't re-pointed). `_recordProjectStream` now migrates the transport, so
    // reaching here signals a genuine anomaly (a race, or a stream torn down
    // mid-flight), not the routine restart case. "0" legitimately has no
    // transport (adverts are snooped above), so it's never a drop.
    if (st == null && sid != kControlStreamId) {
      developer.log(
        'dropping inbound frame for unknown streamId $sid',
        name: 'antgrid.relay',
      );
      _dropped(
        'rx',
        'unknown-stream',
        channel: channel,
        streamId: sid,
        msgType: mType,
        frameId: frameId,
      );
    }
  }

  /// Snoop control-plane adverts for project→stream bindings so [bindProject]
  /// can resolve at 0 RTT and drill-in `stream-ready` waiters resolve. Called
  /// for LIVE frames and for `state.snapshot`-replayed frames alike — the
  /// bridge's replay-cache dedup can legally suppress a byte-identical live
  /// re-advert after an app kill+reopen, so the snapshot pull is the reconnect
  /// binding contract, not a cache warm-up.
  void _snoopControl(String sid, Object? m) {
    if (sid != kControlStreamId || m is! Map<String, dynamic>) return;
    final type = m['type'];
    if (type == 'stream-ready') {
      final pid = m['projectId'];
      final streamId = m['streamId'];
      if (pid is String && streamId is String)
        _recordProjectStream(pid, streamId);
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
        final dropped = <String, String>{};
        _projectStreamIds.removeWhere((pid, sid) {
          final gone = !next.containsKey(pid);
          if (gone) dropped[pid] = sid;
          return gone;
        });
        // A restarted host re-opens a project LOCALLY first, so the advert that
        // announces it back is dialable:false — it carries no replacement id for
        // `_recordProjectStream` to migrate onto. Forgetting the binding is not
        // enough: the transport ProjectSession and all 7 services hold is still
        // aimed at the dead id and every send vanishes. Re-drive project:start
        // for exactly those, which promotes the core and answers stream-ready.
        for (final e in dropped.entries) {
          if (_streams.containsKey(e.value)) {
            _projectStreamIds[e.key] = e.value;
            _onStreamInvalid(e.value);
          } else {
            _invalidStreamIds.remove(e.value);
          }
        }
        next.forEach(_recordProjectStream);
      }
    } else if (type == 'stream-invalid') {
      final streamId = m['streamId'];
      if (streamId is String) _onStreamInvalid(streamId);
    } else if (type == 'control:result' &&
        m['ok'] == false &&
        m['verb'] == 'project:start') {
      // A rejected project:start (NOT_ALLOWED / OPEN_FAILED, or the retired
      // SESSION_LIMIT_EXCEEDED from a pre-worker-limit relay) — fail the
      // pending bind with the real reason
      // instead of letting it run out its blind timeout. The `verb` match is
      // load-bearing: the bridge echoes `projectId` on EVERY failed
      // control-plane verb, so matching on `ok:false` alone would let an
      // unrelated rejection kill a healthy bind with a bogus code.
      final pid = m['projectId'];
      if (pid is String) {
        final waiter = _streamReadyWaiters.remove(pid);
        if (waiter != null && !waiter.isCompleted) {
          final err = m['error'];
          waiter.completeError(
            ProjectBindException(
              err is Map && err['code'] is String
                  ? err['code'] as String
                  : 'UNKNOWN',
              err is Map && err['message'] is String
                  ? err['message'] as String
                  : '',
            ),
          );
        }
      }
    }
  }

  /// The agent holds no stream for [streamId] — a host restart re-attached every
  /// project under fresh random ids and ours died with the old process. Without
  /// this the phone keeps sending on the dead id and every verb times out with
  /// no signal to renegotiate (the bridge only warned and dropped).
  ///
  /// Re-drive `project:start` rather than wait for a re-advert: the project may
  /// not even be open on the restarted host, and the advert that would carry the
  /// new id is exactly what didn't reach us.
  void _onStreamInvalid(String streamId) {
    _invalidStreamIds.add(streamId);
    if (_rebindInFlight.contains(streamId)) return;
    String? projectId;
    for (final e in _projectStreamIds.entries) {
      if (e.value == streamId) {
        projectId = e.key;
        break;
      }
    }
    // An id we hold no binding for is already healed (a re-advert beat the
    // notice) or was never ours — nothing to re-drive.
    if (projectId == null) {
      _invalidStreamIds.remove(streamId);
      return;
    }
    final build = projectStartMessageBuilder;
    if (build == null) return;
    // Failure is not fatal: the binding stays marked dead and the in-flight
    // guard is released, so the agent's NEXT notice (it answers every frame the
    // phone replays onto the dead id) re-drives. Swallowed rather than surfaced
    // — this is a background self-heal with no caller to report to.
    _rebindInFlight.add(streamId);
    unawaited(
      bindProject(projectId, build(projectId))
          .catchError((_) => '')
          .whenComplete(() => _rebindInFlight.remove(streamId)),
    );
  }

  void _recordProjectStream(String projectId, String streamId) {
    final prev = _projectStreamIds[projectId];
    _invalidStreamIds.remove(streamId);
    if (prev != null && prev != streamId) {
      _invalidStreamIds.remove(prev);
      // A host restart re-attaches the project under a fresh streamId (ids are
      // random per attach — bridge/stream-mux.ts). Re-point the LIVE transport,
      // held by the ProjectSession and every service, from the dead id to the
      // new one instead of orphaning it. Left un-migrated, outbound sends target
      // the old id — the restarted host logs "unknown streamId" and drops them —
      // and inbound frames arrive on the new id with no transport to receive.
      // Don't clobber an existing transport already bound to the new id.
      final migrated = _streams[prev];
      if (migrated != null && !_streams.containsKey(streamId)) {
        _streams.remove(prev);
        migrated._retarget(streamId);
        _streams[streamId] = migrated;
        // Re-hydrate over the live stream: the reconnect's refreshSnapshot ran
        // against the dead id and was dropped.
        if (_established) unawaited(migrated.refreshSnapshot());
      }
    }
    _projectStreamIds[projectId] = streamId;
    final waiter = _streamReadyWaiters.remove(projectId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(streamId);
    if (!_streamReadyController.isClosed) {
      _streamReadyController.add((projectId: projectId, streamId: streamId));
    }
  }

  /// Takes the whole decoded frame, not just its type: `credit` carries fields.
  void _handleSessionFrame(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'ping':
        unawaited(_sendSessionFrame({'type': 'pong'}).catchError((_) {}));
        break;
      case 'pong':
        _missedPongs = 0;
        break;
      case 'credit':
        // Hand-validated, like every other sealed session frame: these are bare
        // objects that never pass through the envelope schemas.
        final channel = json['channel'];
        final consumed = json['consumed'];
        if ((channel != 'control' && channel != 'preview') ||
            consumed is! int ||
            consumed < 0) {
          developer.log(
            'dropping malformed credit frame',
            name: 'antgrid.relay',
          );
          break;
        }
        _scheduler.credit(channel as String, consumed);
        break;
      case 'session-takeover':
        // The agent is switching to another device and is about to drop our
        // keys. Tear down (which also disarms every rekey trigger) and REPORT —
        // re-establishing here would fight the other device for the session.
        _teardownSession();
        if (!_takeovers.isClosed) _takeovers.add(null);
        break;
      // 'established' / 'handshake:agent-ready' are decrypted under the
      // handshake's candidate keys and owned by the driver; a stale copy here
      // (already-swapped keys) is ignored.
    }
  }

  Future<void> _sendSessionFrame(Map<String, dynamic> obj) async {
    final keys = _keys;
    final type = obj['type'] as String?;
    if (keys == null) {
      _dropped('tx', 'no-e2e-session', channel: 'control', msgType: type);
      return;
    }
    final ct = await E2eTransportDart(
      sendKey: keys.p2a,
      recvKey: keys.a2p,
    ).seal(jsonEncode(obj));
    relay.sendMessage(machineDeviceId, 'control', ct);
    // Exempt from the GATE, never from the accounting: a relay drop report
    // names only a channel and a byte count, so a frame written without being
    // charged would have its report give back bytes some other frame is still
    // holding, and the window would grow past what the agent can absorb.
    _scheduler.charge('control', ct.length);
    // Liveness frames are the cheapest signal that a session is alive at all —
    // a capture where ping goes out and pong never comes back is the whole
    // diagnosis for a silently dead socket.
    _annotate(_frameId(ct), msgType: type);
  }

  Future<void> dispose() async {
    _disposed = true;
    _handshaker.abort();
    _stopLiveness();
    _fragSweep?.cancel();
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    await _presenceSub?.cancel();
    await _errorSub?.cancel();
    for (final s in List<StreamTransport>.of(_streams.values)) {
      await s.dispose();
    }
    _streams.clear();
    for (final w in _streamReadyWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('session disposed'));
    }
    _streamReadyWaiters.clear();
    _inboundTails.clear();
    // No drop records: the capture tap is read off the socket this dispose is
    // tearing down.
    _scheduler.clear();
    await _established$.close();
    await _takeovers.close();
    await _sessionDown.close();
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

  /// The stream this transport currently targets. Not final: a host restart
  /// re-attaches the project under a fresh streamId, and [MachineSession]
  /// re-points this transport in place via [_retarget] (see
  /// `_recordProjectStream`) so the ProjectSession and its services keep sending
  /// on the live stream rather than a dead id the restarted host drops.
  String streamId;

  StreamTransport({required this.session, required this.streamId});

  /// Migrate this transport onto [newStreamId] after a host-restart re-advert.
  /// Called by [MachineSession] only, which owns the `_streams` re-keying.
  ///
  /// Frames already queued for the dead id keep it and still go out: the host
  /// answers `stream-invalid`, which re-drives the bind. Cheaper than rewriting
  /// the envelope of every frame built before the re-point, and it exercises
  /// the self-heal that has to work anyway.
  void _retarget(String newStreamId) => streamId = newStreamId;

  void noteFramesDropped() {
    if (!droppedFrameController.isClosed) droppedFrameController.add(null);
  }

  @override
  bool get isLocal => false;

  // A stream stays TransportState.connected across a session-down window (the
  // socket may be fine; only the E2E session drops), so the base "connected ==
  // established" is wrong here — a hydrator firing then would seal-and-vanish.
  // The live E2E session is the truth.
  @override
  bool get isEstablished => session.isEstablished;

  @override
  Future<void> connect() async {
    setState(TransportState.connected);
    // Seed durable state — but only when the session can carry the request:
    // without keys sendOnStream drops it and the RPC would burn its full
    // timeout to report what is already known. Nothing is lost, since every
    // attached stream is refreshed on each (re)establish.
    if (!session.isEstablished) return;
    await _fetchSnapshot(timeout: session.snapshotTimeout * 2);
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) => session.sendOnStream(streamId, message, channel);

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
      // ≥3 consecutive E_TIMEOUTs is a rekey trigger.
      session.notifyRpcResult(timedOut: e.code == 'E_TIMEOUT');
      rethrow;
    }
  }

  /// Deliver a decoded message that the session demuxed to this stream.
  void dispatchFromSession(Map<String, dynamic> json, String channel) =>
      dispatchDecoded(json, channel);

  @override
  void noteOrphanResponse(String? requestId, String channel) {
    session.relay.netTap?.call({
      'op': 'frame',
      'dir': 'rx',
      'kind': 'drop',
      'channel': channel,
      'streamId': streamId,
      'msgType': 'response',
      'reason': 'late-response',
      'detail': {if (requestId != null) 'requestId': requestId},
    });
  }

  /// Re-pull the durable-state snapshot now that session keys are (re)installed,
  /// then re-drive the tier-3 hydrators. Order matters: the snapshot replays the
  /// durable state first, then hydrators pull the view-state the snapshot does
  /// not carry (session list, config, the reopened file, the transcript). This
  /// is the per-stream reconciliation checkpoint.
  ///
  /// The pull carries every durable frame but the file tree, and for a relay
  /// app it is the ONLY carrier of a checkout's `agent:status` — the frame its
  /// terminal tabs are built from: `terminal:started` is not durable, the
  /// bridge republishes a checkout's status on nothing an app can trigger
  /// short of starting a session that is already running, and the next
  /// establishment is the only other re-pull. `tree:full` is left out on
  /// purpose, and not pulled separately either: it is the one unbounded frame
  /// (every checkout's whole tree, megabytes for a project with several
  /// worktrees), and the hydrators below already ask the bridge for each
  /// checkout's tree on every establishment — pulling it here as well sent the
  /// same megabytes two and three times over on every connect, and on a slow
  /// uplink that backlog starved the bridge's relay pongs until the relay
  /// closed its socket, so the session dropped and the whole cycle re-ran.
  /// While the tree rode in this reply at all, a slow link or one lost
  /// fragment cost the terminal its tab — a running session opened afterwards
  /// sat on "waiting for agent" with nothing left to deliver it.
  ///
  /// The pull is retried on timeout, since a reply that lands after the wait
  /// is discarded like any late RPC response. Only the first attempt is
  /// awaited: the hydrators do not depend on the snapshot having landed (a
  /// bundle built before it reads the frames live when they arrive), so they
  /// must not wait out a bad link's retries.
  Future<void> refreshSnapshot() async {
    await _fetchSnapshot(timeout: session.snapshotTimeout);
    redriveHydrators();
  }

  /// Round trips a pull gets before it is given up on, the first included.
  /// Each retry doubles the previous wait, so the last one gives a slow reply
  /// four times the room the first did.
  static const _kSnapshotAttempts = 3;

  /// Stamps each pull so the retries of a superseded one stop: a
  /// (re)establish or a second bind starts a fresh pull on the live keys, and
  /// [dispose] ends them all.
  int _snapshotGen = 0;

  Future<void> _fetchSnapshot({required Duration timeout}) async {
    final gen = ++_snapshotGen;
    if (await _pullSnapshot(timeout, attempt: 1)) return;
    unawaited(_retrySnapshot(gen, timeout));
  }

  Future<void> _retrySnapshot(int gen, Duration timeout) async {
    for (var attempt = 2; attempt <= _kSnapshotAttempts; attempt++) {
      timeout *= 2;
      if (gen != _snapshotGen || outbound.isClosed || !session.isEstablished) {
        return;
      }
      if (await _pullSnapshot(timeout, attempt: attempt)) return;
    }
    developer.log(
      'state.snapshot gave up after $_kSnapshotAttempts attempts on stream '
      '$streamId; its frames stay as they were until the next establishment',
      name: 'antgrid.relay',
    );
  }

  /// One `state.snapshot` round trip. True once the pull is settled — the
  /// reply landed, or it failed in a way no retry changes (a pre-RPC agent, a
  /// send that never left) — and false only on a timeout, the one failure a
  /// slower second try can turn around.
  Future<bool> _pullSnapshot(Duration timeout, {required int attempt}) async {
    const method = 'state.snapshot';
    const params = <String, dynamic>{
      'types': ['*'],
      'exclude': _kHeavyReplayTypes,
    };
    try {
      // Only the first attempt counts toward the session's consecutive-timeout
      // rekey trigger. A retry re-asks a question already counted, and letting
      // it count too made the chain itself the trigger: three waits on a slow
      // link forced a rekey, the re-establish started a fresh chain, and the
      // loop re-requested the reply forever over a link that could not carry
      // it. A pull that lands still clears the counter — the session has just
      // proven itself.
      final counts = attempt == 1;
      final snap = counts
          ? await request(method, params: params, timeout: timeout)
          : await super.request(method, params: params, timeout: timeout);
      if (!counts) session.notifyRpcResult(timedOut: false);
      final frames = (snap['frames'] as List?) ?? const [];
      final fresh = <InboundMessage>[];
      for (final raw in frames) {
        if (raw is Map) {
          final m = raw.cast<String, dynamic>();
          // Snapshot-replayed frames must feed the session's stream-binding
          // map exactly like live frames: the bridge's replay-cache dedup can
          // suppress the live re-advert after an app kill+reopen, making this
          // pull the ONLY carrier of `agent:projects{streamId}`.
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
      return true;
    } on RpcException catch (e) {
      // Leave the existing cache untouched either way.
      if (e.code != 'E_TIMEOUT') return true;
      developer.log(
        'state.snapshot timed out after ${timeout.inMilliseconds}ms on stream '
        '$streamId (attempt $attempt of $_kSnapshotAttempts)',
        name: 'antgrid.relay',
      );
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _snapshotGen++;
    failAllPending();
    clearHydrators();
    snapshotCache.clear();
    session.removeStream(streamId);
    await outbound.close();
    await stateController.close();
    await droppedFrameController.close();
  }
}

/// Durable frames the snapshot pull leaves out: the only unbounded ones the
/// bridge caches, each delivered by a per-checkout hydrator instead — see
/// [StreamTransport.refreshSnapshot].
const _kHeavyReplayTypes = <String>['tree:full'];
