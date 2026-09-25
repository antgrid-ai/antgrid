import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'agent_transport.dart';
import 'buffered_agent_transport.dart';
import 'flow.dart';
import 'frag.dart';
import 'frame.dart';
import 'models/stream_envelope.dart';
import 'models/stream_open.dart';
import 'relay_service.dart';
import 'peer_link.dart';
import 'send_scheduler.dart';
import 'terminal_attachment.dart';
import 'tunnel_stream.dart';

/// Liveness constants; mirror `bridge/src/relay-client.ts`.
const int kPingSilenceSeconds = 20;
const int kMaxMissedPongs = 2;
const int _kConsecutiveTimeoutsToClose = 3;

/// Reopen backoff for a project stream that ended while its transport is
/// still wanted (Stage A A4): the first retry follows almost immediately,
/// later ones back off toward [kProjectStreamReopenMaxBackoff] rather than
/// hammering a bridge that is itself restarting.
const Duration kProjectStreamReopenInitialBackoff = Duration(seconds: 1);
const Duration kProjectStreamReopenMaxBackoff = Duration(seconds: 30);

/// Local queue cap handed to [MultiStreamPeerLink.openStream] for a project
/// stream — the same ceiling the per-session scheduler enforced for a
/// project's traffic before A4 (`MAX_SEND_QUEUE_BYTES`, mirrored from
/// `bridge/src/project-streams.ts`).
const int kProjectStreamMaxQueuedBytes = 67108864;

/// Drives ONE hello attempt-cycle over a [MachineSession]'s socket, completing
/// only once the bridge's `established` arrives. The app implements this
/// wrapping `ConnectionHandshake`; the package stays Flutter-free. Each
/// [perform] must run a FRESH attempt (new `attemptId`).
abstract interface class SessionHandshaker {
  /// Runs one hello to `established`. True once it lands, false on timeout /
  /// abort / a link that will not accept the hello.
  Future<bool> perform();

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

/// Outcome of reading a project stream's first record — see
/// [StreamTransport._bindOverStream].
enum _BindOutcome { bound, notReadyRetry }

/// One phone↔machine session multiplexed over a single [PeerLink] socket for
/// its control plane, with each project riding its own native QUIC stream
/// (Stage A A4) when the link supports one ([MultiStreamPeerLink]).
/// QUIC/TLS between the two lease-authorized endpoints is the confidentiality
/// layer; this class owns the hello/close driver, the control-plane fragment
/// reassembler, liveness, and project-stream lifecycle. Session frames
/// (`session:hello`, `established`, `ping`, `pong`, `credit`) and the
/// control-plane `{s, m}` envelope (`s` absent/"0") ride the plain [relay]
/// socket; a project's traffic is bare `AbMessage` JSON on its own stream,
/// with no envelope.
class MachineSession {
  final PeerLink relay;

  /// The bare machine deviceUuid — the routing `to` for every outbound frame
  /// and the fragment-id namespace.
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

  /// Base wait for a `state.snapshot` pull. Each retry doubles it — see
  /// [StreamTransport.refreshSnapshot] for why a pull is retried at all.
  final Duration snapshotTimeout;

  /// Silence after which liveness sends a `ping`, and the period the
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
    RelayLogger? logger,
  }) : _handshaker = handshaker,
       _logger = logger,
       _channelWindowBytes = channelWindowBytes ?? kChannelWindowBytes,
       _socketInflightBytes = socketInflightBytes ?? kSocketInflightBytes {
    // [ready] is observation-optional: failReady/dispose may completeError
    // before any awaiter attaches (see the getter doc). ignore() pre-registers
    // a swallowing listener so that never trips the unhandled-error zone hook;
    // every real `await ready` still receives the error.
    _readyCompleter.future.ignore();
    _armEstablishedReady();
  }

  _SessionGeneration? _generation;
  int _epochCounter = 0;

  /// `kControlStreamId` -> the session-stream transport, everything else ->
  /// a project's transport. Unified so disposal (`removeStream`) and the
  /// per-(re)establishment sweep need no special case for the control entry.
  final Map<String, StreamTransport> _streams = {};

  StreamSubscription<IncomingPeerFrame>? _msgSub;
  StreamSubscription<PeerLinkState>? _stateSub;
  Timer? _fragSweep;
  Timer? _livenessTimer;

  bool _disposed = false;
  bool _established = false;
  bool _handshakeInFlight = false;
  int _missedPongs = 0;
  int _consecutiveTimeouts = 0;
  int _fragCounter = 0;
  DateTime _lastRecv = DateTime.now();

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
  final _fragAborts = StreamController<FragHint>.broadcast();
  final _fragSendErrors = StreamController<FragSendError>.broadcast();
  final _projectStreamEvents = StreamController<ProjectStreamEvent>.broadcast();

  /// Frame-payload bytes allowed in flight per channel and across the socket
  /// before the agent must credit them.
  final int _channelWindowBytes;
  final int _socketInflightBytes;

  /// Cumulative payload bytes received on each channel this session, and how
  /// much of that has already been credited back to the agent. Both reset at
  /// establishment, which is the same instant the agent's send windows reset.
  final Map<String, int> _consumed = {'control': 0, 'preview': 0};
  final Map<String, int> _creditSent = {'control': 0, 'preview': 0};

  /// Every outbound session-plane frame passes through here: one drain loop,
  /// encoded at dequeue, control ahead of preview. Session frames are written
  /// directly and so overtake any backlog — but they still land behind
  /// whatever is already inside the socket's own sink, and nothing in this
  /// stack can read that sink, so the scheduler's accounting is the only bound
  /// on it there is. A project's traffic no longer passes through here at all
  /// (Stage A A4): it writes straight to that project's own native stream.
  late final SendScheduler _scheduler = SendScheduler(
    sink: _encodeAndSend,
    window: _channelWindowBytes,
    socketCap: _socketInflightBytes,
    // A gate stalled with data queued is the one failure here with no other
    // observable: the socket keeps heartbeating (liveness frames bypass the
    // queue), the peer keeps crediting, and meanwhile every frame the user
    // typed sits in this scheduler. Left unwired, the canary fired into null
    // and only the agent's side of the same stall was ever visible.
    log: (m) => _log(RelayLogLevel.warn, m),
  );

  /// Test-only seam: park the send gate, shrink its limits, release it. Not
  /// part of the supported API.
  SendScheduler get debugScheduler => _scheduler;

  /// Projects the agent has told us are dialable — from a live or
  /// snapshot-replayed `stream-ready {projectId}`, or an `agent:projects`
  /// entry with `running:true`. See [_markReady]/[_markNotReady].
  final Set<String> _readyProjects = {};

  /// Per-project waiter for the FIRST readiness signal after
  /// [openProject]/a reopen sent `project:start` — resolved by [_markReady],
  /// failed by a rejecting `control:result`.
  final Map<String, Completer<void>> _readyWaiters = {};

  late final FragReassembler _reassembler = FragReassembler(
    timeoutMs: kTransferTimeoutMs,
    globalBudgetBytes: kGlobalReassemblyBudget,
    onComplete: _dispatchDecoded,
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

  /// `true` once the peer session is established at least once and still live.
  bool get isEstablished => _established;

  /// Fires on EVERY (re)establishment. [ready] cannot serve
  /// that purpose — it is one-shot, so after the first establishment it can no
  /// longer tell a caller that the session came back.
  Stream<void> get established => _established$.stream;

  /// Fires when the agent hands this machine's session to another device
  /// (`session-takeover`). Report-only: the session is already torn down
  /// when this emits and NOTHING here re-establishes it, because two devices
  /// each reclaiming on takeover would evict each other forever.
  Stream<void> get takeoverEvents => _takeovers.stream;

  /// Fires when a hello attempt ends with no live session (the agent never
  /// answered `established`).
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

  /// `open:true` once per bind (after the bridge's first `stream-ready`
  /// record); `open:false` once per bound stream's end, or at session loss,
  /// whichever comes first.
  Stream<ProjectStreamEvent> get projectStreamEvents =>
      _projectStreamEvents.stream;

  /// The session-stream transport (the machine control plane). Created on
  /// first use and kept until disposed — a later access rebuilds it.
  StreamTransport get control {
    final existing = _streams[kControlStreamId];
    if (existing != null) return existing;
    final st = StreamTransport._control(this);
    _streams[kControlStreamId] = st;
    if (_established) unawaited(st.refreshSnapshot());
    return st;
  }

  /// The live transport for [projectId], bound or not; null if none.
  StreamTransport? projectTransport(String projectId) => _streams[projectId];

  /// Live project transports this session holds, excluding the control entry
  /// — what [kStreamMaxProjectsPerPeer] bounds.
  int get _projectStreamCount =>
      _streams.length - (_streams.containsKey(kControlStreamId) ? 1 : 0);

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
  ///  4. open the native stream ([MultiStreamPeerLink.openStream]);
  ///  5. first record: `stream-ready` → bound; `stream:refused` → a
  ///     [ProjectBindException] named by the refusal. A `NOT_READY` refusal
  ///     clears the ready mark and repeats from 2 once, then fails.
  ///
  /// A link that is not a [MultiStreamPeerLink] fails with
  /// `ProjectBindException('STREAM_UNSUPPORTED', …)`. A failed call disposes
  /// a transport it created for this call.
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

  /// Wrap [message] as a control-plane `{m}` envelope and queue it on the
  /// session stream (fragmenting past the threshold). Dropped when no keys
  /// are installed (pre-establishment / mid-reconnect) — the bridge replays
  /// durable state via `state.snapshot`.
  ///
  /// Resolves when the message's last frame has been handed to the socket or
  /// dropped, never when it has merely been copied into a buffer this layer
  /// cannot measure. A caller that cannot wait for the channel ahead of it must
  /// impose its own timeout.
  Future<void> sendOnSession(
    Map<String, dynamic> message,
    String channel,
  ) async {
    final type = message['type'] is String ? message['type'] as String : null;
    if (_generation == null) {
      // Usually benign (the bridge replays durable state on establishment),
      // but it is also where a session that never comes back shows up first,
      // and nothing else on this path observes it. Dropped rather than
      // queued: the snapshot pull on the next establishment is the reconnect
      // contract, not a backlog of messages the peer has since moved past.
      _dropped(
        'tx',
        'no-e2e-session',
        channel: channel,
        streamId: kControlStreamId,
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
      return;
    }
    final envelope = <String, dynamic>{'m': message};
    final plaintext = jsonEncode(envelope);
    final bytes = utf8ByteLength(plaintext);
    if (bytes > kMaxTransferBytes) {
      _dropped(
        'tx',
        'message-too-large',
        channel: channel,
        streamId: kControlStreamId,
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
        final id = '$machineDeviceId-$kControlStreamId-${_fragCounter++}';
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
        streamId: kControlStreamId,
        msgType: type,
        detail: {'error': '${e.runtimeType}'},
      );
      return;
    }
    final queued = [
      for (final p in frames)
        QueuedAppFrame(
          channel: channel,
          streamId: kControlStreamId,
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
        streamId: kControlStreamId,
        msgType: type,
        detail: {'frames': frames.length},
      );
      // Every send on this path is fire-and-forget, so the caller never learns
      // its message was discarded; without this the loss is visible only to a
      // netwatch tap nobody has armed.
      _log(
        RelayLogLevel.warn,
        'send queue full — message dropped',
        fields: {
          'channel': channel,
          'msgType': type,
          'frames': frames.length,
        },
      );
      return;
    }
    // A fragment set leaves in order, so the last frame's hand-off is the
    // message's.
    await queued.last.done.future;
  }

  /// Encode one queued frame under the session live at THIS moment and write
  /// it. Returns the length that reached the wire, or null if nothing did.
  Future<int?> _encodeAndSend(QueuedAppFrame f) async {
    final gen = _generation;
    if (gen == null) {
      _dropped(
        'tx',
        'no-e2e-session',
        channel: f.channel,
        streamId: f.streamId,
        msgType: f.msgType,
      );
      // Warn where [sendOnSession]'s twin is info: this frame was accepted into
      // the queue, so its sender was told it would go out and is awaiting a
      // hand-off that now never comes.
      _log(
        RelayLogLevel.warn,
        'queued frame dropped — session went down before it was sent',
        fields: {
          'channel': f.channel,
          'streamId': f.streamId,
          'msgType': f.msgType,
        },
      );
      return null;
    }
    final bytes = Uint8List.fromList(utf8.encode(f.plaintext));
    if (!relay.isDispatchAllowed) return null;
    final outcome = await relay.sendFrame(f.channel, bytes);
    if (outcome != PeerSendOutcome.accepted || !identical(gen, _generation)) {
      // A generation change between the send and its outcome means a teardown
      // or a fresh hello already retired the session this frame was written
      // for — the peer either never saw it or has since moved on.
      return null;
    }
    // Each fragment leaves on its own, so one message leaves as N frames with
    // N unrelated ids. Naming every one with the parent type is what keeps a
    // large transfer from reading as a burst of anonymous frames. After the
    // send, not before: the tap records the wire event inside sendFrame, and
    // this names the event it just made.
    _annotate(_frameId(bytes), msgType: f.msgType, streamId: f.streamId);
    return bytes.length;
  }

  void notifyRpcResult({required bool timedOut}) {
    if (!timedOut) {
      _consecutiveTimeouts = 0;
      return;
    }
    _consecutiveTimeouts++;
    if (_consecutiveTimeouts >= _kConsecutiveTimeoutsToClose &&
        _established &&
        !_handshakeInFlight) {
      _consecutiveTimeouts = 0;
      // A session with no application-layer keys to rotate cannot repair
      // itself in place: closing the link is the whole recovery, and the
      // supervisor redials with a fresh session.
      unawaited(relay.close());
    }
  }

  /// Detach [streamId]'s transport. A project's send queue lives on its own
  /// native stream, not [_scheduler] — `dropStream` here only ever matters for
  /// the control entry.
  void removeStream(String streamId) {
    _streams.remove(streamId);
    _scheduler.dropStream(streamId);
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
    // event invalidates it. Clearing `_established` is also what silences the
    // RPC-timeout close trigger, which is gated on a live session.
    _established = false;
    _generation = null;
    _stopLiveness();
    _cancelPendingWork();
    _resetRxFlow();
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
    // Whatever the send gate was still holding dies with the session it was
    // queued for. Their futures complete rather than fail: the callers
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
    // Windows reset BEFORE the attempt, not after it confirms: there is never
    // a second hello on the same link, so an attempt that fails closes the
    // link anyway, and a stale window left behind would misattribute whatever
    // the peer wrote in the meantime to a session that never existed.
    _scheduler.resetWindows();
    _resetRxFlow();
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
    _consecutiveTimeouts = 0;
    _startLiveness();
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    if (!_established$.isClosed) _established$.add(null);
    _scheduler.kick();
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

  // --- inbound flow control -------------------------------------------------

  void _resetRxFlow() {
    for (final ch in const ['control', 'preview']) {
      _consumed[ch] = 0;
      _creditSent[ch] = 0;
    }
  }

  /// Count payload bytes the agent charged to its window. Every frame that
  /// arrives on a live session counts, whether or not it decoded:
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
    // The flush above is deliberately ahead of this: closing the link still
    // leaves whatever credit was just queued written to the socket first.
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
    unawaited(_sendSessionFrame({'type': 'ping'}).catchError((_) {}));
  }

  // --- frame capture --------------------------------------------------------

  /// Read off the socket rather than injected, so a capture is wired in exactly
  /// one place (`app/lib/providers/relay_connection.dart`) and the two layers
  /// can never disagree about whether one is armed.
  RelayNetTap? get _tap => relay.netTap;

  String? _frameId(Uint8List payload) =>
      _tap == null ? null : frameIdOf(payload);

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

  // --- inbound dispatch (session stream) -------------------------------------

  /// Synchronous and in order: QUIC/TLS is the confidentiality layer now, so
  /// there is no per-frame async decrypt step left to chain — the old
  /// per-channel tail existed only to keep a slow `open()` from letting a
  /// small frame overtake a large one, and a plain UTF-8 decode never blocks.
  void _onPeerFrame(IncomingPeerFrame msg) {
    if (_disposed || !relay.isDispatchAllowed) return;
    final gen = _generation;
    // Counted even pre-establishment (the hello driver owns dispatch of
    // those frames, but the bridge already charged them to a window this
    // side must agree on once the window exists).
    if (gen != null || _handshakeInFlight) {
      _noteConsumed(msg.channel, msg.payload.length);
    }
    // Frames between `established` and this side's install are counted above
    // and dropped here; the snapshot re-pull on install covers them.
    if (gen == null) return;
    String plaintext;
    try {
      plaintext = utf8.decode(msg.payload);
    } catch (_) {
      _dropped('rx', 'bad-utf8', channel: msg.channel);
      return;
    }
    final frameId = frameIdOf(msg.payload);
    _lastRecv = DateTime.now();
    _missedPongs = 0;
    if (_reassembler.accept(
      plaintext,
      channel: msg.channel,
      frameId: frameId,
      epoch: gen.epoch,
    )) {
      // The reassembler consumes a fragment before any type is visible, so this
      // is the only chance to say what it was. Matches the bridge's `__frag`.
      _annotate(frameId, msgType: '__frag');
      return;
    }
    _dispatchDecoded(plaintext, msg.channel, frameId, gen.epoch);
  }

  /// [frameId] and [epoch] name the frame this plaintext arrived in. A
  /// reassembled message spans N frames and takes them from the fragment that
  /// completed it — see [FragReassembler.accept].
  void _dispatchDecoded(
    String plaintext,
    String channel,
    String frameId,
    int epoch,
  ) {
    if (_disposed || _generation == null || !relay.isDispatchAllowed) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (_) {
      _dropped('rx', 'plaintext-not-json', channel: channel, frameId: frameId);
      return;
    }
    final type = json['type'];
    // Payload disambiguation: a top-level `type` string is a
    // session/liveness frame; an `m` field is control-plane traffic.
    if (type is String) {
      _annotate(frameId, msgType: type);
      _handleSessionFrame(json, epoch);
      return;
    }
    if (!json.containsKey('m')) {
      _dropped(
        'rx',
        'unrecognized-plaintext',
        channel: channel,
        frameId: frameId,
      );
      return;
    }
    final env = StreamEnvelope.fromJson(json);
    if (env == null) {
      _dropped('rx', 'bad-envelope', channel: channel, frameId: frameId);
      return;
    }
    if (env.s != null && env.s != kControlStreamId) {
      // Stage A A4: a project's traffic rides its own stream now, so a
      // non-control `s` on the session stream means a peer still speaking
      // the pre-A4 protocol. No log line — this is a protocol drop, not the
      // "we hold no transport for a legitimate project" case the deleted
      // stream-unbound notice used to answer.
      _dropped(
        'rx',
        'project-on-session-stream',
        channel: channel,
        streamId: env.s,
        frameId: frameId,
      );
      return;
    }
    final m = env.m;
    final mType = m is Map<String, dynamic> && m['type'] is String
        ? m['type'] as String
        : null;
    _annotate(frameId, msgType: mType, streamId: kControlStreamId);
    if (m is Map<String, dynamic>) {
      _snoopControl(m);
      // Not the `control` getter: creating the transport here would fire a
      // snapshot pull nobody asked for. Adverts were snooped above, so a
      // session with no control transport yet loses nothing.
      _streams[kControlStreamId]?.dispatchFromSession(m, channel);
    }
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

  /// Takes the whole decoded frame, not just its type: `credit` carries fields.
  void _handleSessionFrame(Map<String, dynamic> json, int epoch) {
    switch (json['type']) {
      case 'ping':
        unawaited(_sendSessionFrame({'type': 'pong'}).catchError((_) {}));
        break;
      case 'pong':
        _missedPongs = 0;
        break;
      case 'credit':
        // Hand-validated, like every other session frame: these are bare
        // objects that never pass through the envelope schemas.
        final channel = json['channel'];
        final consumed = json['consumed'];
        if ((channel != 'control' && channel != 'preview') ||
            consumed is! int ||
            consumed < 0) {
          _log(RelayLogLevel.warn, 'dropping malformed credit frame');
          break;
        }
        // A cumulative total only means anything against the session that
        // produced it. Banking an earlier session's much larger total would
        // make every credit of the current one read as stale — the channel
        // would then ride the resync floor for the rest of it.
        if (_generation == null || epoch != _generation!.epoch) break;
        _scheduler.credit(channel as String, consumed);
        break;
      case 'session-takeover':
        // The agent is switching to another device and is about to drop our
        // session. Tear down and REPORT — re-establishing here would fight the
        // other device for it.
        _teardownSession();
        if (!_takeovers.isClosed) _takeovers.add(null);
        break;
    }
  }

  Future<void> _sendSessionFrame(Map<String, dynamic> obj) async {
    final gen = _generation;
    final type = obj['type'] as String?;
    if (gen == null) {
      _dropped('tx', 'no-e2e-session', channel: 'control', msgType: type);
      // This path carries ping, pong and credit — the frames the peer reads as
      // proof we are alive and as permission to keep sending. Losing one is
      // indistinguishable at the far end from a link that has gone dead, so it
      // must never be diagnosed only from an unarmed tap.
      _log(
        RelayLogLevel.warn,
        'session frame dropped — no session',
        fields: {'msgType': type},
      );
      return;
    }
    final ct = Uint8List.fromList(utf8.encode(jsonEncode(obj)));
    if (!relay.isDispatchAllowed) return;
    final outcome = await relay.sendFrame('control', ct);
    if (outcome != PeerSendOutcome.accepted || !identical(gen, _generation)) {
      // A generation change between the send and its outcome means a teardown
      // or a fresh hello already retired the session this frame was written
      // for.
      return;
    }
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
    for (final w in _tunnelSlotWaiters.values) {
      if (!w.isCompleted) w.complete(false);
    }
    _tunnelSlotWaiters.clear();
    // No drop records: the capture tap is read off the socket this dispose is
    // tearing down.
    _scheduler.clear();
    await _established$.close();
    await _takeovers.close();
    await _sessionDown.close();
    await _fragAborts.close();
    await _fragSendErrors.close();
    await _projectStreamEvents.close();
    _generation = null;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(StateError('session disposed'));
    }
    if (!_establishedReady.isCompleted) {
      _establishedReady.completeError(StateError('session disposed'));
    }
  }

  // --- terminal-attachment / tunnel slot pools (unchanged by A4) -----------

  /// Terminal-attachment streams this session currently holds open, capped at
  /// [kStreamMaxTerminalAttachmentsPerPeer] so an over-cap open fails locally
  /// (`CAP_EXCEEDED`) instead of stalling on `openBi` against the bridge's own
  /// per-peer limit.
  int _terminalAttachmentSlots = 0;

  bool _takeTerminalAttachmentSlot() {
    if (_terminalAttachmentSlots >= kStreamMaxTerminalAttachmentsPerPeer) {
      return false;
    }
    _terminalAttachmentSlots++;
    return true;
  }

  void _releaseTerminalAttachmentSlot() {
    if (_terminalAttachmentSlots > 0) _terminalAttachmentSlots--;
  }

  /// Tunnel-stream slots (HTTP and WS share one pool), capped at
  /// [kStreamMaxTunnelStreamsPerPeer]. Unlike terminal attachments, an
  /// over-cap open WAITS instead of failing locally (stage-A-A3-contract.md
  /// §9 D-5): a page load issues more parallel requests than any cap, and
  /// that is not the user's error. FIFO order comes from [Map] preserving
  /// insertion order.
  int _tunnelSlotsHeld = 0;
  final _tunnelSlotWaiters = <Object, Completer<bool>>{};

  /// `true` once [owner] holds a slot; `false` if [_cancelTunnelSlotWait] or
  /// [dispose] settles the wait first — the caller distinguishes those
  /// (`CANCELLED` vs `TRANSPORT_CLOSED`) itself, since only it knows which one
  /// happened. A free slot is granted synchronously so the open frame leaves
  /// in the same turn as the call, with no microtask for a racing cancel.
  FutureOr<bool> _acquireTunnelSlot(Object owner) {
    if (_tunnelSlotsHeld < kStreamMaxTunnelStreamsPerPeer) {
      _tunnelSlotsHeld++;
      return true;
    }
    final completer = Completer<bool>();
    _tunnelSlotWaiters[owner] = completer;
    return completer.future;
  }

  /// No-op once [owner]'s wait has already resolved (a slot was granted, or
  /// [dispose] already failed it).
  void _cancelTunnelSlotWait(Object owner) {
    final completer = _tunnelSlotWaiters.remove(owner);
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  /// Hands the freed slot straight to the oldest waiter instead of just
  /// decrementing the count: a waiter that never gets told a slot is free
  /// would otherwise starve behind every open that came before it.
  void _releaseTunnelSlot() {
    if (_tunnelSlotWaiters.isNotEmpty) {
      final owner = _tunnelSlotWaiters.keys.first;
      final completer = _tunnelSlotWaiters.remove(owner)!;
      completer.complete(true);
      return;
    }
    if (_tunnelSlotsHeld > 0) _tunnelSlotsHeld--;
  }

  /// Begin driving the session: subscribe to the socket and liveness.
  /// Call once, right after construction.
  ///
  /// Deliberately does NOT start a handshake. The connection supervisor climbs
  /// the ladder and calls [ensureEstablished] once the agent is reachable —
  /// having two components decide when to handshake is what the level-triggered
  /// supervisor replaced.
  void start() {
    _msgSub = relay.messageStream.listen(_onPeerFrame);
    _stateSub = relay.payloadStateStream.listen(_onState);
    _fragSweep = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        _reassembler.sweep();
        for (final st in _streams.values) {
          st._reassembler?.sweep();
        }
      },
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
}

/// Time left before [deadline], floored at zero — a negative [Duration] passed
/// to `Future.timeout` is not a meaningful budget.
Duration _remainingUntil(DateTime deadline) {
  final left = deadline.difference(DateTime.now());
  return left.isNegative ? Duration.zero : left;
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
  String get streamId => projectId ?? kControlStreamId;

  /// `true` for control, always. For a project, `true` only while its native
  /// stream is open and its first `stream-ready` record has arrived.
  bool _bound;
  bool get isProjectBound => _bound;

  // --- project-stream state (unused, and always default, for control) ------

  PeerStream? _peerStream;
  FragReassembler? _reassembler;
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
  int _fragCounter = 0;
  Future<void> _sendChain = Future<void>.value();

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
    await _fetchSnapshot(timeout: session.snapshotTimeout * 2);
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
      _reopenAttempt = 0;
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
      final relay = session.relay;
      if (relay is! MultiStreamPeerLink) {
        throw ProjectBindException(
          'STREAM_UNSUPPORTED',
          'link has no purpose-specific streams',
        );
      }
      // `PeerLink` and `MultiStreamPeerLink` are separate interfaces (see
      // peer_link.dart), so the `is!` check above cannot promote `relay`.
      final link = relay as MultiStreamPeerLink;
      PeerStream stream;
      try {
        stream = await link
            .openStream(
              ProjectStreamOpen(pid),
              maxRecordBytes: kStreamProjectRecordMaxBytes,
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
    final reassembler = FragReassembler(
      timeoutMs: kTransferTimeoutMs,
      globalBudgetBytes: kGlobalReassemblyBudget,
      onComplete: (json, channel, frameId, epoch) =>
          _dispatchProjectMessage(json),
      onAbort: (hint) {
        if (hint != null && !session._fragAborts.isClosed) {
          session._fragAborts.add(hint);
        }
      },
    );
    _reassembler = reassembler;
    unawaited(_runStream(stream, pid, firstCompleter, reassembler));
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
    FragReassembler reassembler,
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
        _onProjectRecord(record, reassembler);
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

  void _onProjectRecord(Uint8List record, FragReassembler reassembler) {
    final text = _safeUtf8Decode(record);
    if (text == null) {
      session._dropped('rx', 'bad-record', channel: 'control', streamId: streamId);
      return;
    }
    if (reassembler.accept(text, channel: 'control', frameId: streamId, epoch: 0)) {
      return;
    }
    _dispatchProjectMessage(text);
  }

  void _dispatchProjectMessage(String text) {
    final json = _tryDecodeJsonRecord(text);
    if (json == null) {
      session._dropped('rx', 'bad-record', channel: 'control', streamId: streamId);
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
        msgType: type,
      );
      return;
    }
    final stream = _peerStream;
    if (stream == null) return; // Defensive: `_bound` implies a live stream.
    final plaintext = jsonEncode(message);
    final bytes = utf8ByteLength(plaintext);
    if (bytes > kMaxTransferBytes) {
      session._dropped(
        'tx',
        'message-too-large',
        channel: channel,
        streamId: streamId,
        msgType: type,
        detail: {'bytes': bytes},
      );
      if (!session._fragSendErrors.isClosed) {
        session._fragSendErrors.add(
          FragSendError(
            'MESSAGE_TOO_LARGE',
            '${message['type'] ?? 'message'} exceeds kMaxTransferBytes',
          ),
        );
      }
      return;
    }
    final List<String> records;
    if (bytes <= kFragThreshold) {
      records = [plaintext];
    } else {
      final path = message['path'] as String?;
      final hint = type == 'file:content' && path != null
          ? FragHint('file:content', path)
          : null;
      // Bare-message fragments (no `{s, m}` envelope) — the id is unique per
      // (machine, project, counter); the bridge reassembles by bare id.
      final id = '${session.machineDeviceId}-$projectId-${_fragCounter++}';
      records = buildFragments(plaintext, id, hint);
    }
    // Every fragment of one message is handed to the writer in one
    // synchronous loop (§1.1) — nothing else may interleave inside a
    // fragment set. `_sendChain` already serializes against other messages.
    for (final record in records) {
      if (!_bound || !identical(_peerStream, stream)) return;
      PeerSendOutcome outcome;
      try {
        outcome = await stream.send(Uint8List.fromList(utf8.encode(record)));
      } catch (_) {
        _quietly(stream.reset());
        return;
      }
      if (outcome != PeerSendOutcome.accepted) {
        // A dropped noq SendStream FINs; every error path resets explicitly.
        // The read loop observes the resulting end and runs `_onStreamEnded`.
        _quietly(stream.reset());
        return;
      }
    }
  }

  /// Fresh bind (first ever, or a reopen): reset backoff, tell
  /// [MachineSession.projectStreamEvents], then re-pull durable state — the
  /// per-stream reconciliation checkpoint (see [refreshSnapshot]).
  void _onOpen() {
    _reopenAttempt = 0;
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
    _reassembler = null;
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
    _reassembler = null;
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

  @override
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
    bool countsTowardHealth = true,
  }) async {
    try {
      final r = await super.request(method, params: params, timeout: timeout);
      // Both outcomes are gated, not just the timeout: an exempt call's
      // SUCCESS resetting the run would let a pull that is re-driven on every
      // re-establishment keep clearing the evidence of a link that is failing
      // every other RPC — the same loop wearing the opposite sign.
      if (countsTowardHealth) session.notifyRpcResult(timedOut: false);
      return r;
    } on RpcException catch (e) {
      // ≥3 consecutive E_TIMEOUTs close the link. Skipped when the caller
      // re-issues this same pull on every re-establishment — including the
      // one that close itself causes — since folding those in makes the retry
      // loop its own trigger (see the doc on [AgentTransport.request]).
      if (countsTowardHealth) {
        session.notifyRpcResult(timedOut: e.code == 'E_TIMEOUT');
      }
      rethrow;
    }
  }

  /// Deliver a decoded message that the session (or this project's own
  /// stream) demuxed to this transport.
  void dispatchFromSession(Map<String, dynamic> json, String channel) =>
      dispatchDecoded(json, channel);

  /// Opens a native terminal stream when the session's link supports one,
  /// falling back to the inherited socket-path attachment otherwise (e.g.
  /// `fake_live_relay.dart`, which implements [PeerLink] only).
  @override
  TerminalAttachment openTerminalAttachment({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> subscribe,
  }) {
    final link = session.relay;
    if (link is! MultiStreamPeerLink) {
      return super.openTerminalAttachment(
        requestId: requestId,
        checkoutId: checkoutId,
        subscribe: subscribe,
      );
    }
    final attachment = _StreamTerminalAttachment(
      transport: this,
      requestId: requestId,
      checkoutId: checkoutId,
      subscribe: subscribe,
      // `PeerLink` and `MultiStreamPeerLink` are separate interfaces (see
      // peer_link.dart), so the `is!` check above cannot promote `link`.
      link: link as MultiStreamPeerLink,
    );
    attachment._start();
    return attachment;
  }

  /// Opens a native HTTP tunnel stream when the session's link supports one,
  /// falling back to the inherited `NOT_SUPPORTED` stub otherwise (D2:
  /// loopback never tunnels, so there is no socket-path implementation).
  @override
  TunnelHttpExchange openTunnelHttp({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required Uint8List body,
  }) {
    final link = session.relay;
    if (link is! MultiStreamPeerLink) {
      return super.openTunnelHttp(
        requestId: requestId,
        checkoutId: checkoutId,
        head: head,
        body: body,
      );
    }
    final exchange = _StreamTunnelHttpExchange(
      transport: this,
      requestId: requestId,
      checkoutId: checkoutId,
      head: head,
      body: body,
      // `PeerLink` and `MultiStreamPeerLink` are separate interfaces (see
      // peer_link.dart), so the `is!` check above cannot promote `link`.
      link: link as MultiStreamPeerLink,
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
    final link = session.relay;
    if (link is! MultiStreamPeerLink) {
      return super.openTunnelWs(
        tunnelId: tunnelId,
        checkoutId: checkoutId,
        open: open,
      );
    }
    final channel = _StreamTunnelWsChannel(
      transport: this,
      tunnelId: tunnelId,
      checkoutId: checkoutId,
      open: open,
      link: link as MultiStreamPeerLink,
    );
    channel._start();
    return channel;
  }

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
  /// The pull is retried on timeout, since a reply that lands after the wait
  /// is discarded like any late RPC response. Only the first attempt is
  /// awaited: the hydrators do not depend on the snapshot having landed (a
  /// bundle built before it reads the frames live when they arrive), so they
  /// must not wait out a bad link's retries.
  Future<void> refreshSnapshot() async {
    await _fetchSnapshot(timeout: session.snapshotTimeout);
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
  /// superseded rather than duplicated. The returned future completes when the
  /// FIRST round trip settles, not when the snapshot lands: the retries run
  /// detached, exactly as they do for [refreshSnapshot].
  Future<void> refreshDurableState() =>
      _fetchSnapshot(timeout: session.snapshotTimeout);

  /// Round trips a pull gets before it is given up on, the first included.
  /// Each retry doubles the previous wait, so the last one gives a slow reply
  /// four times the room the first did.
  static const _kSnapshotAttempts = 3;

  /// Stamps each pull so the retries of a superseded one stop: a
  /// (re)establish or a second bind starts a fresh pull on the live session,
  /// and [dispose] ends them all.
  int _snapshotGen = 0;

  Future<void> _fetchSnapshot({required Duration timeout}) async {
    final gen = ++_snapshotGen;
    if (await _pullSnapshot(timeout, attempt: 1)) return;
    unawaited(_retrySnapshot(gen, timeout));
  }

  Future<void> _retrySnapshot(int gen, Duration timeout) async {
    for (var attempt = 2; attempt <= _kSnapshotAttempts; attempt++) {
      timeout *= 2;
      if (gen != _snapshotGen || outbound.isClosed || !isEstablished) {
        return;
      }
      if (await _pullSnapshot(timeout, attempt: attempt)) return;
    }
    session._log(
      RelayLogLevel.warn,
      'state.snapshot gave up; frames stay as they were until the next '
      'establishment',
      fields: {'streamId': streamId, 'attempts': _kSnapshotAttempts},
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
      // close trigger. A retry re-asks a question already counted, and letting
      // it count too made the chain itself the trigger: three waits on a slow
      // link forced a re-establish, the re-establish started a fresh chain, and the
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
      return true;
    } on RpcException catch (e) {
      // Leave the existing cache untouched either way.
      if (e.code != 'E_TIMEOUT') return true;
      session._log(
        RelayLogLevel.info,
        'state.snapshot timed out',
        fields: {
          'streamId': streamId,
          'timeoutMs': timeout.inMilliseconds,
          'attempt': attempt,
          'of': _kSnapshotAttempts,
        },
      );
      return false;
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

/// A terminal attachment riding its own native QUIC stream. Opens
/// asynchronously and never throws: every failure — including the open
/// itself — ends [done] with a [TerminalAttachmentFailed] instead (carry-over
/// 4), so a bridge that briefly cannot serve one attachment never surfaces
/// through [PeerLink.failureStream] or the connection supervisor.
class _StreamTerminalAttachment implements TerminalAttachment {
  _StreamTerminalAttachment({
    required this.transport,
    required this.requestId,
    required this.checkoutId,
    required Map<String, dynamic> subscribe,
    required MultiStreamPeerLink link,
  }) : _subscribe = subscribe,
       _link = link;

  final StreamTransport transport;
  MachineSession get session => transport.session;
  @override
  final String requestId;
  @override
  final String checkoutId;
  final Map<String, dynamic> _subscribe;
  final MultiStreamPeerLink _link;

  @override
  bool get isStream => true;

  final _messages = StreamController<Map<String, dynamic>>();
  final _doneCompleter = Completer<TerminalAttachmentEnd>();

  bool _slotTaken = false;
  bool _ended = false;
  // Set by close(): before the stream exists yet, or while its open is still
  // in flight, there is nothing to finish() — only a slot and (once opened) a
  // stream to reset.
  bool _closeRequested = false;
  PeerStream? _stream;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<TerminalAttachmentEnd> get done => _doneCompleter.future;

  // Once a stream exists the slot is held until its records complete, so a
  // close() cannot free a slot the bridge is still counting.
  bool _recordsDone = false;

  void _releaseSlot() {
    if (!_slotTaken) return;
    _slotTaken = false;
    session._releaseTerminalAttachmentSlot();
  }

  void _end(TerminalAttachmentEnd end) {
    if (_ended) return;
    _ended = true;
    if (_stream == null || _recordsDone) _releaseSlot();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete(end);
    unawaited(_messages.close());
  }

  Future<void> _start() async {
    if (!session._takeTerminalAttachmentSlot()) {
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
      stream = await _link.openStream(
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
    _stream = stream;
    if (_closeRequested) {
      // close() landed while the open was in flight: reset rather than
      // finish() a stream whose subscribe was never sent. The bridge counts
      // this stream against its cap until its own half ends, so the slot is
      // held until the records drain (carry-over 1), never freed here.
      _quietly(stream.reset());
      _end(const TerminalAttachmentClosedLocally());
      await _readRecords(stream);
      return;
    }
    PeerSendOutcome? outcome;
    Object? sendError;
    try {
      outcome = await stream.send(
        Uint8List.fromList(utf8.encode(jsonEncode(_subscribe))),
      );
    } catch (e) {
      sendError = e;
    }
    if (outcome != PeerSendOutcome.accepted) {
      // Same carry-over 1 as a close() during the open: held until drained.
      _quietly(stream.reset());
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
          final refusal = StreamRefused.tryDecode(record);
          if (refusal != null) {
            _quietly(stream.finish());
            _end(TerminalAttachmentRefused(refusal));
            continue;
          }
        }
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(record));
        } catch (_) {
          decoded = null;
        }
        if (decoded is! Map<String, dynamic>) {
          _quietly(stream.reset());
          _end(const TerminalAttachmentFailed('INVALID_RECORD'));
          continue;
        }
        if (!_messages.isClosed) _messages.add(decoded);
      }
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    // The bridge's half ended (FIN or reset — Dart cannot tell them apart).
    // Always finish our own send half here (a no-op if already finished),
    // and release the slot now that nothing more is coming.
    try {
      await stream.finish();
    } catch (_) {
      // A link already gone has nothing left to finish.
    }
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
        Uint8List.fromList(utf8.encode(jsonEncode(message))),
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
    try {
      await stream.finish();
    } catch (_) {
      // Never throws; the records loop still observes the bridge's end.
    }
  }
}

/// Fire-and-forget for a stream end whose failure means the link is already
/// gone: an unawaited rejection would otherwise surface as an uncaught error.
void _quietly(Future<void> future) =>
    unawaited(future.catchError((Object _) {}));

/// One app-side upload slice, at most this many bytes per `0x00` record
/// (stage-A-A3-contract.md §1.3 — the same `STREAM_RECORD_SLICE_BYTES` every
/// stream's writer uses).
const int _kTunnelBodySliceBytes = 262144;

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
class _StreamTunnelHttpExchange implements TunnelHttpExchange {
  _StreamTunnelHttpExchange({
    required this.transport,
    required this.requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required Uint8List body,
    required MultiStreamPeerLink link,
  }) : _checkoutId = checkoutId,
       _head = head,
       _body = body,
       _link = link;

  final StreamTransport transport;
  MachineSession get session => transport.session;
  @override
  final String requestId;
  final String _checkoutId;
  final Map<String, dynamic> _head;
  final Uint8List _body;
  final MultiStreamPeerLink _link;

  final _headCompleter = Completer<TunnelHttpHead>();
  final _bodyController = StreamController<TunnelBodyRecord>();

  bool _slotTaken = false;
  bool _ended = false;
  bool _cancelRequested = false;
  bool _headDelivered = false;
  bool _endRecordSeen = false;
  // Set once a stream exists and its records have fully drained — mirrors
  // _StreamTerminalAttachment's rule: the slot is held until then, never
  // freed early by cancel() alone.
  bool _recordsDone = false;
  PeerStream? _stream;

  @override
  Future<TunnelHttpHead> get head => _headCompleter.future;

  @override
  Stream<TunnelBodyRecord> get body => _bodyController.stream;

  void _releaseSlot() {
    if (!_slotTaken) return;
    _slotTaken = false;
    session._releaseTunnelSlot();
  }

  void _fail(TunnelExchangeFailure failure) {
    if (_ended) return;
    _ended = true;
    if (!_headCompleter.isCompleted) _headCompleter.completeError(failure);
    if (!_bodyController.isClosed) {
      _bodyController.addError(failure);
      unawaited(_bodyController.close());
    }
    if (_stream == null || _recordsDone) _releaseSlot();
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
    final slot = session._acquireTunnelSlot(this);
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
      stream = await _link.openStream(
        TunnelHttpStreamOpen(projectId: projectId, requestId: requestId),
        maxRecordBytes: kStreamTunnelRecordMaxBytes,
        maxQueuedBytes: kTunnelStreamMaxQueuedBytes,
      );
    } catch (e) {
      _fail(TunnelExchangeFailure('STREAM_OPEN_FAILED', error: e));
      return;
    }
    _stream = stream;
    // "Opening: reset once open" (stage-A-A3-contract.md §4.1 cancel()) — a
    // clean CANCELLED, since nothing was ever written for the bridge to
    // answer.
    if (_cancelRequested) {
      _quietly(stream.reset());
      _fail(const TunnelExchangeFailure('CANCELLED'));
      // The bridge counts this stream against its cap until it sees the
      // reset and answers it; freeing the slot before our records end would
      // let the next open race that and draw a spurious CAP_EXCEEDED.
      await _readRecords(stream);
      return;
    }
    final headJson = <String, dynamic>{
      ..._head,
      'bodyLength': _body.length,
      'checkoutId': _checkoutId,
    };
    PeerSendOutcome? headOutcome;
    Object? headError;
    try {
      headOutcome = await stream.send(
        Uint8List.fromList(utf8.encode(jsonEncode(headJson))),
      );
    } catch (e) {
      headError = e;
    }
    // "Open: stop the upload, reset() the send half, keep draining records" —
    // cancel() has already reset; just fall through to draining rather than
    // reporting this send's own outcome as a failure.
    if (!_cancelRequested) {
      if (headOutcome != PeerSendOutcome.accepted) {
        _quietly(stream.reset());
        _fail(TunnelExchangeFailure('SEND_FAILED', error: headError));
        await _readRecords(stream);
        return;
      }
      var sent = 0;
      while (sent < _body.length) {
        final end = min(sent + _kTunnelBodySliceBytes, _body.length);
        final slice = Uint8List.sublistView(_body, sent, end);
        PeerSendOutcome? sliceOutcome;
        Object? sliceError;
        try {
          sliceOutcome = await stream.send(
            encodeTunnelDataRecord(kTunnelRecordTagBody, slice),
          );
        } catch (e) {
          sliceError = e;
        }
        if (_cancelRequested) break;
        if (sliceOutcome != PeerSendOutcome.accepted) {
          _quietly(stream.reset());
          _fail(TunnelExchangeFailure('SEND_FAILED', error: sliceError));
          await _readRecords(stream);
          return;
        }
        sent = end;
      }
    }
    await _readRecords(stream);
  }

  Future<void> _readRecords(PeerStream stream) async {
    var first = true;
    try {
      await for (final record in stream.records) {
        if (_ended) continue; // Keep draining without delivering.
        if (first) {
          first = false;
          final refusal = StreamRefused.tryDecode(record);
          if (refusal != null) {
            _quietly(stream.finish());
            _fail(TunnelExchangeFailure('REFUSED', refusal: refusal));
            continue;
          }
          final decoded = decodeTunnelRecord(record);
          final json = decoded is TunnelJsonRecord
              ? _tryDecodeJsonRecord(decoded.text)
              : null;
          if (json == null ||
              json['type'] != 'tunnel:http-head' ||
              json['requestId'] != requestId) {
            _quietly(stream.reset());
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
        final decoded = decodeTunnelRecord(record);
        if (decoded is TunnelDataRecord) {
          if (decoded.tag != kTunnelRecordTagBody &&
              decoded.tag != kTunnelRecordTagBodyGzip) {
            _quietly(stream.reset());
            _fail(const TunnelExchangeFailure('PROTOCOL'));
            continue;
          }
          if (!_bodyController.isClosed) {
            _bodyController.add(
              TunnelBodyRecord(
                bytes: decoded.payload,
                gzip: decoded.tag == kTunnelRecordTagBodyGzip,
              ),
            );
          }
          continue;
        }
        final json = decoded is TunnelJsonRecord
            ? _tryDecodeJsonRecord(decoded.text)
            : null;
        if (json != null && json['type'] == 'tunnel:http-end') {
          _endRecordSeen = true;
          if (!_bodyController.isClosed) unawaited(_bodyController.close());
          continue;
        }
        _quietly(stream.reset());
        _fail(const TunnelExchangeFailure('PROTOCOL'));
      }
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    try {
      await stream.finish();
    } catch (_) {
      // A link already gone has nothing left to finish.
    }
    _recordsDone = true;
    if (!_ended) {
      if (_cancelRequested) {
        // The bridge's half ends because our reset told it to; reporting that
        // as STREAM_ENDED or TRUNCATED would blame the peer for our cancel.
        _fail(const TunnelExchangeFailure('CANCELLED'));
      } else if (!_headDelivered) {
        _fail(const TunnelExchangeFailure('STREAM_ENDED'));
      } else if (!_endRecordSeen) {
        _fail(const TunnelExchangeFailure('TRUNCATED'));
      } else {
        // A clean end after tunnel:http-end: nothing more to report, but the
        // slot this exchange held is still live until now.
        _releaseSlot();
      }
    } else {
      _releaseSlot();
    }
  }

  @override
  void cancel() {
    if (_cancelRequested || _ended) return;
    _cancelRequested = true;
    // A caller that cancels has stopped caring about the head, so the
    // CANCELLED it will now carry must not surface as an unhandled error.
    _headCompleter.future.ignore();
    session._cancelTunnelSlotWait(this);
    final stream = _stream;
    if (stream == null) return; // _start() checks _cancelRequested once open resolves.
    _quietly(stream.reset());
  }
}

/// One browser-side WebSocket's tunnel, riding its own native QUIC stream for
/// the socket's lifetime. Same carry-over-4 shape as
/// [_StreamTunnelHttpExchange]: every failure ends [done] locally rather than
/// surfacing through [PeerLink.failureStream].
class _StreamTunnelWsChannel implements TunnelWsChannel {
  _StreamTunnelWsChannel({
    required this.transport,
    required this.tunnelId,
    required String checkoutId,
    required Map<String, dynamic> open,
    required MultiStreamPeerLink link,
  }) : _checkoutId = checkoutId,
       _open = open,
       _link = link;

  final StreamTransport transport;
  MachineSession get session => transport.session;
  @override
  final String tunnelId;
  final String _checkoutId;
  final Map<String, dynamic> _open;
  final MultiStreamPeerLink _link;

  final _frames = StreamController<TunnelWsFrame>();
  final _doneCompleter = Completer<TunnelWsEnd>();
  // Resolves once the open sequence settles: the live stream, or null if it
  // never got one (refused before send, cancelled, disposed while waiting).
  final _streamReady = Completer<PeerStream?>();

  bool _slotTaken = false;
  bool _ended = false;
  bool _abortRequested = false;
  bool _closeRequested = false;
  bool _recordsDone = false;
  bool _sawCloseRecord = false;
  int? _peerCloseCode;
  String? _peerCloseReason;
  PeerStream? _stream;

  /// Serializes every [send]/[close] call in arrival order, including ones
  /// made before the stream opens (stage-A-A3-contract.md §4.1).
  Future<bool> _sendChain = Future<bool>.value(true);

  @override
  Stream<TunnelWsFrame> get frames => _frames.stream;

  @override
  Future<TunnelWsEnd> get done => _doneCompleter.future;

  void _releaseSlot() {
    if (!_slotTaken) return;
    _slotTaken = false;
    session._releaseTunnelSlot();
  }

  void _end(TunnelWsEnd end) {
    if (_ended) return;
    _ended = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete(end);
    unawaited(_frames.close());
    if (_stream == null || _recordsDone) _releaseSlot();
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
    final slot = session._acquireTunnelSlot(this);
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
      stream = await _link.openStream(
        TunnelWsStreamOpen(projectId: projectId, wsId: tunnelId),
        maxRecordBytes: kStreamTunnelRecordMaxBytes,
        maxQueuedBytes: kTunnelStreamMaxQueuedBytes,
      );
    } catch (e) {
      _streamReady.complete(null);
      _end(TunnelWsFailed(TunnelExchangeFailure('STREAM_OPEN_FAILED', error: e)));
      return;
    }
    _stream = stream;
    if (_abortRequested) {
      _quietly(stream.reset());
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
        Uint8List.fromList(utf8.encode(jsonEncode(openJson))),
      );
    } catch (e) {
      sendError = e;
    }
    if (!_abortRequested && outcome != PeerSendOutcome.accepted) {
      _quietly(stream.reset());
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
          final refusal = StreamRefused.tryDecode(record);
          if (refusal != null) {
            _quietly(stream.finish());
            _end(TunnelWsFailed(TunnelExchangeFailure('REFUSED', refusal: refusal)));
            continue;
          }
        }
        final decoded = decodeTunnelRecord(record);
        if (decoded is TunnelDataRecord) {
          if (decoded.tag != kTunnelRecordTagWsText &&
              decoded.tag != kTunnelRecordTagWsBinary) {
            _quietly(stream.reset());
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
        _quietly(stream.reset());
        _end(TunnelWsFailed(const TunnelExchangeFailure('PROTOCOL')));
      }
    } catch (_) {
      // A records error is the bridge's half ending too; handled below.
    }
    try {
      await stream.finish();
    } catch (_) {
      // A link already gone has nothing left to finish.
    }
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
      _quietly(stream.reset());
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
      _quietly(stream.reset());
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
      await stream.send(Uint8List.fromList(utf8.encode(jsonEncode(msg))));
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
    session._cancelTunnelSlotWait(this);
    final stream = _stream;
    if (stream != null) _quietly(stream.reset());
  }
}
