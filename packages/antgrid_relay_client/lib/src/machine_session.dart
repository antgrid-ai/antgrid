import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'agent_transport.dart';
import 'buffered_agent_transport.dart';
import 'frame.dart';
import 'models/stream_open.dart';
import 'relay_service.dart';
import 'peer_link.dart';
import 'terminal_attachment.dart';
import 'tunnel_stream.dart';
import 'upload_stream.dart';

/// The app's own wedge probe: a bridge whose event loop is stuck but whose
/// QUIC stack still acks would otherwise look alive forever. A dead bridge is
/// `kPeerQuicMaxIdleTimeout`'s job, not this one's — nothing on the bridge
/// mirrors these.
const int kPingSilenceSeconds = 20;
const int kMaxMissedPongs = 2;

/// Consecutive RPC timeouts on one project stream before it resets and
/// reopens (`StreamTransport._resetForHealth`) — that stream only, never the
/// whole link. The control transport counts nothing; its only connection-level
/// escape is the ping above.
const int kProjectStreamTimeoutsToReset = 3;

/// Reopen backoff for a project stream that ended while its transport is
/// still wanted (Stage A A4): the first retry follows almost immediately,
/// later ones back off toward [kProjectStreamReopenMaxBackoff] rather than
/// hammering a bridge that is itself restarting.
const Duration kProjectStreamReopenInitialBackoff = Duration(seconds: 1);
const Duration kProjectStreamReopenMaxBackoff = Duration(seconds: 30);

/// Deadline for the one `state.snapshot` request a (re)establishment, bind or
/// [StreamTransport.refreshDurableState] call sends — long enough that a
/// reply landing after a caller's own [MachineSession.snapshotTimeout] wait is
/// still applied rather than discarded as late.
const Duration kSnapshotPullDeadline = Duration(seconds: 70);

/// Local queue cap handed to [PeerLink.openStream] for a project
/// stream; the same per-stream bound as the bridge's
/// `PROJECT_STREAM_MAX_QUEUED_BYTES` (`bridge/src/project-streams.ts`).
const int kProjectStreamMaxQueuedBytes = 67108864;

/// Drives ONE hello attempt-cycle over a [MachineSession]'s socket, completing
/// only once the bridge's `session:established` arrives. The app implements this
/// wrapping `ConnectionHandshake`; the package stays Flutter-free. Each
/// [perform] must run a FRESH attempt (new `attemptId`).
abstract interface class SessionHandshaker {
  /// Runs one hello to `session:established`. True once it lands, false on timeout /
  /// abort / a link that will not accept the hello.
  Future<bool> perform();

  /// Abort any in-flight [perform] (session teardown / supersession).
  void abort();
}

/// Thrown by [MachineSession.ensureEstablished] when the one handshake attempt
/// it drove did not reach `session:established`. Retry pacing and give-up belong to the
/// caller (the app's connection supervisor), which is why this reports a single
/// failed attempt rather than an exhausted budget.
class HandshakeException implements Exception {
  final String message;
  HandshakeException(this.message);
  @override
  String toString() => 'HandshakeException: $message';
}

/// Thrown by [MachineSession.openProject] when the bridge refuses the project
/// stream, or the `project:start` it sent first is rejected
/// (`control:result {ok:false}` — e.g. `NOT_ALLOWED`, `NOT_READY`) — so the
/// caller fails with the real reason instead of a blind timeout.
class ProjectBindException implements Exception {
  final String code;
  final String message;
  ProjectBindException(this.code, this.message);
  @override
  String toString() => 'ProjectBindException($code): $message';
}

/// One established hello, identified by a monotonic epoch rather than a bool:
/// object identity lets a send fence itself against a rotation that happens
/// mid-await (`identical(gen, _generation)`), which a bool cannot distinguish
/// from "still the same state" when it flips false then true again before the
/// awaited call returns.
class _SessionGeneration {
  _SessionGeneration(this.epoch);
  final int epoch;
}

/// `(projectId, open)` — see [MachineSession.projectStreamEvents].
typedef ProjectStreamEvent = ({String projectId, bool open});

/// One outbound message refused locally for exceeding the peer's read cap.
class MessageTooLarge {
  const MessageTooLarge(this.type, this.bytes);
  final String? type;
  final int bytes;
}

/// Outcome of reading a project stream's first record — see
/// [StreamTransport._bindOverStream].
enum _BindOutcome { bound, notReadyRetry }

/// One phone↔machine session multiplexed over a single [PeerLink] socket for
/// its control plane, with each project riding its own native QUIC stream
/// ([PeerLink.openStream]). QUIC/TLS between the
/// two lease-authorized endpoints is the confidentiality layer; this class
/// owns the hello/close driver, liveness, and project-stream lifecycle.
/// A session-stream record is one length-prefixed JSON body — a session
/// frame (`session:hello`, `session:established`, `session:ping`,
/// `session:pong`) or a bare control-plane `AbMessage`, told apart by the
/// JSON `type` alone ([isSessionFrameType]). A project's traffic is bare
/// `AbMessage` JSON on its own stream.
class MachineSession {
  final PeerLink relay;

  /// The bare machine deviceUuid — the routing `to` for every outbound frame.
  final String machineDeviceId;

  final SessionHandshaker _handshaker;
  final RelayLogger? _logger;

  /// Builds the `project:start` control message a project stream (re)open
  /// sends when the project has not already been declared ready — used both
  /// by [openProject]'s first attempt and by a stream's self-driven reopen
  /// after it ends. Injected rather than built here because message
  /// construction (uuid ids) lives in the app layer, not in this pure-Dart
  /// package. Omitted → a stream that ends can only be reopened by a fresh
  /// ready notice, never self-driven.
  final Map<String, dynamic> Function(String projectId)?
  projectStartMessageBuilder;

  /// How long a caller of [StreamTransport.refreshSnapshot] or
  /// [StreamTransport.refreshDurableState] (and [StreamTransport.connect], at
  /// twice this) waits before moving on. The pull itself keeps running until
  /// [snapshotDeadline] regardless — a reply landing after this wait but
  /// before that deadline is still applied.
  final Duration snapshotTimeout;

  /// Silence after which liveness sends a `session:ping`, and the period the
  /// liveness timer itself runs at. Injectable so a test need not wait out the
  /// real interval.
  final Duration pingSilence;

  /// Deadline for the `state.snapshot` request itself. Defaults to
  /// [kSnapshotPullDeadline].
  final Duration snapshotDeadline;

  MachineSession({
    required this.relay,
    required this.machineDeviceId,
    required SessionHandshaker handshaker,
    this.projectStartMessageBuilder,
    this.snapshotTimeout = const Duration(seconds: 5),
    this.pingSilence = const Duration(seconds: kPingSilenceSeconds),
    this.snapshotDeadline = kSnapshotPullDeadline,
    RelayLogger? logger,
  }) : _handshaker = handshaker,
       _logger = logger {
    // [ready] is observation-optional: failReady/dispose may completeError
    // before any awaiter attaches (see the getter doc). ignore() pre-registers
    // a swallowing listener so that never trips the unhandled-error zone hook;
    // every real `await ready` still receives the error.
    _readyCompleter.future.ignore();
    _armEstablishedReady();
  }

  _SessionGeneration? _generation;
  int _epochCounter = 0;

  /// `kSessionStreamLabel` -> the session-stream transport, everything else ->
  /// a project's transport. Unified so disposal (`removeStream`) and the
  /// per-(re)establishment sweep need no special case for the control entry.
  final Map<String, StreamTransport> _streams = {};

  StreamSubscription<IncomingSessionRecord>? _msgSub;
  StreamSubscription<PeerLinkState>? _stateSub;
  Timer? _livenessTimer;

  bool _disposed = false;
  bool _established = false;
  bool _handshakeInFlight = false;
  int _missedPongs = 0;
  DateTime _lastRecv = DateTime.now();

  /// Serializes writes on the session stream so a dequeue-time generation
  /// check (see [sendOnSession]) sees frames in the order they were queued.
  Future<void> _sessionSendChain = Future<void>.value();

  /// The attempt [ensureEstablished] joins instead of starting a second one.
  /// Null whenever no handshake is running.
  Future<void>? _handshakeFuture;

  final _readyCompleter = Completer<void>();

  /// Completes each time [_generation] is installed and is re-armed on socket
  /// loss, so a bind issued across a reconnect can wait for the next
  /// establishment instead of failing on the transient pre-establishment
  /// window.
  late Completer<void> _establishedReady;

  final _established$ = StreamController<void>.broadcast();
  final _takeovers = StreamController<void>.broadcast();
  final _sessionDown = StreamController<void>.broadcast();
  final _messageTooLarge = StreamController<MessageTooLarge>.broadcast();
  final _projectStreamEvents = StreamController<ProjectStreamEvent>.broadcast();

  /// Projects the agent has told us are dialable — from a live or
  /// snapshot-replayed `stream-ready {projectId}`, or an `agent:projects`
  /// entry with `running:true`. See [_markReady]/[_markNotReady].
  final Set<String> _readyProjects = {};

  /// Per-project waiter for the FIRST readiness signal after
  /// [openProject]/a reopen sent `project:start` — resolved by [_markReady],
  /// failed by a rejecting `control:result`.
  final Map<String, Completer<void>> _readyWaiters = {};

  /// Completes on the FIRST `session:established`; errors if the session is disposed
  /// beforehand. One-shot — never await it to observe a re-establishment (use
  /// [ensureEstablished] or [established]).
  ///
  /// Errors may land before anyone awaits (dispose-before-established) — the
  /// `ignore()` in the constructor keeps those from surfacing as unhandled
  /// async errors while real awaiters still observe them.
  Future<void> get ready => _readyCompleter.future;

  /// `true` once the peer session is established at least once and still live.
  bool get isEstablished => _established;

  /// Fires on EVERY (re)establishment. [ready] cannot serve
  /// that purpose — it is one-shot, so after the first establishment it can no
  /// longer tell a caller that the session came back.
  Stream<void> get established => _established$.stream;

  /// Fires when the agent hands this machine's session to another device
  /// (`session:takeover`). Report-only: the session is already torn down
  /// when this emits and NOTHING here re-establishes it, because two devices
  /// each reclaiming on takeover would evict each other forever.
  Stream<void> get takeoverEvents => _takeovers.stream;

  /// Fires when a hello attempt ends with no live session (the agent never
  /// answered `session:established`).
  ///
  /// Nothing here retries: retry pacing and give-up belong to the caller's
  /// connection supervisor, and a supervisor can only re-drive what it is told
  /// about. Without this signal the socket looks healthy, the `established`
  /// rung reads satisfied off a torn-down session, and the ladder never runs
  /// again. The socket-death and takeover paths have their own signals, so
  /// this one deliberately does not double-report them.
  Stream<void> get sessionDownEvents => _sessionDown.stream;

  Stream<MessageTooLarge> get messageTooLarge => _messageTooLarge.stream;

  /// `open:true` once per bind (after the bridge's first `stream-ready`
  /// record); `open:false` once per bound stream's end, or at session loss,
  /// whichever comes first.
  Stream<ProjectStreamEvent> get projectStreamEvents =>
      _projectStreamEvents.stream;

  /// The session-stream transport (the machine control plane). Created on
  /// first use and kept until disposed — a later access rebuilds it.
  StreamTransport get control {
    final existing = _streams[kSessionStreamLabel];
    if (existing != null) return existing;
    final st = StreamTransport._control(this);
    _streams[kSessionStreamLabel] = st;
    if (_established) unawaited(st.refreshSnapshot());
    return st;
  }

  /// The live transport for [projectId], bound or not; null if none.
  StreamTransport? projectTransport(String projectId) => _streams[projectId];

  /// Live project transports this session holds, excluding the control entry
  /// — what [kStreamMaxProjectsPerPeer] bounds.
  int get _projectStreamCount =>
      _streams.length - (_streams.containsKey(kSessionStreamLabel) ? 1 : 0);

  /// Returns [projectId]'s transport once its project stream is bound (the
  /// bridge's first record was `stream-ready`). Creates the transport on
  /// first use; concurrent calls for the same project share one attempt.
  ///
  /// Sequence, under ONE deadline:
  ///  1. wait for establishment;
  ///  2. unless a ready notice for [projectId] has been seen since
  ///     establishment or since this project's last stream end, send
  ///     [startMessage] on the session stream and await
  ///     `stream-ready {projectId}` (or an `agent:projects` entry
  ///     `running:true`) — a rejecting `control:result` fails with
  ///     [ProjectBindException];
  ///  3. over [kStreamMaxProjectsPerPeer] fails at once with
  ///     `ProjectBindException('CAP_EXCEEDED', …)` and never waits;
  ///  4. open the native stream ([PeerLink.openStream]);
  ///  5. first record: `stream-ready` → bound; `stream:refused` → a
  ///     [ProjectBindException] named by the refusal. A `NOT_READY` refusal
  ///     clears the ready mark and repeats from 2 once, then fails.
  ///
  /// A failed call disposes a transport it created for this call.
  Future<StreamTransport> openProject(
    String projectId,
    Map<String, dynamic> startMessage, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_disposed) throw StateError('session disposed');
    final deadline = DateTime.now().add(timeout);
    var st = _streams[projectId];
    // A disposed transport stays registered until its stream drains (it still
    // holds the bridge's cap slot), but it can never carry traffic again:
    // handing it out would give the caller a dead transport. Wait for it to
    // leave, then open fresh.
    while (st != null && st._disposed) {
      try {
        await st._removed.future.timeout(_remainingUntil(deadline));
      } on TimeoutException {
        throw ProjectBindException(
          'E_TIMEOUT',
          'previous project stream is still draining',
        );
      }
      if (_disposed) throw StateError('session disposed');
      st = _streams[projectId];
    }
    if (st == null) {
      // Checked before any wait (step 3 "never waits"): a project not
      // already tracked can only ever draw a fresh slot, and whether one is
      // free is known synchronously.
      if (_projectStreamCount >= kStreamMaxProjectsPerPeer) {
        throw ProjectBindException('CAP_EXCEEDED', 'too many project streams');
      }
      st = StreamTransport._project(this, projectId);
      _streams[projectId] = st;
    }
    st._openCallers++;
    try {
      await st._ensureBound(startMessage, _remainingUntil(deadline));
      st._handedOut = true;
      return st;
    } catch (_) {
      // Only a transport no caller ever received and no concurrent open is
      // still waiting on is ours to dispose; one already handed out belongs
      // to its holder, who keeps its reopen path.
      if (st._openCallers == 1 &&
          !st._handedOut &&
          identical(_streams[projectId], st)) {
        _streams.remove(projectId);
        unawaited(st.dispose());
      }
      rethrow;
    } finally {
      st._openCallers--;
    }
  }

  /// Writes [message] as a bare control-plane `AbMessage` record on the
  /// session stream. Dropped when no session generation is live
  /// (pre-establishment / mid-reconnect) — the bridge replays durable state
  /// via `state.snapshot` on the next establishment.
  ///
  /// Resolves once the message has been handed to the link or dropped, never
  /// when it has merely been queued behind sends already in flight. A caller
  /// that cannot wait for those to drain first must impose its own timeout.
  Future<void> sendOnSession(
    Map<String, dynamic> message,
    String channel,
  ) {
    final type = message['type'] is String ? message['type'] as String : null;
    if (_generation == null) {
      // Usually benign (the bridge replays durable state on establishment),
      // but it is also where a session that never comes back shows up first,
      // and nothing else on this path observes it. Dropped rather than
      // queued: the snapshot pull on the next establishment is the reconnect
      // contract, not a backlog of messages the peer has since moved past.
      _dropped(
        'tx',
        'no-established-session',
        channel: channel,
        streamId: kSessionStreamLabel,
        streamKind: 'session',
        msgType: type,
      );
      // Info, not warn: the comment above is right that this is usually the
      // benign reconnect case, and a terminal being typed into reaches here
      // once per keystroke. It earns a line at all because a session that
      // never comes back looks exactly like the benign case until someone can
      // count how long the drops went on.
      _log(
        RelayLogLevel.info,
        'send dropped — no session',
        fields: {'channel': channel, 'msgType': type},
      );
      return Future.value();
    }
    final plaintext = jsonEncode(message);
    final bytes = utf8ByteLength(plaintext);
    if (bytes > kStreamProjectAppRecordMaxBytes) {
      _dropped(
        'tx',
        'message-too-large',
        channel: channel,
        streamId: kSessionStreamLabel,
        streamKind: 'session',
        msgType: type,
        detail: {'bytes': bytes},
      );
      if (!_messageTooLarge.isClosed) {
        _messageTooLarge.add(MessageTooLarge(type, bytes));
      }
      return Future.value();
    }
    // Captured now, not when this send reaches the front of the chain: a
    // teardown mid-queue must drop a frame written for a session that is
    // already gone rather than hand it to a successor session.
    final gen = _generation;
    final result = _sessionSendChain.then(
      (_) => _doSendOnSession(plaintext, channel, type, gen),
    );
    // The chain keeps only completion order: one link's throw is its own
    // caller's to see, and must not reject every later send behind it.
    _sessionSendChain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Writes one session-stream record queued by [sendOnSession], rechecking
  /// [gen] at dequeue: a session teardown while this send waited its turn in
  /// [_sessionSendChain] must drop the frame rather than hand it to whatever
  /// session comes next.
  Future<void> _doSendOnSession(
    String plaintext,
    String channel,
    String? type,
    _SessionGeneration? gen,
  ) async {
    if (!identical(gen, _generation)) {
      _dropped(
        'tx',
        'no-established-session',
        channel: channel,
        streamId: kSessionStreamLabel,
        streamKind: 'session',
        msgType: type,
      );
      // Warn where [sendOnSession]'s twin is info: this frame was accepted for
      // sending, so its caller was told it would go out and is awaiting a
      // hand-off that now never comes.
      _log(
        RelayLogLevel.warn,
        'queued frame dropped — session went down before it was sent',
        fields: {
          'channel': channel,
          'streamId': kSessionStreamLabel,
          'msgType': type,
        },
      );
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(plaintext));
    if (!relay.isDispatchAllowed) return;
    final outcome = await relay.sendRecord(bytes);
    if (outcome != PeerSendOutcome.accepted || !identical(gen, _generation)) {
      // A generation change between the send and its outcome means a teardown
      // or a fresh hello already retired the session this frame was written
      // for — the peer either never saw it or has since moved on.
      return;
    }
    _emitSessionFrameRow('tx', type, frameId: _frameId(bytes), bytes: bytes.length);
  }

  /// Detach [streamId]'s transport.
  void removeStream(String streamId) {
    _streams.remove(streamId);
  }

  /// [removeStream] for [st] only: a transport disposed while a fresh one for
  /// the same project was already registered must not evict its successor.
  void _removeTransport(StreamTransport st) {
    if (identical(_streams[st.streamId], st)) removeStream(st.streamId);
    if (!st._removed.isCompleted) st._removed.complete();
  }

  // --- socket transitions ---------------------------------------------------

  /// A session is per-CONNECTION, so only the socket dying invalidates it.
  /// Every other transition is left alone: with pairing gone there is no
  /// grant whose loss could strand an otherwise-live session, and the
  /// supervisor re-drives [ensureEstablished] on whatever it observes.
  void _onState(PeerLinkState s) {
    if (s == PeerLinkState.closed) {
      _teardownSession();
    }
  }

  void _armEstablishedReady() {
    _establishedReady = Completer<void>();
    // dispose() can fail this before any [openProject] awaits it — same
    // unobserved-error guard as [_readyCompleter].
    _establishedReady.future.ignore();
  }

  void _teardownSession() {
    // Drop all session state — called when the socket dies and when the agent
    // hands the session to another device. A session is per-connection; either
    // event invalidates it.
    _established = false;
    _generation = null;
    _stopLiveness();
    _cancelPendingWork();
    // Readiness is per-CONNECTION too (a fresh hello re-registers the core
    // from scratch on the bridge side) — cleared wholesale rather than left
    // for each stream's own end to trickle it away.
    _readyProjects.clear();
    for (final w in _readyWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('session lost'));
    }
    _readyWaiters.clear();
    for (final s in _streams.values) {
      s._onConnectionLost();
    }
    // Re-arm only from the completed state: a second blip before the first
    // establishment would otherwise orphan whoever is already awaiting.
    if (_establishedReady.isCompleted) _armEstablishedReady();
  }

  void _cancelPendingWork() {
    // Fail every in-flight RPC now: their replies can never arrive on a dead
    // session, so waiting out each timeout is a pure fail-slow spinner. Tier-3
    // hydration re-drives on the next establishment; tier-2 actions surface
    // the failure for the user to retry.
    for (final s in _streams.values) {
      s.failAllPending(code: 'E_SESSION_DOWN', message: 'relay session down');
    }
  }

  // --- handshake --------------------------------------------------------

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
    final ok = await _handshaker.perform();
    if (_disposed) return;
    if (!ok) {
      // There is never a second hello on the same link — a failed attempt
      // means the connection itself is abandoned, not just the session.
      _teardownSession();
      unawaited(relay.close());
      return;
    }
    _generation = _SessionGeneration(++_epochCounter);
    if (!_establishedReady.isCompleted) _establishedReady.complete();
    _established = true;
    _lastRecv = DateTime.now();
    _missedPongs = 0;
    _startLiveness();
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    if (!_established$.isClosed) _established$.add(null);
    // Defensive re-clear: `_teardownSession` already cleared it, and nothing
    // repopulates it while `_generation` is null, but a first-ever
    // establishment never ran a teardown.
    _readyProjects.clear();
    // Re-pull durable state on every (re)establish so late subscribers
    // (a ControlPlaneClient, a just-bound project stream) replay it. The
    // control transport re-pulls; every live project transport reopens AT
    // ONCE with no backoff — each reopen's own bind is what re-pulls its
    // durable state (see StreamTransport._onOpen).
    for (final s in _streams.values) {
      if (s.projectId == null) {
        unawaited(s.refreshSnapshot());
      } else {
        s._reopenAtEstablish();
      }
    }
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

  /// The app's own wedge probe: a bridge whose event loop is stuck but whose
  /// QUIC stack still acks would otherwise look alive forever. A dead bridge
  /// is caught instead by `kPeerQuicMaxIdleTimeout` closing the connection.
  void _checkLiveness() {
    if (_disposed || !_established) return;
    if (_handshakeInFlight) return;
    final silentFor = DateTime.now().difference(_lastRecv);
    if (silentFor < pingSilence) return;
    if (_missedPongs >= kMaxMissedPongs) {
      // Ahead of _stopLiveness, which zeroes the count this line reports.
      _log(
        RelayLogLevel.warn,
        'session declared dead — closing the link',
        fields: {
          'silentForMs': silentFor.inMilliseconds,
          'missedPongs': _missedPongs,
        },
      );
      // A session with no in-place repair: closing the link is the whole
      // recovery, and the supervisor redials with a fresh session.
      _stopLiveness();
      unawaited(relay.close());
      return;
    }
    _missedPongs++;
    unawaited(_sendSessionFrame({'type': kSessionPing}).catchError((_) {}));
  }

  // --- frame capture --------------------------------------------------------

  /// Read off the socket rather than injected, so a capture is wired in exactly
  /// one place (`app/lib/providers/relay_connection.dart`) and the two layers
  /// can never disagree about whether one is armed.
  RelayNetTap? get _tap => relay.netTap;

  String? _frameId(Uint8List payload) =>
      _tap == null ? null : frameIdOf(payload);

  /// One row per session-stream record, in each direction: applies to session
  /// frames and control-plane `AbMessage`s alike, since both ride this
  /// stream.
  void _emitSessionFrameRow(
    String dir,
    String? type, {
    required String? frameId,
    required int bytes,
  }) {
    final tap = _tap;
    if (tap == null || frameId == null) return;
    tap({
      'op': 'frame',
      'dir': dir,
      'kind': 'frame',
      'transport': 'iroh',
      'channel': 'control',
      'streamKind': 'session',
      'streamId': kSessionStreamLabel,
      'msgType': type,
      'bytes': bytes,
      'frameId': frameId,
    });
  }

  void _log(
    RelayLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  }) {
    _logger?.call(level, message, fields: fields);
  }

  void _dropped(
    String dir,
    String reason, {
    String? channel,
    String? streamId,
    String? streamKind,
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
      'streamKind': streamKind,
      'msgType': msgType,
      'frameId': frameId,
      'reason': reason,
      'detail': detail,
    });
  }

  /// One purpose-specific stream's open/refused/reset/ended, so a capture can
  /// see the shape of a request even when every record on it stays opaque
  /// (an upload's raw bytes, a tunnel body). [reason] is `stream-open`,
  /// `stream-refused`, `stream-reset` or `stream-ended`.
  void _tapLifecycle(
    String streamKind,
    String streamId,
    String reason, {
    Map<String, Object?>? detail,
  }) {
    _tap?.call({
      'op': 'frame',
      'dir': 'tx',
      'kind': 'lifecycle',
      'streamKind': streamKind,
      'streamId': streamId,
      'reason': reason,
      'detail': detail,
    });
  }

  // --- inbound dispatch (session stream) -------------------------------------

  /// Synchronous and in order: QUIC/TLS is the confidentiality layer now, so
  /// there is no per-frame async decrypt step left to chain — the old
  /// per-channel tail existed only to keep a slow `open()` from letting a
  /// small frame overtake a large one, and a plain UTF-8 decode never blocks.
  void _onSessionRecord(IncomingSessionRecord msg) {
    if (_disposed || !relay.isDispatchAllowed || _generation == null) return;
    String plaintext;
    try {
      plaintext = utf8.decode(msg.payload);
    } catch (_) {
      _dropped('rx', 'bad-utf8', channel: 'control');
      return;
    }
    // Null unless a tap is armed: a bridge record can be a whole
    // MAX_TRANSFER_BYTES reply, and hashing it serves only the capture.
    final frameId = _frameId(msg.payload);
    _lastRecv = DateTime.now();
    _missedPongs = 0;
    _dispatchDecoded(plaintext, frameId, msg.payload.length);
  }

  /// [frameId] names the frame this plaintext arrived in, for the capture tap;
  /// [bytes] is the record's payload length.
  void _dispatchDecoded(String plaintext, String? frameId, int bytes) {
    if (_disposed || _generation == null || !relay.isDispatchAllowed) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (_) {
      _dropped(
        'rx',
        'plaintext-not-json',
        channel: 'control',
        streamId: kSessionStreamLabel,
        streamKind: 'session',
        frameId: frameId,
      );
      return;
    }
    final type = json['type'];
    if (type is! String) {
      _dropped(
        'rx',
        'unrecognized-plaintext',
        channel: 'control',
        streamId: kSessionStreamLabel,
        streamKind: 'session',
        frameId: frameId,
      );
      return;
    }
    _emitSessionFrameRow('rx', type, frameId: frameId, bytes: bytes);
    if (isSessionFrameType(type)) {
      _handleSessionFrame(json, frameId);
      return;
    }
    _snoopControl(json);
    // Not the `control` getter: creating the transport here would fire a
    // snapshot pull nobody asked for. Adverts were snooped above, so a
    // session with no control transport yet loses nothing.
    _streams[kSessionStreamLabel]?.dispatchFromSession(json, 'control');
  }

  /// Snoop control-plane adverts for project readiness so [openProject] can
  /// resolve and a stream's reopen can self-trigger. Called for LIVE frames
  /// and for `state.snapshot`-replayed frames alike — the bridge's
  /// replay-cache dedup can legally suppress a byte-identical live re-advert
  /// after an app kill+reopen, so the snapshot pull is the reconnect binding
  /// contract, not a cache warm-up.
  void _snoopControl(Object? m) {
    if (m is! Map<String, dynamic>) return;
    final type = m['type'];
    if (type == 'stream-ready') {
      final pid = m['projectId'];
      if (pid is String) _markReady(pid);
    } else if (type == 'agent:projects') {
      final projects = m['projects'];
      if (projects is List) {
        final running = <String>{};
        for (final p in projects) {
          if (p is Map<String, dynamic>) {
            final pid = p['projectId'];
            if (pid is String && p['running'] == true) running.add(pid);
          }
        }
        // The advert is the agent's COMPLETE dialable catalog: a project it
        // does not list as running is not ready, even if an earlier ready
        // notice said otherwise (a restart re-attached it, or it was
        // stopped).
        for (final pid in Set<String>.of(_readyProjects)) {
          if (!running.contains(pid)) _markNotReady(pid);
        }
        for (final pid in running) {
          _markReady(pid);
        }
      }
    } else if (type == 'control:result' &&
        m['ok'] == false &&
        m['verb'] == 'project:start') {
      // A rejected project:start (for example NOT_ALLOWED / NOT_READY) —
      // fail the pending bind with the real reason instead of letting it run
      // out its blind timeout. The `verb` match is load-bearing: the bridge
      // echoes `projectId` on EVERY failed control-plane verb, so matching on
      // `ok:false` alone would let an unrelated rejection kill a healthy
      // bind with a bogus code.
      final pid = m['projectId'];
      if (pid is String) {
        final waiter = _readyWaiters.remove(pid);
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

  /// Marks [projectId] ready and resolves whoever is waiting for that. When
  /// this is a fresh transition (not already ready) and a live transport for
  /// the project is sitting unbound with no bind in flight, opportunistically
  /// starts its (re)open — the "becomes ready while unbound" case in
  /// [openProject]'s doc.
  void _markReady(String projectId) {
    final isNewlyReady = _readyProjects.add(projectId);
    final waiter = _readyWaiters.remove(projectId);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    if (!isNewlyReady || _disposed) return;
    final st = _streams[projectId];
    if (st == null || st._bound || st._bindInFlight != null) return;
    final builder = projectStartMessageBuilder;
    unawaited(
      st
          ._ensureBound(
            builder == null ? null : builder(projectId),
            const Duration(seconds: 20),
          )
          .catchError((_) => st),
    );
  }

  void _markNotReady(String projectId) => _readyProjects.remove(projectId);

  void _handleSessionFrame(Map<String, dynamic> json, String? frameId) {
    switch (json['type']) {
      case kSessionPing:
        unawaited(_sendSessionFrame({'type': kSessionPong}).catchError((_) {}));
        break;
      case kSessionPong:
        _missedPongs = 0;
        break;
      case kSessionTakeover:
        // The agent is switching to another device and is about to drop our
        // session. Tear down and REPORT — re-establishing here would fight the
        // other device for it.
        _teardownSession();
        if (!_takeovers.isClosed) _takeovers.add(null);
        break;
      default:
        _dropped('rx', 'unknown-session-frame', frameId: frameId);
    }
  }

  Future<void> _sendSessionFrame(Map<String, dynamic> obj) async {
    final gen = _generation;
    final type = obj['type'] as String?;
    if (gen == null) {
      _dropped('tx', 'no-established-session', channel: 'control', msgType: type);
      // This path carries ping and pong — the frames the peer reads as proof
      // we are alive. Losing one is indistinguishable at the far end from a
      // link that has gone dead, so it must never be diagnosed only from an
      // unarmed tap.
      _log(
        RelayLogLevel.warn,
        'session frame dropped — no session',
        fields: {'msgType': type},
      );
      return;
    }
    final ct = Uint8List.fromList(utf8.encode(jsonEncode(obj)));
    if (!relay.isDispatchAllowed) return;
    final outcome = await relay.sendRecord(ct);
    if (outcome != PeerSendOutcome.accepted || !identical(gen, _generation)) {
      // A generation change between the send and its outcome means a teardown
      // or a fresh hello already retired the session this frame was written
      // for.
      return;
    }
    // Liveness frames are the cheapest signal that a session is alive at all —
    // a capture where ping goes out and pong never comes back is the whole
    // diagnosis for a silently dead socket.
    _emitSessionFrameRow('tx', type, frameId: _frameId(ct), bytes: ct.length);
  }

  Future<void> dispose() async {
    _disposed = true;
    _handshaker.abort();
    _stopLiveness();
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    // Before the transports: a project still waiting on its ready notice
    // must fail now, not hold its transport's dispose until the deadline.
    for (final w in _readyWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('session disposed'));
    }
    _readyWaiters.clear();
    for (final s in List<StreamTransport>.of(_streams.values)) {
      await s.dispose();
    }
    _streams.clear();
    _readyProjects.clear();
    _tunnelSlots.failAll();
    _uploadSlots.failAll();
    await _established$.close();
    await _takeovers.close();
    await _sessionDown.close();
    await _messageTooLarge.close();
    await _projectStreamEvents.close();
    _generation = null;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(StateError('session disposed'));
    }
    if (!_establishedReady.isCompleted) {
      _establishedReady.completeError(StateError('session disposed'));
    }
  }

  // --- terminal-attachment / tunnel / upload slot pools ---------------------

  /// Terminal attachments fail fast over the cap (`CAP_EXCEEDED`) instead of
  /// stalling on `openBi` against the bridge's own per-peer limit. Tunnel
  /// (HTTP and WS share one pool) and upload streams instead wait FIFO
  /// (stage-A-A3-contract.md §9 D-5): a page load issues more parallel
  /// requests than any cap, and that is not the user's error.
  final _terminalSlots = _StreamSlots(kStreamMaxTerminalAttachmentsPerPeer);
  final _tunnelSlots = _StreamSlots(kStreamMaxTunnelStreamsPerPeer);
  final _uploadSlots = _StreamSlots(kStreamMaxUploadStreamsPerPeer);

  /// Begin driving the session: subscribe to the socket and liveness.
  /// Call once, right after construction.
  ///
  /// Deliberately does NOT start a handshake. The connection supervisor climbs
  /// the ladder and calls [ensureEstablished] once the agent is reachable —
  /// having two components decide when to handshake is what the level-triggered
  /// supervisor replaced.
  void start() {
    _msgSub = relay.messageStream.listen(_onSessionRecord);
    _stateSub = relay.payloadStateStream.listen(_onState);
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
}

/// Time left before [deadline], floored at zero — a negative [Duration] passed
/// to `Future.timeout` is not a meaningful budget.
Duration _remainingUntil(DateTime deadline) {
  final left = deadline.difference(DateTime.now());
  return left.isNegative ? Duration.zero : left;
}

/// Completes when [future] settles or [wait] elapses, whichever is first —
/// never with [future]'s error, since a caller bounded by [wait] only wants to
/// know when to stop waiting. [future] itself is never cancelled and keeps
/// running to its own conclusion; the timer is cancelled the moment it
/// settles, so it never outlives this call.
Future<void> _firstOf(Future<void> future, Duration wait) {
  final completer = Completer<void>();
  Timer? timer;
  void settle() {
    timer?.cancel();
    if (!completer.isCompleted) completer.complete();
  }

  future.then((_) => settle(), onError: (Object _) => settle());
  timer = Timer(wait, settle);
  return completer.future;
}

/// One capped pool of stream slots, shared by the terminal, tunnel and upload
/// exchanges. [tryTake] fails fast (terminal attachments: `CAP_EXCEEDED`
/// beats stalling on `openBi` against the bridge's own limit); [acquire]
/// queues FIFO instead (tunnel and upload: a batch of requests past the cap
/// is not the user's error). [Map] insertion order is what makes the FIFO
/// order — the oldest waiter is always `_waiters.keys.first`.
class _StreamSlots {
  _StreamSlots(this._cap);

  final int _cap;
  int _held = 0;
  final _waiters = <Object, Completer<bool>>{};

  bool tryTake() {
    if (_held >= _cap) return false;
    _held++;
    return true;
  }

  /// `true` once [owner] holds a slot; `false` if [cancelWait] or [failAll]
  /// settles the wait first — the caller distinguishes those (`CANCELLED` vs
  /// `TRANSPORT_CLOSED`) itself, since only it knows which one happened. A
  /// free slot is granted synchronously so the open frame leaves in the same
  /// turn as the call, with no microtask for a racing cancel.
  FutureOr<bool> acquire(Object owner) {
    if (_held < _cap) {
      _held++;
      return true;
    }
    final completer = Completer<bool>();
    _waiters[owner] = completer;
    return completer.future;
  }

  /// No-op once [owner]'s wait has already resolved (a slot was granted, or
  /// [failAll] already failed it).
  void cancelWait(Object owner) {
    final completer = _waiters.remove(owner);
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  /// Hands the freed slot straight to the oldest waiter instead of just
  /// decrementing the count: a waiter that never gets told a slot is free
  /// would otherwise starve behind every open that came before it.
  void release() {
    if (_waiters.isNotEmpty) {
      final owner = _waiters.keys.first;
      final completer = _waiters.remove(owner)!;
      completer.complete(true);
      return;
    }
    if (_held > 0) _held--;
  }

  void failAll() {
    for (final w in _waiters.values) {
      if (!w.isCompleted) w.complete(false);
    }
    _waiters.clear();
  }
}

/// The session-stream (control-plane) or one project's [AgentTransport] view
/// over a [MachineSession]. Interface-compatible with the pre-A4 transport:
/// services and `BufferedAgentTransport` RPC plumbing are unchanged; `send()`
/// delegates to the session (control) or to this project's own native stream,
/// and `dispatchFromSession` receives only this transport's decoded messages.
class StreamTransport extends BufferedAgentTransport {
  final MachineSession session;

  /// Null for the control (session-stream) transport; the project id for a
  /// project transport. Fixed for the transport's lifetime — a project's
  /// identity IS its stream now, so there is nothing left to re-point after a
  /// restart (Stage A A4 retired the old streamId-migration dance).
  final String? projectId;

  StreamTransport._control(this.session) : projectId = null, _bound = true;

  StreamTransport._project(this.session, String this.projectId)
    : _bound = false;

  /// Diagnostic and eval handle only — `"0"` for control, else [projectId].
  String get streamId => projectId ?? kSessionStreamLabel;

  /// `true` for control, always. For a project, `true` only while its native
  /// stream is open and its first `stream-ready` record has arrived.
  bool _bound;
  bool get isProjectBound => _bound;

  // --- project-stream state (unused, and always default, for control) ------

  PeerStream? _peerStream;
  bool _disposed = false;
  bool _openNotified = false;
  Completer<void>? _bindInFlight;
  Completer<void>? _disposeDrained;
  PeerStream? _drainingStream;

  /// Completes once this transport has left the session's registry — what a
  /// racing [MachineSession.openProject] waits on before opening fresh.
  final Completer<void> _removed = Completer<void>();
  Timer? _reopenTimer;
  int _reopenAttempt = 0;
  Future<void> _sendChain = Future<void>.value();

  /// Per-project-stream RPC-timeout accounting (meaningful only when
  /// [projectId] is non-null). Bumped on every fresh bind so an outcome from a
  /// binding this transport has since left behind — a superseded reopen — can
  /// never count against the current one.
  int _bindEpoch = 0;
  int _timeoutStreak = 0;

  /// Consecutive health resets with no answered RPC in between — what
  /// [_onOpen] uses to back the reopen off instead of hammering a stream that
  /// keeps timing out.
  int _healthResets = 0;

  /// [MachineSession.openProject] calls currently waiting on this transport.
  int _openCallers = 0;

  /// Set once an [MachineSession.openProject] call has returned this
  /// transport to a caller.
  bool _handedOut = false;

  @override
  bool get isLocal => false;

  // A stream stays TransportState.connected across a session-down window (the
  // socket may be fine; only the peer session drops), so the base "connected ==
  // established" is wrong here — a hydrator firing then would send into
  // nothing. The live peer session (and, for a project, its own bound stream)
  // is the truth.
  @override
  bool get isEstablished =>
      projectId == null ? session.isEstablished : (session.isEstablished && _bound);

  @override
  Future<void> connect() async {
    setState(TransportState.connected);
    if (projectId != null) {
      // The bind that produced this (bound) transport already ran
      // refreshSnapshot(); an unbound one has nothing to pull yet and will
      // when it binds.
      return;
    }
    // Seed durable state — but only when the session can carry the request:
    // without keys sendOnSession drops it and the RPC would burn its full
    // timeout to report what is already known. Nothing is lost, since every
    // attached stream is refreshed on each (re)establish.
    if (!session.isEstablished) return;
    await _fetchSnapshot(wait: session.snapshotTimeout * 2);
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) => projectId == null
      ? session.sendOnSession(message, channel)
      : _sendProject(message, channel);

  // --- project-stream bind / reopen ----------------------------------------

  /// Ensures this project transport is bound, sharing one in-flight attempt.
  /// A no-op (returns immediately) for the control transport.
  Future<StreamTransport> _ensureBound(
    Map<String, dynamic>? startMessage,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (projectId == null || _bound) return this;
      final inFlight = _bindInFlight;
      if (inFlight == null) break;
      try {
        await inFlight.future.timeout(_remainingUntil(deadline));
        return this;
      } on TimeoutException {
        // The shared attempt ran under the FIRST caller's deadline. A caller
        // that joined it with time to spare runs its own attempt rather than
        // inheriting a shorter caller's give-up; any other failure is the
        // bridge's answer and is shared as is.
        if (_disposed || startMessage == null) rethrow;
        if (!DateTime.now().isBefore(deadline)) rethrow;
      }
    }

    _reopenTimer?.cancel();
    _reopenTimer = null;
    final completer = Completer<void>();
    completer.future.ignore();
    _bindInFlight = completer;
    Object? error;
    StackTrace? stack;
    try {
      await _attemptBind(startMessage, _remainingUntil(deadline));
    } catch (e, s) {
      error = e;
      stack = s;
    }
    if (identical(_bindInFlight, completer)) _bindInFlight = null;
    if (error != null) {
      completer.completeError(error, stack);
      if (!_disposed && !_bound) _scheduleReopen();
      Error.throwWithStackTrace(error, stack!);
    }
    completer.complete();
    return this;
  }

  Future<void> _attemptBind(
    Map<String, dynamic>? startMessage,
    Duration timeout,
  ) async {
    final pid = projectId!;
    final deadline = DateTime.now().add(timeout);
    if (session._generation == null) {
      try {
        await session._establishedReady.future.timeout(_remainingUntil(deadline));
      } on TimeoutException {
        throw StateError('openProject: session not established');
      }
    }
    var retriedNotReady = false;
    while (true) {
      if (_disposed) throw StateError('transport disposed');
      if (!session._readyProjects.contains(pid)) {
        if (startMessage == null) {
          throw ProjectBindException(
            'NOT_READY',
            'project is not ready; wait for stream-ready',
          );
        }
        await _awaitProjectReady(pid, startMessage, deadline);
      }
      PeerStream stream;
      try {
        stream = await session.relay
            .openStream(
              ProjectStreamOpen(pid),
              maxRecordBytes: kStreamProjectBridgeRecordMaxBytes,
              maxQueuedBytes: kProjectStreamMaxQueuedBytes,
            )
            .timeout(_remainingUntil(deadline));
      } catch (e) {
        throw ProjectBindException('STREAM_OPEN_FAILED', '$e');
      }
      if (_disposed) {
        _quietly(stream.reset());
        throw StateError('transport disposed');
      }
      _peerStream = stream;
      final outcome = await _bindOverStream(stream, pid, deadline);
      if (outcome == _BindOutcome.bound) return;
      // outcome == _BindOutcome.notReadyRetry. The bridge has no live core
      // for the project, so the ready mark this open trusted is stale: clear
      // it so the retry re-sends project:start instead of reopening at once.
      if (identical(_peerStream, stream)) _peerStream = null;
      session._markNotReady(pid);
      if (retriedNotReady || startMessage == null) {
        throw ProjectBindException(
          'NOT_READY',
          'project is not ready; wait for stream-ready',
        );
      }
      retriedNotReady = true;
    }
  }

  Future<void> _awaitProjectReady(
    String pid,
    Map<String, dynamic> startMessage,
    DateTime deadline,
  ) async {
    final waiter = session._readyWaiters.putIfAbsent(pid, () {
      final c = Completer<void>();
      c.future.ignore();
      return c;
    });
    await session
        .sendOnSession(startMessage, 'control')
        .timeout(_remainingUntil(deadline));
    await waiter.future.timeout(_remainingUntil(deadline));
  }

  /// Starts the persistent read loop over [stream] and resolves once its
  /// FIRST record settles the bind (or the stream ends before one arrives).
  Future<_BindOutcome> _bindOverStream(
    PeerStream stream,
    String pid,
    DateTime deadline,
  ) async {
    final firstCompleter = Completer<_BindOutcome>();
    unawaited(_runStream(stream, pid, firstCompleter));
    try {
      return await firstCompleter.future.timeout(_remainingUntil(deadline));
    } on TimeoutException {
      // Settled first so a `stream-ready` arriving after this give-up is
      // refused by the read loop rather than binding a stream nobody awaits.
      if (!firstCompleter.isCompleted) {
        firstCompleter.completeError(StateError('bind timed out'));
      }
      _quietly(stream.reset());
      throw ProjectBindException(
        'E_TIMEOUT',
        'project stream bind timed out',
      );
    }
  }

  /// The one continuous read loop for a project's native stream: the first
  /// record settles [firstCompleter] (bound / refused / a protocol
  /// violation), and every record after that is ordinary traffic —
  /// mirrors `_StreamTerminalAttachment._readRecords`'s "first flag inside one
  /// loop" shape.
  Future<void> _runStream(
    PeerStream stream,
    String pid,
    Completer<_BindOutcome> firstCompleter,
  ) async {
    var first = true;
    try {
      await for (final record in stream.records) {
        if (first) {
          first = false;
          final refusal = StreamRefused.tryDecode(record);
          if (refusal != null) {
            if (refusal.code == StreamRefusedCode.notReady) {
              if (!firstCompleter.isCompleted) {
                firstCompleter.complete(_BindOutcome.notReadyRetry);
              }
            } else if (!firstCompleter.isCompleted) {
              firstCompleter.completeError(
                ProjectBindException(refusal.code.wireValue, refusal.message),
              );
            }
            continue;
          }
          final json = _tryDecodeJsonRecord(_safeUtf8Decode(record));
          if (json != null &&
              json['type'] == 'stream-ready' &&
              json['projectId'] == pid) {
            // A bind that already gave up (timeout) or a stream a later open
            // has replaced must not bind: the transport would then carry a
            // stream no attempt owns while the bridge holds a second binding.
            if (_disposed ||
                firstCompleter.isCompleted ||
                !identical(_peerStream, stream)) {
              _quietly(stream.reset());
              if (!firstCompleter.isCompleted) {
                firstCompleter.completeError(StateError('transport disposed'));
              }
              continue;
            }
            _bound = true;
            if (!firstCompleter.isCompleted) {
              firstCompleter.complete(_BindOutcome.bound);
            }
            _onOpen();
            continue;
          }
          // A first record that is neither `stream:refused` nor a
          // `stream-ready` naming this project is a protocol error (§1.1):
          // reset our send half and fail the bind.
          _quietly(stream.reset());
          if (!firstCompleter.isCompleted) {
            firstCompleter.completeError(
              ProjectBindException(
                'INVALID_RECORD',
                'unexpected first record on project stream',
              ),
            );
          }
          continue;
        }
        // Records still buffered on a stream this transport has let go of
        // (session loss, a replacement open) belong to no live binding.
        if (!_bound || !identical(_peerStream, stream)) continue;
        _onProjectRecord(record);
      }
    } catch (_) {
      // The peer's half ending as an error reads the same as a clean FIN
      // here — there is nothing more to distinguish once the stream is gone.
    }
    if (!firstCompleter.isCompleted) {
      firstCompleter.completeError(
        ProjectBindException(
          'STREAM_ENDED',
          'project stream closed before it bound',
        ),
      );
    }
    _onStreamEnded(stream);
  }

  void _onProjectRecord(Uint8List record) {
    final text = _safeUtf8Decode(record);
    if (text == null) {
      session._dropped(
        'rx',
        'bad-record',
        channel: 'control',
        streamId: streamId,
        streamKind: 'project',
      );
      return;
    }
    _dispatchProjectMessage(text);
  }

  void _dispatchProjectMessage(String text) {
    final json = _tryDecodeJsonRecord(text);
    if (json == null) {
      session._dropped(
        'rx',
        'bad-record',
        channel: 'control',
        streamId: streamId,
        streamKind: 'project',
      );
      return;
    }
    dispatchFromSession(json, 'control');
  }

  Future<void> _sendProject(Map<String, dynamic> message, String channel) {
    final result = _sendChain.then((_) => _doSendProject(message, channel));
    // Errors are handled inside `_doSendProject` itself (it never throws), so
    // the chain's own future is always a plain success — nothing to catch
    // here.
    _sendChain = result;
    return result;
  }

  Future<void> _doSendProject(
    Map<String, dynamic> message,
    String channel,
  ) async {
    final type = message['type'] is String ? message['type'] as String : null;
    if (!_bound) {
      // The snapshot pull at the next bind is the reconnect contract, as it
      // was pre-establishment before A4.
      session._dropped(
        'tx',
        'no-project-stream',
        channel: channel,
        streamId: streamId,
        streamKind: 'project',
        msgType: type,
      );
      return;
    }
    final stream = _peerStream;
    if (stream == null) return; // Defensive: `_bound` implies a live stream.
    final plaintext = jsonEncode(message);
    final bytes = utf8ByteLength(plaintext);
    if (bytes > kStreamProjectAppRecordMaxBytes) {
      session._dropped(
        'tx',
        'message-too-large',
        channel: channel,
        streamId: streamId,
        streamKind: 'project',
        msgType: type,
        detail: {'bytes': bytes},
      );
      if (!session._messageTooLarge.isClosed) {
        session._messageTooLarge.add(MessageTooLarge(type, bytes));
      }
      return;
    }
    if (!_bound || !identical(_peerStream, stream)) return;
    PeerSendOutcome outcome;
    try {
      outcome = await stream.send(Uint8List.fromList(utf8.encode(plaintext)));
    } catch (_) {
      _quietly(stream.reset());
      return;
    }
    if (outcome != PeerSendOutcome.accepted) {
      // A dropped SendStream FINs; every error path resets explicitly. The
      // read loop observes the resulting end and runs `_onStreamEnded`.
      _quietly(stream.reset());
    }
  }

  /// Fresh bind (first ever, or a reopen): bump the epoch that fences RPC
  /// timeout/answer accounting to THIS binding, reset backoff unless a
  /// still-unanswered run of health resets says the stream keeps failing,
  /// tell [MachineSession.projectStreamEvents], then
  /// re-pull durable state — the per-stream reconciliation checkpoint (see
  /// [refreshSnapshot]).
  ///
  /// A stream that keeps timing out therefore reopens at 1 s, 2 s, 4 s … up to
  /// [kProjectStreamReopenMaxBackoff] instead of hammering at 1 s; the first
  /// answered RPC ([_noteAnswered]) clears [_healthResets] again.
  /// [_reopenAtEstablish] zeroes [_reopenAttempt] itself for a fresh session,
  /// unconditionally — that path starts clean regardless of what happened on
  /// the last connection.
  void _onOpen() {
    _bindEpoch++;
    _timeoutStreak = 0;
    if (_healthResets == 0) _reopenAttempt = 0;
    if (!_openNotified) {
      _openNotified = true;
      if (!session._projectStreamEvents.isClosed) {
        session._projectStreamEvents.add((projectId: projectId!, open: true));
      }
    }
    unawaited(refreshSnapshot());
  }

  /// Idempotent "the stream is not open any more" notice — called from BOTH
  /// [_onConnectionLost] (session loss) and [_onStreamEnded] (the stream's own
  /// end), whichever fires first; the other becomes a no-op.
  void _emitClosed() {
    if (!_openNotified) return;
    _openNotified = false;
    if (!session._projectStreamEvents.isClosed) {
      session._projectStreamEvents.add((projectId: projectId!, open: false));
    }
  }

  /// Eager, synchronous state reset when the whole session dies — see
  /// `MachineSession._teardownSession`. Letting go of [_peerStream] here makes
  /// the dying stream's own later end a stale one [_onStreamEnded] ignores:
  /// by then the next establishment may already have reopened.
  void _onConnectionLost() {
    if (projectId == null) return;
    _reopenTimer?.cancel();
    _reopenTimer = null;
    _bound = false;
    _peerStream = null;
    _emitClosed();
  }

  /// The read loop ended (peer FIN/reset, connection loss, or our own
  /// disposal draining out). Frees the slot and schedules a reopen — unless
  /// disposed (frees for good) or the session is currently down (the next
  /// establishment drives every live project transport's reopen directly, see
  /// `MachineSession._handshakeAttempt`).
  ///
  /// Only the end of the CURRENT stream counts: a refused, timed-out or
  /// session-lost stream can end long after a newer one took its place, and
  /// acting on it would unbind the live stream.
  void _onStreamEnded(PeerStream stream) {
    if (_disposed) {
      if (identical(_peerStream, stream)) _peerStream = null;
      if (identical(_drainingStream, stream)) {
        _drainingStream = null;
        session._removeTransport(this);
        _disposeDrained?.complete();
        _disposeDrained = null;
      }
      return;
    }
    if (!identical(_peerStream, stream)) return;
    _bound = false;
    _peerStream = null;
    _emitClosed();
    session._markNotReady(projectId!);
    // A bind in flight owns its own failure and reopen.
    if (session.isEstablished && _bindInFlight == null) _scheduleReopen();
  }

  /// At each (re)establishment every live project transport reopens AT ONCE,
  /// with no backoff — called from `MachineSession._handshakeAttempt`.
  void _reopenAtEstablish() {
    if (projectId == null || _disposed || _bound) return;
    _reopenTimer?.cancel();
    _reopenTimer = null;
    _reopenAttempt = 0;
    final builder = session.projectStartMessageBuilder;
    unawaited(
      _ensureBound(
        builder == null ? null : builder(projectId!),
        const Duration(seconds: 20),
      ).catchError((_) => this),
    );
  }

  /// Schedules a self-driven reopen with growing backoff. A no-op with no
  /// [MachineSession.projectStartMessageBuilder]: without one to build a fresh
  /// `project:start`, this stream can only be reopened by a ready notice (see
  /// `MachineSession._markReady`).
  void _scheduleReopen() {
    if (projectId == null || _disposed || _bound) return;
    final builder = session.projectStartMessageBuilder;
    if (builder == null) return;
    _reopenTimer?.cancel();
    final delay = _nextReopenDelay();
    _reopenTimer = Timer(delay, () {
      _reopenTimer = null;
      unawaited(
        _ensureBound(builder(projectId!), const Duration(seconds: 20))
            .catchError((_) => this),
      );
    });
  }

  Duration _nextReopenDelay() {
    final shift = _reopenAttempt.clamp(0, 8);
    if (_reopenAttempt < 8) _reopenAttempt++;
    final ms = kProjectStreamReopenInitialBackoff.inMilliseconds * (1 << shift);
    return Duration(
      milliseconds: ms.clamp(
        kProjectStreamReopenInitialBackoff.inMilliseconds,
        kProjectStreamReopenMaxBackoff.inMilliseconds,
      ),
    );
  }

  // --- RPC / hydration (shared by control and project transports) ----------

  /// RPC failures a project stream's own health accounting must not read as
  /// "the bridge answered": each already means this binding produced no
  /// application reply, so folding one into [_noteAnswered] would let a
  /// stream that cannot carry traffic at all look healthy. Any other code is
  /// the bridge's own application error, which proves the stream carried a
  /// reply.
  static const _kLocalRpcFailureCodes = {
    'E_TIMEOUT',
    'E_SEND_FAILED',
    'E_SESSION_DOWN',
    'E_STREAM_RESET',
    'E_DISPOSED',
  };

  @override
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final epoch = (projectId != null && _bound) ? _bindEpoch : null;
    try {
      final r = await super.request(method, params: params, timeout: timeout);
      _noteAnswered(epoch);
      return r;
    } on RpcException catch (e) {
      if (e.code == 'E_TIMEOUT') {
        _noteTimeout(epoch);
      } else if (!_kLocalRpcFailureCodes.contains(e.code)) {
        _noteAnswered(epoch);
      }
      rethrow;
    }
  }

  /// No-op for the control transport (whose [epoch] is always null) or for an
  /// outcome from a binding this transport has since left behind — a
  /// superseded reopen must not clear the streak the CURRENT binding is
  /// counting.
  void _noteAnswered(int? epoch) {
    if (epoch == null || epoch != _bindEpoch) return;
    _timeoutStreak = 0;
    _healthResets = 0;
  }

  void _noteTimeout(int? epoch) {
    if (epoch == null || epoch != _bindEpoch || !_bound) return;
    _timeoutStreak++;
    if (_timeoutStreak >= kProjectStreamTimeoutsToReset) _resetForHealth();
  }

  /// Three consecutive RPC timeouts on this project stream: reset and reopen
  /// THAT stream only, never the link — the control transport's only
  /// connection-level escape is the ping, and a project stream wedged while
  /// every other stream is fine is not the whole session's problem.
  void _resetForHealth() {
    final stream = _peerStream;
    session._log(
      RelayLogLevel.warn,
      'project stream reset after consecutive RPC timeouts',
      fields: {
        'streamId': streamId,
        'projectId': projectId,
        'timeouts': _timeoutStreak,
        'healthResets': _healthResets + 1,
      },
    );
    _timeoutStreak = 0;
    _healthResets++;
    if (stream != null) _quietly(stream.reset());
    failAllPending(
      code: 'E_STREAM_RESET',
      message: 'project stream reset after repeated timeouts',
    );
    // Mirrors what `_onStreamEnded` does for the current stream: the old
    // stream's later end is then stale and ignored, and its buffered records
    // are dropped by the existing identity guard.
    _bound = false;
    _peerStream = null;
    _emitClosed();
    session._markNotReady(projectId!);
    // A bind in flight owns its own failure and reopen.
    if (session.isEstablished && _bindInFlight == null) _scheduleReopen();
  }

  /// Deliver a decoded message that the session (or this project's own
  /// stream) demuxed to this transport.
  void dispatchFromSession(Map<String, dynamic> json, String channel) =>
      dispatchDecoded(json, channel);

  /// Opens a native terminal stream.
  @override
  TerminalAttachment openTerminalAttachment({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> subscribe,
  }) {
    final attachment = _StreamTerminalAttachment(
      transport: this,
      requestId: requestId,
      checkoutId: checkoutId,
      subscribe: subscribe,
    );
    attachment._start();
    return attachment;
  }

  /// Opens a native HTTP tunnel stream.
  @override
  TunnelHttpExchange openTunnelHttp({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required int bodyLength,
    Stream<List<int>>? body,
  }) {
    final exchange = _StreamTunnelHttpExchange(
      transport: this,
      requestId: requestId,
      checkoutId: checkoutId,
      head: head,
      bodyLength: bodyLength,
      body: body,
    );
    exchange._start();
    return exchange;
  }

  /// Opens a native WS tunnel stream — see [openTunnelHttp].
  @override
  TunnelWsChannel openTunnelWs({
    required String tunnelId,
    required String checkoutId,
    required Map<String, dynamic> open,
  }) {
    final channel = _StreamTunnelWsChannel(
      transport: this,
      tunnelId: tunnelId,
      checkoutId: checkoutId,
      open: open,
    );
    channel._start();
    return channel;
  }

  /// Opens a native upload stream.
  @override
  UploadExchange openUpload({
    required String requestId,
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) {
    if (fileName.length > kStreamUploadMaxFileNameLength) {
      return FailedUploadExchange(const UploadFailure('INVALID_NAME'), requestId);
    }
    final exchange = _StreamUploadExchange(
      transport: this,
      requestId: requestId,
      projectId: projectId,
      checkoutId: checkoutId,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType != null && mimeType.length <= kStreamUploadMaxMimeTypeLength
          ? mimeType
          : null,
      onProgress: onProgress,
    );
    exchange._start();
    return exchange;
  }

  @override
  void noteOrphanResponse(String? requestId, String channel) {
    // A late reply is proof the stream carried a request all the way to an
    // answer, even though it arrived after this transport gave up waiting —
    // the read loop only ever dispatches from the CURRENT bound stream (see
    // `_runStream`'s `!_bound || !identical(_peerStream, stream)` guard), so
    // an orphan did cross this binding. It clears the timeout streak but not
    // `_healthResets`: a stream this slow is not yet proven healthy.
    if (projectId != null && _bound) _timeoutStreak = 0;
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

  /// Re-pull the durable-state snapshot now that the session (or this
  /// project's stream) is (re)bound, then re-drive the tier-3 hydrators.
  /// Order matters: the snapshot replays the durable state first, then
  /// hydrators pull the view-state the snapshot does not carry (session list,
  /// config, the reopened file, the transcript). This is the per-stream
  /// reconciliation checkpoint.
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
  /// One request carries the whole pull, under [MachineSession.snapshotDeadline]
  /// — long enough that a reply landing after this call's own wait
  /// ([MachineSession.snapshotTimeout]) is still applied rather than discarded
  /// as late (see [_fetchSnapshot]). The hydrators do not depend on the
  /// snapshot having landed (a bundle built before it reads the frames live
  /// when they arrive), so they must not wait out a slow pull either.
  Future<void> refreshSnapshot() async {
    await _fetchSnapshot(wait: session.snapshotTimeout);
    redriveHydrators();
  }

  /// Re-pull the durable state alone, leaving the tier-3 hydrators as they are.
  ///
  /// [refreshSnapshot] exists for a (re)establishment, where the view-state the
  /// snapshot does not carry is stale too. A user asking one checkout to try
  /// attaching again is not that: the hydrator replay re-asks every ACTIVE
  /// checkout for its whole `tree:full`, so routing a tap through it would
  /// answer one stalled workspace with megabytes for every workspace on
  /// screen beside it. This carries the frame
  /// that tap is actually after — the bridge recomputes each checkout's
  /// `agent:status` while serving the pull, so the reply is no older than the
  /// tap.
  ///
  /// Shares [_fetchSnapshot]'s generation stamp, so a pull already airborne is
  /// superseded rather than duplicated. The returned future completes when
  /// the pull settles or this call's own wait elapses, whichever is first —
  /// the pull itself keeps running to [MachineSession.snapshotDeadline]
  /// regardless.
  Future<void> refreshDurableState() =>
      _fetchSnapshot(wait: session.snapshotTimeout);

  /// Stamps each pull so a superseded one's reply is discarded rather than
  /// applied: a (re)establish or a second bind starts a fresh pull on the
  /// live session, and [dispose] ends them all.
  int _snapshotGen = 0;

  /// One `state.snapshot` request, under [MachineSession.snapshotDeadline].
  /// [wait] only bounds how long THIS call waits for it — a reply landing
  /// after [wait] but before the deadline is still applied, because the
  /// request behind it is still pending. That is the point of the long
  /// deadline: a caller that cannot wait moves on, but the eventual reply is
  /// not wasted.
  Future<void> _fetchSnapshot({required Duration wait}) {
    final gen = ++_snapshotGen;
    final pull = _pullSnapshot(gen);
    return _firstOf(pull, wait);
  }

  /// The pull itself. Goes through the counted [request], so a project
  /// stream's pull counts once per binding like any other RPC. Never throws:
  /// a timeout is logged and left for the next establishment, bind or
  /// [refreshDurableState] call to re-ask; any other error leaves the cache as
  /// it is.
  Future<void> _pullSnapshot(int gen) async {
    const method = 'state.snapshot';
    const params = <String, dynamic>{
      'types': ['*'],
      'exclude': _kHeavyReplayTypes,
    };
    try {
      final snap = await request(
        method,
        params: params,
        timeout: session.snapshotDeadline,
      );
      // Superseded by a fresher pull, or the transport disposed while this
      // one was in flight: leave the cache, outbound and readiness snooping
      // untouched.
      if (gen != _snapshotGen || _disposed) return;
      final frames = (snap['frames'] as List?) ?? const [];
      final fresh = <InboundMessage>[];
      for (final raw in frames) {
        if (raw is Map) {
          final m = raw.cast<String, dynamic>();
          // Snapshot-replayed frames must feed the session's readiness state
          // exactly like live frames: the bridge's replay-cache dedup can
          // suppress the live re-advert after an app kill+reopen, making this
          // pull the ONLY carrier of `agent:projects{running}`. Control-plane
          // only — a project stream's own snapshot carries no adverts.
          if (projectId == null) session._snoopControl(m);
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
    } on RpcException catch (e) {
      if (e.code != 'E_TIMEOUT') return; // Leave the cache as it is.
      session._log(
        RelayLogLevel.info,
        'state.snapshot timed out',
        fields: {
          'streamId': streamId,
          'deadlineMs': session.snapshotDeadline.inMilliseconds,
        },
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _snapshotGen++;
    failAllPending();
    clearHydrators();
    snapshotCache.clear();
    await outbound.close();
    await stateController.close();
    if (projectId == null) {
      // Control: no native stream of its own to drain.
      session._removeTransport(this);
      return;
    }
    _reopenTimer?.cancel();
    _reopenTimer = null;
    if (session._disposed) {
      // The whole session is going: no later open on it can race this
      // stream for a cap slot, and waiting on the bridge's FIN (or on a bind
      // still waiting for its first record) would let one unresponsive
      // stream hang the session's teardown.
      final stream = _peerStream;
      if (stream != null) {
        _quietly(_bindInFlight != null ? stream.reset() : stream.finish());
      }
      session._removeTransport(this);
      return;
    }
    final inFlight = _bindInFlight;
    if (inFlight != null) await inFlight.future.catchError((_) {});
    final stream = _peerStream;
    if (stream == null) {
      // Never bound, or already unbound between reopens: nothing draining
      // against the bridge's cap, so the slot is free now.
      session._removeTransport(this);
      return;
    }
    // The bridge counts this stream against its per-peer cap until it sees
    // our end AND its own half's end (§4.3 — the same reason as the terminal-
    // attachment carry-over, §4.4): freeing the slot before the records
    // drain would let the very next openProject race that and draw a
    // spurious CAP_EXCEEDED.
    final drained = Completer<void>();
    _disposeDrained = drained;
    _drainingStream = stream;
    _quietly(stream.finish());
    await drained.future;
  }
}

/// Durable frames the snapshot pull leaves out: the only unbounded ones the
/// bridge caches, each delivered by a per-checkout hydrator instead — see
/// [StreamTransport.refreshSnapshot].
const _kHeavyReplayTypes = <String>['tree:full'];

/// Decodes [record] as UTF-8, or null on any failure — never throws.
String? _safeUtf8Decode(Uint8List record) {
  try {
    return utf8.decode(record);
  } catch (_) {
    return null;
  }
}

/// What every purpose-specific stream exchange shares: a slot from [_slots],
/// held until the stream's records drain once a stream exists (the bridge
/// counts the stream against its cap until it sees the end, so freeing the
/// slot early would let the next open draw a spurious `CAP_EXCEEDED`), and the
/// lifecycle tap every open/refusal/reset/end reports through.
abstract class _StreamExchange {
  _StreamExchange(this.transport, this._slots, this._kind, this._tapId);

  final StreamTransport transport;
  final _StreamSlots _slots;
  final String _kind;
  final String _tapId;
  MachineSession get session => transport.session;

  bool _slotTaken = false;
  bool _ended = false;
  bool _recordsDone = false;
  PeerStream? _stream;

  void _releaseSlot() {
    if (!_slotTaken) return;
    _slotTaken = false;
    _slots.release();
  }

  void _releaseSlotIfDrained() {
    if (_stream == null || _recordsDone) _releaseSlot();
  }

  void _tap(String reason, [Map<String, Object?>? detail]) =>
      session._tapLifecycle(_kind, _tapId, reason, detail: detail);

  /// Every Dart error path resets explicitly: a dropped send half FINs, which
  /// the bridge would read as a clean end.
  void _reset(PeerStream stream) {
    _tap('stream-reset');
    _quietly(stream.reset());
  }

  Future<void> _resetAwait(PeerStream stream) {
    _tap('stream-reset');
    return _quietlyAwait(stream.reset());
  }

  /// The in-band refusal a first record may carry; FINs our half when it is
  /// one, since the bridge has already FINed its own.
  StreamRefused? _refusal(PeerStream stream, Uint8List record) {
    final refusal = StreamRefused.tryDecode(record);
    if (refusal != null) {
      _tap('stream-refused', {'code': refusal.code.wireValue});
      _quietly(stream.finish());
    }
    return refusal;
  }
}

Uint8List _jsonRecord(Map<String, dynamic> message) =>
    Uint8List.fromList(utf8.encode(jsonEncode(message)));

/// A terminal attachment riding its own native QUIC stream. Opens
/// asynchronously and never throws: every failure — including the open
/// itself — ends [done] with a [TerminalAttachmentFailed] instead (carry-over
/// 4), so a bridge that briefly cannot serve one attachment never surfaces
/// through [PeerLink.failureStream] or the connection supervisor.
class _StreamTerminalAttachment extends _StreamExchange
    implements TerminalAttachment {
  _StreamTerminalAttachment({
    required StreamTransport transport,
    required this.requestId,
    required this.checkoutId,
    required Map<String, dynamic> subscribe,
  }) : _subscribe = subscribe,
       super(transport, transport.session._terminalSlots, 'terminal', requestId);

  @override
  final String requestId;
  @override
  final String checkoutId;
  final Map<String, dynamic> _subscribe;

  @override
  bool get isStream => true;

  final _messages = StreamController<Map<String, dynamic>>();
  final _doneCompleter = Completer<TerminalAttachmentEnd>();

  // Set by close(): before the stream exists yet, or while its open is still
  // in flight, there is nothing to finish() — only a slot and (once opened) a
  // stream to reset.
  bool _closeRequested = false;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<TerminalAttachmentEnd> get done => _doneCompleter.future;

  void _end(TerminalAttachmentEnd end) {
    if (_ended) return;
    _ended = true;
    _releaseSlotIfDrained();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete(end);
    unawaited(_messages.close());
  }

  Future<void> _start() async {
    if (!_slots.tryTake()) {
      _end(const TerminalAttachmentFailed('CAP_EXCEEDED'));
      return;
    }
    _slotTaken = true;
    final projectId = transport.projectId;
    if (projectId == null) {
      _end(const TerminalAttachmentFailed('NO_PROJECT'));
      return;
    }
    if (!transport.isProjectBound) {
      _end(const TerminalAttachmentFailed('NO_PROJECT_STREAM'));
      return;
    }
    if (_closeRequested) {
      // close() landed before the open was even attempted.
      _end(const TerminalAttachmentClosedLocally());
      return;
    }
    PeerStream stream;
    try {
      stream = await session.relay.openStream(
        TerminalStreamOpen(
          projectId: projectId,
          requestId: requestId,
          checkoutId: checkoutId,
        ),
        maxRecordBytes: kStreamTerminalBridgeRecordMaxBytes,
        maxQueuedBytes: kTerminalAttachmentMaxQueuedBytes,
      );
    } catch (e) {
      // Carry-over 4: never rethrown, never reported to failureStream or the
      // connection supervisor — this attachment's open failure is purely
      // local (e.g. PeerConnectionFailure(terminal: true) from a closed link).
      _end(TerminalAttachmentFailed('STREAM_OPEN_FAILED', e));
      return;
    }
    _tap('stream-open');
    _stream = stream;
    if (_closeRequested) {
      // close() landed while the open was in flight: reset rather than
      // finish() a stream whose subscribe was never sent. The bridge counts
      // this stream against its cap until its own half ends, so the slot is
      // held until the records drain (carry-over 1), never freed here.
      _reset(stream);
      _end(const TerminalAttachmentClosedLocally());
      await _readRecords(stream);
      return;
    }
    PeerSendOutcome? outcome;
    Object? sendError;
    try {
      outcome = await stream.send(
        _jsonRecord(_subscribe),
      );
    } catch (e) {
      sendError = e;
    }
    if (outcome != PeerSendOutcome.accepted) {
      // Same carry-over 1 as a close() during the open: held until drained.
      _reset(stream);
      _end(TerminalAttachmentFailed('SEND_FAILED', sendError));
      await _readRecords(stream);
      return;
    }
    await _readRecords(stream);
  }

  Future<void> _readRecords(PeerStream stream) async {
    var first = true;
    try {
      await for (final record in stream.records) {
        // Ended already (a mid-stream close(), a refusal, or an invalid
        // record) — keep draining without delivering so the native side's
        // completion still runs its course (step 7).
        if (_ended) continue;
        if (first) {
          first = false;
          final refusal = _refusal(stream, record);
          if (refusal != null) {
            _end(TerminalAttachmentRefused(refusal));
            continue;
          }
        }
        final decoded = _tryDecodeJsonRecord(_safeUtf8Decode(record));
        if (decoded == null) {
          _reset(stream);
          _end(const TerminalAttachmentFailed('INVALID_RECORD'));
          continue;
        }
        if (!_messages.isClosed) _messages.add(decoded);
      }
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    // The bridge's half ended (FIN or reset — Dart cannot tell them apart in
    // record mode, so this side always reports the end it can prove).
    _tap('stream-ended', {'end': 'fin'});
    // Always finish our own send half here (a no-op if already finished),
    // and release the slot now that nothing more is coming.
    await _quietlyAwait(stream.finish());
    _recordsDone = true;
    _end(const TerminalAttachmentPeerEnded());
    _releaseSlot();
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_ended) return;
    final stream = _stream;
    if (stream == null) return; // Still opening; nothing to send onto yet.
    try {
      final outcome = await stream.send(
        _jsonRecord(message),
      );
      if (outcome != PeerSendOutcome.accepted) {
        _quietly(stream.reset());
      }
    } catch (_) {
      // Never throws — mirrors the socket path's fire-and-forget send.
    }
  }

  @override
  Future<void> close() async {
    if (_closeRequested || _ended) return;
    _closeRequested = true;
    final stream = _stream;
    if (stream == null) {
      // Open hasn't resolved yet; _start() checks _closeRequested at both of
      // its points before a stream exists.
      return;
    }
    _end(const TerminalAttachmentClosedLocally());
    await _quietlyAwait(stream.finish());
  }
}

/// Fire-and-forget for a stream end whose failure means the link is already
/// gone: an unawaited rejection would otherwise surface as an uncaught error.
void _quietly(Future<void> future) =>
    unawaited(future.catchError((Object _) {}));

/// Decodes one record as a JSON object, or null on any failure (bad UTF-8,
/// bad JSON, not an object) — never throws.
Map<String, dynamic>? _tryDecodeJsonRecord(String? text) {
  if (text == null) return null;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// One HTTP tunnel request/response pair riding its own native QUIC stream.
/// Opens asynchronously and never throws: every failure — including the open
/// itself — ends [head]/[body] with a [TunnelExchangeFailure] instead (the
/// same carry-over 4 as [_StreamTerminalAttachment]), so a bridge that briefly
/// cannot serve one preview request never surfaces through
/// [PeerLink.failureStream] or the connection supervisor.
class _StreamTunnelHttpExchange extends _StreamExchange
    implements TunnelHttpExchange {
  _StreamTunnelHttpExchange({
    required StreamTransport transport,
    required this.requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required int bodyLength,
    required Stream<List<int>>? body,
  }) : _checkoutId = checkoutId,
       _head = head,
       _bodyLength = bodyLength,
       _bodySource = body,
       super(transport, transport.session._tunnelSlots, 'tunnel-http', requestId);

  @override
  final String requestId;
  final String _checkoutId;
  final Map<String, dynamic> _head;
  final int _bodyLength;
  final Stream<List<int>>? _bodySource;

  final _headCompleter = Completer<TunnelHttpHead>();
  final _bodyController = StreamController<Uint8List>();

  // Set by [_fail] alone: a clean response end also sets [_ended], but the
  // request body must keep flowing after that, since the bridge still owes
  // the origin every declared byte.
  bool _failed = false;
  bool _cancelRequested = false;
  bool _headDelivered = false;

  @override
  Future<TunnelHttpHead> get head => _headCompleter.future;

  @override
  Stream<Uint8List> get body => _bodyController.stream;

  void _fail(TunnelExchangeFailure failure) {
    if (_ended) return;
    _ended = true;
    _failed = true;
    if (!_headCompleter.isCompleted) _headCompleter.completeError(failure);
    if (!_bodyController.isClosed) {
      _bodyController.addError(failure);
      unawaited(_bodyController.close());
    }
    _releaseSlotIfDrained();
  }

  Future<void> _start() async {
    // Resolve the project BEFORE the slot wait (stage-A-A3-contract.md
    // §4.3): an unbound stream should fail at once rather than sit in the
    // FIFO behind opens that could actually succeed. Same code either way a
    // project stream is missing — control transport (no project) or an
    // unbound project transport.
    final projectId = transport.projectId;
    if (projectId == null || !transport.isProjectBound) {
      _fail(const TunnelExchangeFailure('STREAM_UNBOUND'));
      return;
    }
    final slot = _slots.acquire(this);
    final gotSlot = slot is bool ? slot : await slot;
    if (!gotSlot) {
      _fail(
        TunnelExchangeFailure(_cancelRequested ? 'CANCELLED' : 'TRANSPORT_CLOSED'),
      );
      return;
    }
    _slotTaken = true;
    if (_cancelRequested) {
      _fail(const TunnelExchangeFailure('CANCELLED'));
      return;
    }
    PeerStream stream;
    try {
      stream = await session.relay.openStream(
        TunnelHttpStreamOpen(projectId: projectId, requestId: requestId),
        maxRecordBytes: kStreamTunnelRecordMaxBytes,
        maxQueuedBytes: kTunnelStreamMaxQueuedBytes,
        rawAfterRecords: 1,
      );
    } catch (e) {
      _fail(TunnelExchangeFailure('STREAM_OPEN_FAILED', error: e));
      return;
    }
    _tap('stream-open');
    _stream = stream;
    // "Opening: reset once open" (stage-A-A3-contract.md §4.1 cancel()) — a
    // clean CANCELLED, since nothing was ever written for the bridge to
    // answer.
    if (_cancelRequested) {
      _reset(stream);
      _fail(const TunnelExchangeFailure('CANCELLED'));
      // The bridge counts this stream against its cap until it sees the
      // reset and answers it; freeing the slot before our records end would
      // let the next open race that and draw a spurious CAP_EXCEEDED.
      await _readRecords(stream);
      return;
    }
    final headJson = <String, dynamic>{
      ..._head,
      'bodyLength': _bodyLength,
      'checkoutId': _checkoutId,
    };
    // Records are read while the body is still going out: a bridge refusal
    // FINs and then stops our send half, so a body pumped to completion
    // first would turn every refusal of a large upload into SEND_FAILED.
    final pumpOk = Completer<bool>();
    final reading = _readRecords(stream, pumpOk: pumpOk.future);
    PeerSendOutcome? headOutcome;
    Object? headError;
    try {
      headOutcome = await stream.send(
        _jsonRecord(headJson),
      );
    } catch (e) {
      headError = e;
    }
    // "Open: stop the upload, reset() the send half, keep draining records" —
    // cancel() has already reset; just fall through to draining rather than
    // reporting this send's own outcome as a failure.
    var pumpOutcome = _TunnelBodyPumpOutcome.ok;
    if (!_cancelRequested && !_failed) {
      if (headOutcome != PeerSendOutcome.accepted) {
        _reset(stream);
        _fail(TunnelExchangeFailure('SEND_FAILED', error: headError));
        pumpOk.complete(false);
        await reading;
        return;
      }
      pumpOutcome = await _pumpBody(stream);
      if (!_cancelRequested &&
          !_failed &&
          pumpOutcome != _TunnelBodyPumpOutcome.ok) {
        _reset(stream);
        _fail(
          TunnelExchangeFailure(
            pumpOutcome == _TunnelBodyPumpOutcome.sendFailed
                ? 'SEND_FAILED'
                : 'PROTOCOL',
          ),
        );
      }
    }
    pumpOk.complete(pumpOutcome == _TunnelBodyPumpOutcome.ok);
    await reading;
  }

  /// Writes [_bodyLength] raw bytes from [_bodySource] in
  /// [kTunnelBodySliceBytes] pieces. `StreamIterator` is what pauses the
  /// source between pieces — it buffers nothing beyond the value already
  /// delivered, so the source stays paused for the whole `sendRaw` await.
  Future<_TunnelBodyPumpOutcome> _pumpBody(PeerStream stream) async {
    final source = _bodySource;
    if (source == null) return _TunnelBodyPumpOutcome.ok;
    var sent = 0;
    final iterator = StreamIterator<List<int>>(source);
    try {
      while (await iterator.moveNext()) {
        if (_cancelRequested || _failed) break;
        final chunk = iterator.current;
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        var offset = 0;
        while (offset < bytes.length) {
          if (_cancelRequested || _failed) break;
          final end = min(offset + kTunnelBodySliceBytes, bytes.length);
          final slice = Uint8List.sublistView(bytes, offset, end);
          sent += slice.length;
          if (sent > _bodyLength) return _TunnelBodyPumpOutcome.protocol;
          final outcome = await stream.sendRaw(slice);
          if (outcome != PeerSendOutcome.accepted) {
            return _TunnelBodyPumpOutcome.sendFailed;
          }
          offset = end;
        }
      }
    } catch (_) {
      return _TunnelBodyPumpOutcome.sendFailed;
    } finally {
      unawaited(iterator.cancel());
    }
    // Settled elsewhere; this pump outcome decides nothing further.
    if (_cancelRequested || _failed) return _TunnelBodyPumpOutcome.ok;
    return sent == _bodyLength
        ? _TunnelBodyPumpOutcome.ok
        : _TunnelBodyPumpOutcome.protocol;
  }

  Future<void> _readRecords(
    PeerStream stream, {
    Future<bool>? pumpOk,
  }) async {
    var first = true;
    var reset = false;
    try {
      await for (final record in stream.records) {
        if (_ended) continue; // Keep draining without delivering.
        if (first) {
          first = false;
          final refusal = _refusal(stream, record);
          if (refusal != null) {
            _fail(TunnelExchangeFailure('REFUSED', refusal: refusal));
            continue;
          }
          final json = _tryDecodeJsonRecord(
            utf8.decode(record, allowMalformed: true),
          );
          if (json == null ||
              json['type'] != 'tunnel:http-head' ||
              json['requestId'] != requestId) {
            _reset(stream);
            _fail(const TunnelExchangeFailure('PROTOCOL'));
            continue;
          }
          final rawHeaders = json['headers'];
          final headers = <String, String>{
            if (rawHeaders is Map)
              for (final e in rawHeaders.entries)
                e.key.toString(): e.value.toString(),
          };
          final rawCookies = json['setCookies'];
          final setCookies = <String>[
            if (rawCookies is List) for (final c in rawCookies) c.toString(),
          ];
          _headDelivered = true;
          if (!_headCompleter.isCompleted) {
            _headCompleter.complete(
              TunnelHttpHead(
                status: (json['status'] as num?)?.toInt() ?? 0,
                headers: headers,
                setCookies: setCookies,
              ),
            );
          }
          continue;
        }
        // Raw response bytes, delivered exactly as the bridge wrote them.
        if (!_bodyController.isClosed) _bodyController.add(record);
      }
    } on PeerStreamReset {
      reset = true;
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    // The one exchange where the raw phase actually tells FIN from reset —
    // every other stream kind stays record-mode and reports 'fin'
    // unconditionally.
    _tap('stream-ended', {'end': reset ? 'reset' : 'fin'});
    // Every branch below settles the body before the slot goes: a clean close
    // here would let a reset read as a complete response.
    _recordsDone = true;
    if (!_ended) {
      if (_cancelRequested) {
        // The bridge's half ends because our reset told it to; reporting that
        // as STREAM_ENDED or TRUNCATED would blame the peer for our cancel.
        _reset(stream);
        _fail(const TunnelExchangeFailure('CANCELLED'));
      } else if (reset) {
        _reset(stream);
        _fail(
          TunnelExchangeFailure(_headDelivered ? 'TRUNCATED' : 'STREAM_ENDED'),
        );
      } else if (!_headDelivered) {
        _reset(stream);
        _fail(const TunnelExchangeFailure('STREAM_ENDED'));
      } else {
        // A clean response FIN: the send half only closes now, because it
        // stays open for the whole response so that a reset remains the
        // cancel (a reset after finish() is not reliably delivered).
        // An origin may answer before it has read the whole request body,
        // so the response settles now and the send half waits on the pump.
        _ended = true;
        if (!_bodyController.isClosed) unawaited(_bodyController.close());
        if (pumpOk != null && await pumpOk) {
          await _quietlyAwait(stream.finish());
        } else {
          await _resetAwait(stream);
        }
      }
    }
    _releaseSlot();
  }

  @override
  void cancel() {
    if (_cancelRequested || _ended) return;
    _cancelRequested = true;
    // A caller that cancels has stopped caring about the head, so the
    // CANCELLED it will now carry must not surface as an unhandled error.
    _headCompleter.future.ignore();
    _slots.cancelWait(this);
    final stream = _stream;
    if (stream == null) return; // _start() checks _cancelRequested once open resolves.
    _reset(stream);
  }
}

/// Whether the app's own request body reached `bodyLength` byte-for-byte —
/// what decides `finish()` vs `reset()` once the response side has ended,
/// since the send half stays open until then.
enum _TunnelBodyPumpOutcome { ok, protocol, sendFailed }

/// Awaited version of [_quietly] for a call whose completion this side must
/// wait on before proceeding (releasing the slot only once it settles).
Future<void> _quietlyAwait(Future<void> future) async {
  try {
    await future;
  } catch (_) {
    // The stream, or the connection under it, may already be gone.
  }
}

/// One browser-side WebSocket's tunnel, riding its own native QUIC stream for
/// the socket's lifetime. Same carry-over-4 shape as
/// [_StreamTunnelHttpExchange]: every failure ends [done] locally rather than
/// surfacing through [PeerLink.failureStream].
class _StreamTunnelWsChannel extends _StreamExchange
    implements TunnelWsChannel {
  _StreamTunnelWsChannel({
    required StreamTransport transport,
    required this.tunnelId,
    required String checkoutId,
    required Map<String, dynamic> open,
  }) : _checkoutId = checkoutId,
       _open = open,
       super(transport, transport.session._tunnelSlots, 'tunnel-ws', tunnelId);

  @override
  final String tunnelId;
  final String _checkoutId;
  final Map<String, dynamic> _open;

  final _frames = StreamController<TunnelWsFrame>();
  final _doneCompleter = Completer<TunnelWsEnd>();
  // Resolves once the open sequence settles: the live stream, or null if it
  // never got one (refused before send, cancelled, disposed while waiting).
  final _streamReady = Completer<PeerStream?>();

  bool _abortRequested = false;
  bool _closeRequested = false;
  bool _sawCloseRecord = false;
  int? _peerCloseCode;
  String? _peerCloseReason;

  /// Serializes every [send]/[close] call in arrival order, including ones
  /// made before the stream opens (stage-A-A3-contract.md §4.1).
  Future<bool> _sendChain = Future<bool>.value(true);

  @override
  Stream<TunnelWsFrame> get frames => _frames.stream;

  @override
  Future<TunnelWsEnd> get done => _doneCompleter.future;

  void _end(TunnelWsEnd end) {
    if (_ended) return;
    _ended = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete(end);
    unawaited(_frames.close());
    _releaseSlotIfDrained();
  }

  Future<void> _start() async {
    // Resolve the project BEFORE the slot wait — see the matching comment on
    // _StreamTunnelHttpExchange._start().
    final projectId = transport.projectId;
    if (projectId == null || !transport.isProjectBound) {
      _streamReady.complete(null);
      _end(const TunnelWsFailed(TunnelExchangeFailure('STREAM_UNBOUND')));
      return;
    }
    final slot = _slots.acquire(this);
    final gotSlot = slot is bool ? slot : await slot;
    if (!gotSlot) {
      _streamReady.complete(null);
      _end(
        TunnelWsFailed(
          TunnelExchangeFailure(_abortRequested ? 'CANCELLED' : 'TRANSPORT_CLOSED'),
        ),
      );
      return;
    }
    _slotTaken = true;
    if (_abortRequested) {
      _streamReady.complete(null);
      _end(TunnelWsFailed(const TunnelExchangeFailure('CANCELLED')));
      return;
    }
    PeerStream stream;
    try {
      stream = await session.relay.openStream(
        TunnelWsStreamOpen(projectId: projectId, wsId: tunnelId),
        maxRecordBytes: kStreamTunnelRecordMaxBytes,
        maxQueuedBytes: kTunnelStreamMaxQueuedBytes,
      );
    } catch (e) {
      _streamReady.complete(null);
      _end(TunnelWsFailed(TunnelExchangeFailure('STREAM_OPEN_FAILED', error: e)));
      return;
    }
    _tap('stream-open');
    _stream = stream;
    if (_abortRequested) {
      _reset(stream);
      _streamReady.complete(null);
      _end(TunnelWsFailed(const TunnelExchangeFailure('CANCELLED')));
      // Held until records end, as in _StreamTunnelHttpExchange._start().
      await _readRecords(stream);
      return;
    }
    final openJson = <String, dynamic>{
      ..._open,
      'tunnelId': tunnelId,
      'checkoutId': _checkoutId,
    };
    PeerSendOutcome? outcome;
    Object? sendError;
    try {
      outcome = await stream.send(
        _jsonRecord(openJson),
      );
    } catch (e) {
      sendError = e;
    }
    if (!_abortRequested && outcome != PeerSendOutcome.accepted) {
      _reset(stream);
      _streamReady.complete(null);
      _end(TunnelWsFailed(TunnelExchangeFailure('SEND_FAILED', error: sendError)));
      await _readRecords(stream);
      return;
    }
    _streamReady.complete(stream);
    await _readRecords(stream);
  }

  Future<void> _readRecords(PeerStream stream) async {
    var first = true;
    try {
      await for (final record in stream.records) {
        if (_ended) continue;
        if (first) {
          first = false;
          final refusal = _refusal(stream, record);
          if (refusal != null) {
            _end(TunnelWsFailed(TunnelExchangeFailure('REFUSED', refusal: refusal)));
            continue;
          }
        }
        final decoded = decodeTunnelRecord(record);
        if (decoded is TunnelDataRecord) {
          if (decoded.tag != kTunnelRecordTagWsText &&
              decoded.tag != kTunnelRecordTagWsBinary) {
            _reset(stream);
            _end(TunnelWsFailed(const TunnelExchangeFailure('PROTOCOL')));
            continue;
          }
          if (!_frames.isClosed) {
            _frames.add(
              TunnelWsFrame(
                binary: decoded.tag == kTunnelRecordTagWsBinary,
                bytes: decoded.payload,
              ),
            );
          }
          continue;
        }
        final json = decoded is TunnelJsonRecord
            ? _tryDecodeJsonRecord(decoded.text)
            : null;
        if (json != null && json['type'] == 'tunnel:ws-close') {
          _sawCloseRecord = true;
          _peerCloseCode = (json['code'] as num?)?.toInt();
          _peerCloseReason = json['reason'] as String?;
          // Keep reading only to observe FIN; any further record is a
          // breach.
          continue;
        }
        _reset(stream);
        _end(TunnelWsFailed(const TunnelExchangeFailure('PROTOCOL')));
      }
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    // Tagged records throughout, so a reset
    // closes `records` the same way a FIN does — nothing here can tell them
    // apart, unlike the tunnel-http raw phase.
    _tap('stream-ended', {'end': 'fin'});
    await _quietlyAwait(stream.finish());
    _recordsDone = true;
    if (!_ended) {
      _end(TunnelWsClosedByPeer(_peerCloseCode, _sawCloseRecord ? _peerCloseReason : null));
    } else {
      _releaseSlot();
    }
  }

  Future<bool> _doSend(TunnelWsFrame frame) async {
    if (_ended) return false;
    final stream = await _streamReady.future;
    if (stream == null || _ended) return false;
    if (frame.bytes.length > kStreamTunnelDataMaxBytes) {
      _reset(stream);
      return false;
    }
    final tag = frame.binary ? kTunnelRecordTagWsBinary : kTunnelRecordTagWsText;
    PeerSendOutcome? outcome;
    try {
      outcome = await stream.send(encodeTunnelDataRecord(tag, frame.bytes));
    } catch (_) {
      // Falls through to the non-accepted branch below.
    }
    if (outcome != PeerSendOutcome.accepted) {
      _reset(stream);
      return false;
    }
    return true;
  }

  @override
  Future<bool> send(TunnelWsFrame frame) {
    final result = _sendChain.then((_) => _doSend(frame));
    _sendChain = result;
    return result;
  }

  Future<bool> _doClose(int? code, String? reason) async {
    final stream = await _streamReady.future;
    if (stream == null || _ended) return false;
    final msg = <String, dynamic>{
      'type': 'tunnel:ws-close',
      'tunnelId': tunnelId,
      'checkoutId': _checkoutId,
      if (code != null) 'code': code,
      if (reason != null) 'reason': reason,
    };
    try {
      await stream.send(_jsonRecord(msg));
    } catch (_) {
      // The finish below still runs; a lost close record just means the
      // peer sees a plain FIN.
    }
    _quietly(stream.finish());
    return true;
  }

  @override
  void close({int? code, String? reason}) {
    if (_closeRequested || _abortRequested || _ended) return;
    _closeRequested = true;
    final result = _sendChain.then((_) => _doClose(code, reason));
    _sendChain = result;
  }

  @override
  void abort() {
    if (_abortRequested || _ended) return;
    _abortRequested = true;
    _slots.cancelWait(this);
    final stream = _stream;
    if (stream != null) {
      _reset(stream);
    }
  }
}

/// One file upload riding its own native QUIC stream: the open frame, then
/// [_bytes] raw with no framing, then FIN — the bridge answers with one
/// record (a refusal or the result) and its own FIN. Same carry-over-4 shape
/// as [_StreamTunnelHttpExchange]: every failure ends [result] locally.
class _StreamUploadExchange extends _StreamExchange implements UploadExchange {
  _StreamUploadExchange({
    required StreamTransport transport,
    required this.requestId,
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    required String? mimeType,
    required void Function(int sent, int total)? onProgress,
  }) : _projectId = projectId,
       _checkoutId = checkoutId,
       _fileName = fileName,
       _bytes = bytes,
       _mimeType = mimeType,
       _onProgress = onProgress,
       super(transport, transport.session._uploadSlots, 'upload', requestId) {
    // [UploadExchange.result] promises never to surface as an unhandled
    // error: a caller that fires an upload and walks away must not crash the
    // zone when the stream later ends. Listeners still see the failure.
    _resultCompleter.future.ignore();
  }

  @override
  final String requestId;
  final String _projectId;
  final String _checkoutId;
  final String _fileName;
  final Uint8List _bytes;
  final String? _mimeType;
  final void Function(int sent, int total)? _onProgress;

  final _resultCompleter = Completer<UploadStreamResult>();
  bool _cancelRequested = false;
  Timer? _resultTimer;

  @override
  Future<UploadStreamResult> get result => _resultCompleter.future;

  /// Settles [result] with an [UploadStreamResult] or an [UploadFailure].
  void _settle(Object outcome) {
    if (_ended) return;
    _ended = true;
    _resultTimer?.cancel();
    if (outcome is UploadStreamResult) {
      _resultCompleter.complete(outcome);
    } else {
      _resultCompleter.completeError(outcome);
    }
    _releaseSlotIfDrained();
  }

  Future<void> _start() async {
    final slot = _slots.acquire(this);
    final gotSlot = slot is bool ? slot : await slot;
    if (!gotSlot) {
      _settle(UploadFailure(_cancelRequested ? 'CANCELLED' : 'TRANSPORT_CLOSED'));
      return;
    }
    _slotTaken = true;
    if (_cancelRequested) {
      _settle(const UploadFailure('CANCELLED'));
      return;
    }
    PeerStream stream;
    try {
      stream = await session.relay.openStream(
        UploadStreamOpen(
          projectId: _projectId,
          checkoutId: _checkoutId,
          requestId: requestId,
          fileName: _fileName,
          size: _bytes.length,
          mimeType: _mimeType,
        ),
        maxRecordBytes: kStreamUploadBridgeRecordMaxBytes,
        maxQueuedBytes: kUploadStreamMaxQueuedBytes,
      );
    } catch (e) {
      _settle(UploadFailure('STREAM_OPEN_FAILED', message: '$e'));
      return;
    }
    _tap('stream-open');
    _stream = stream;
    if (_cancelRequested) {
      _reset(stream);
      _settle(const UploadFailure('CANCELLED'));
      await _readRecords(stream);
      return;
    }
    unawaited(_readRecords(stream));
    var sent = 0;
    for (; sent < _bytes.length; sent += kUploadStreamSliceBytes) {
      if (_cancelRequested || _ended) break;
      final end = min(sent + kUploadStreamSliceBytes, _bytes.length);
      final slice = Uint8List.sublistView(_bytes, sent, end);
      PeerSendOutcome outcome;
      try {
        outcome = await stream.sendRaw(slice);
      } catch (e) {
        if (_cancelRequested) return; // cancel() already reset.
        _reset(stream);
        _settle(UploadFailure('SEND_FAILED', message: '$e'));
        return;
      }
      if (_cancelRequested || _ended) break;
      if (outcome != PeerSendOutcome.accepted) {
        _reset(stream);
        _settle(const UploadFailure('SEND_FAILED'));
        return;
      }
      _onProgress?.call(end, _bytes.length);
    }
    if (_cancelRequested) return;
    if (_ended) {
      // Settled by the bridge's result or refusal. A send half dropped
      // without an explicit end FINs, which would read as a short but
      // complete body, so an unfinished write is always reset.
      if (sent < _bytes.length) {
        _reset(stream);
      } else {
        _quietly(stream.finish());
      }
      return;
    }
    await _quietlyAwait(stream.finish());
    _resultTimer = Timer(kUploadResultTimeout, () {
      if (!_ended) {
        _reset(stream);
        _settle(const UploadFailure('TIMEOUT'));
      }
    });
  }

  Future<void> _readRecords(PeerStream stream) async {
    var first = true;
    try {
      await for (final record in stream.records) {
        if (!first || _ended) continue; // Only the first record ever matters.
        first = false;
        final refusal = _refusal(stream, record);
        if (refusal != null) {
          _settle(UploadFailure('REFUSED', refusedCode: refusal.code, message: refusal.message));
          continue;
        }
        final json = _tryDecodeJsonRecord(utf8.decode(record, allowMalformed: true));
        final parsed = json == null
            ? null
            : UploadStreamResult.tryParse(json, requestId: requestId);
        if (parsed == null) {
          _reset(stream);
          _settle(const UploadFailure('PROTOCOL'));
          continue;
        }
        _settle(parsed);
      }
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    // Read-side stays record-mode for an upload (its raw phase is send-only),
    // so a reset reads the same as a FIN here, as with terminal and tunnel-ws.
    _tap('stream-ended', {'end': 'fin'});
    _recordsDone = true;
    if (!_ended) {
      _settle(UploadFailure(_cancelRequested ? 'CANCELLED' : 'STREAM_ENDED'));
    } else {
      _releaseSlot();
    }
  }

  @override
  void cancel() {
    if (_cancelRequested || _ended) return;
    _cancelRequested = true;
    _slots.cancelWait(this);
    final stream = _stream;
    if (stream == null) return; // _start() checks _cancelRequested once open resolves.
    _reset(stream);
    // The result settles now; the slot stays held until the bridge's half
    // ends, since it counts the stream against its cap until then.
    _settle(const UploadFailure('CANCELLED'));
  }
}
