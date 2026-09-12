import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import '../analytics/events.dart';
import '../models/terminal_models.dart';
import '../models/ab_message.dart';
import '../project/perf_recorder.dart';
import '../project/project_session.dart';
import '../util/detached.dart';
import '../utils/terminal_bell.dart';
import 'reply_latch.dart';

class TerminalService {
  final ProjectSession session;
  final String checkoutId;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<void>? _resumeSub;
  bool _disposed = false;

  final Map<String, Timer> _resizeTimers = {};
  final Map<String, String?> _resizeBaseDrivers = {};
  final Map<String, Timer> _pendingTerminalTimers = {};
  final Set<String> _deletedTerminalIds = {};
  final Set<String> _pendingTerminalIds = {};
  final Set<String> _canceledPendingTerminalIds = {};
  final Set<String> _missingTerminalIds = {};

  // --- Frame mode (live `terminal:frame` display) ---

  /// terminalId -> the `requestId` of this client's most recently sent
  /// `terminal:subscribe`. A `terminal:subscribed` or `terminal:display:status`
  /// whose own `requestId` does not match is the answer to an attempt this
  /// terminal has since superseded (a fresh reconnect, respawn or retry) and
  /// must never resurrect it.
  final Map<String, String> _frameSubscribeRequestId = {};

  /// terminalId -> true while a `terminal:subscribe` is outstanding for it.
  /// Consumed by whichever answers first: `terminal:subscribed`, or a
  /// `terminal:display:status` naming the same request.
  final Set<String> _frameSubscribePending = {};

  final Map<String, int> _frameSubscribeRequestedAtMs = {};

  final Map<String, Timer> _frameSubscribeDeadlines = {};

  /// terminalId -> the live attachment once `terminal:subscribed` has been
  /// accepted for it. Absent means no live frame-mode attachment: subscribe
  /// has never succeeded, is outstanding, or the attachment was retired
  /// (ended, failed, unsubscribed, or dropped locally by a fresh attach
  /// attempt that has not yet been answered).
  ///
  /// Scoped to THIS connection: an attachment id is minted by one
  /// `TerminalViewerConnection` and does not survive a reconnect, so every
  /// re-attach drops it before asking again rather than trusting it to still
  /// name anything on the other end.
  final Map<String, ({String runId, String attachmentId})> _frameAttachment =
      {};
  final Map<String, String> _historyRunId = {};
  final Map<String, ({String runId, String attachmentId})>
  _endedHistoryAttachment = {};
  final Map<String, int?> _pendingExitCodes = {};

  /// terminalId -> the highest `terminal:frame` `sequence` this client has
  /// processed (applied or dropped as stale) for its live attachment. Acks
  /// are cumulative on this value, so it doubles as "what to ack next".
  final Map<String, int> _frameHighestSequence = {};

  /// Terminals whose live frame attachment has painted at least one frame.
  /// reconnect or a resubscribe attempt (the engine's last frame is still
  /// current-looking on screen right up until a fresh one replaces it), only
  /// on a genuinely fresh engine ([_createTab]) or a deletion.
  final Set<String> _framePaintedIds = {};

  /// Terminals whose live frame attachment reported a failure other than
  /// `ENDED` -- DISPLAY_FAILED, ACK_TIMEOUT, or any code this client does not
  /// recognize (a newer agent's failure must surface, never be silently
  /// ignored). `HISTORY_DISABLED` is deliberately absent: it scopes to the
  /// archive, and badging a pane that is still painting for a scrollback
  /// refusal hides a terminal that works -- it lands on the terminal's
  /// [TerminalHistoryModel] instead. See [TerminalAttachStage.failed].
  final Set<String> _frameFailedIds = {};

  /// Terminals whose live frame attachment ended with `ENDED` -- the run
  /// completed. Lifecycle, not failure; kept distinct from [_frameFailedIds]
  /// so [TerminalAttachStage.ended] never renders as a failure. See
  /// [TerminalAttachStage.ended].
  final Set<String> _frameEndedIds = {};

  /// terminalId -> the last `terminal:display:status.message` for it, shown
  /// alongside [_frameFailedIds] / [_frameEndedIds].
  final Map<String, String> _frameStatusMessage = {};

  /// terminalId -> the bound on an outstanding `terminal:history:request`.
  ///
  /// A history page is the one frame-mode reply with no other path back to the
  /// user: nothing else restates it, and the model reads as loading until it
  /// lands. An agent that drops the request (a checkout deleting under it, a
  /// run rotated away, a wire that went quiet) would otherwise leave the pane
  /// spinning for good.
  final Map<String, Timer> _historyRequestDeadlines = {};

  Timer? _checkoutAttachDeadline;
  bool _sawAgentStatus = false;
  bool _checkoutAttachFailed = false;
  bool _hydrationPublishScheduled = false;
  bool _trackedUse = false;

  /// True while `session.transport.isEstablished` reads false — the only
  /// truthful synchronous read of "a send will actually leave". Synced by
  /// [_syncInputPaused], never toggled directly, so every writer folds into
  /// the same emission gate.
  bool _inputPaused = false;

  String? _clientId;
  void setClientId(String id) => _clientId = id;

  /// Wall-clock bound for the one-shot git verbs (list-branches, checkout). A
  /// reply that never lands (dropped send / session down) would otherwise strand
  /// [TerminalState.gitBranchesLoading] on forever. Injectable so tests drive a
  /// short window.
  final Duration gitActionTimeout;

  /// Bounds optimistic terminal state when the one-shot start send is dropped.
  /// Injectable so tests do not wait for the production recovery window.
  final Duration terminalStartTimeout;

  /// Bounds one terminal's screen pull. A request is not a promise of a reply —
  /// an id the agent no longer knows, and a send dropped in a keyless window or
  /// behind the machine's remote-access gate, are all answered with no frame at
  /// all — so an unanswered pull over an empty engine has to end somewhere.
  /// Injectable so tests drive a short window.
  final Duration snapshotAttachTimeout;

  /// Bounds the wait for the checkout's first `agent:status`, which is what
  /// tells the app there are any terminals to attach to.
  final Duration checkoutAttachTimeout;
  ReplyLatch? _branchesLatch;
  ReplyLatch? _checkoutLatch;

  /// Every attach bound is armed on first subscription and dropped with the
  /// last one: a bound exists to tell a surface that is waiting that its wait
  /// ended badly, so a service nobody watches must not hold a live timer for
  /// the length of the timeout — the test binding reports one outliving its
  /// widget tree as a leak, and a service is built eagerly for every checkout
  /// whether or not anything reads it.
  late final _stateController = StreamController<TerminalState>.broadcast(
    onListen: _resumeAttachBounds,
    onCancel: _dropAttachBounds,
  );
  final StreamController<TerminalNotificationMessage> _notificationController =
      StreamController<TerminalNotificationMessage>.broadcast();
  final StreamController<NotificationPushMessage> _pushController =
      StreamController<NotificationPushMessage>.broadcast();
  TerminalState _state = const TerminalState();

  Stream<TerminalState> get stateStream => _stateController.stream;
  Stream<TerminalNotificationMessage> get notificationStream =>
      _notificationController.stream;
  Stream<NotificationPushMessage> get pushNotificationStream =>
      _pushController.stream;
  TerminalState get currentState => _state;
  String get projectId => session.projectId;

  TerminalService.fromSession(
    this.session, {
    this.checkoutId = 'main',
    this.gitActionTimeout = const Duration(seconds: 15),
    this.terminalStartTimeout = const Duration(seconds: 15),
    this.snapshotAttachTimeout = const Duration(seconds: 15),
    this.checkoutAttachTimeout = const Duration(seconds: 30),
  }) {
    // Heavy tier — terminal:output + terminal:snapshot (HEAVY tier messages).
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onHeavyJson);

    // Status tier — terminal:started, terminal:exited, agent:status,
    // git:branches, git:checkout-result. Routed through the focus-gated
    // router status stream so all dispatch goes through one path.
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onStatusJson);
  }

  static const _frameHydratorKey = 'terminal:frames';

  void activate() {
    if (_disposed) return;
    session.hydrateCheckout(checkoutId, _frameHydratorKey, _rehydrateTerminals);
    _resumeSub ??= session.focusResumed.listen(
      (_) => detached(
        'TerminalService',
        're-attach snapshot pull on focus resume',
        _rehydrateTerminals,
      ),
    );
  }

  void deactivate() {
    if (_disposed) return;
    session.unhydrateCheckout(checkoutId, _frameHydratorKey);
    unawaited(_resumeSub?.cancel());
    _resumeSub = null;
  }

  /// Bounds the wait for the first `agent:status`, so a checkout that is never
  /// answered stops claiming progress.
  ///
  /// Re-armed rather than merely cancelled wherever the attach is re-driven: a
  /// fresh attempt clears the previous failure, and clearing it without a new
  /// bound would leave the checkout attaching with nothing left to end it.
  void _cancelCheckoutAttachDeadline() {
    _checkoutAttachDeadline?.cancel();
    _checkoutAttachDeadline = null;
  }

  void _dropAttachBounds() {
    _cancelCheckoutAttachDeadline();
    for (final terminalId in _frameSubscribePending.toList()) {
      _clearPendingSubscribe(terminalId);
    }
  }

  void _resumeAttachBounds() {
    _armCheckoutAttachDeadline();
    if (_disposed) return;
    for (final entry in _state.tabs.entries) {
      // Only the tabs a pull could still reach, and only those left with
      // neither a screen nor anything outstanding — a re-pull over a painted
      // or in-flight tab is the churn `_stageFor`'s `refreshing` arm exists to
      // keep off screen.
      if (!_hasLivePty(entry.value)) continue;
      if (_stageFor(entry.key) != TerminalAttachStage.cold) continue;
      _attachTerminal(entry.key);
    }
  }

  void _armCheckoutAttachDeadline() {
    _cancelCheckoutAttachDeadline();
    if (_disposed || _sawAgentStatus) return;
    _checkoutAttachDeadline = Timer(checkoutAttachTimeout, () {
      _checkoutAttachDeadline = null;
      if (_disposed || _sawAgentStatus) return;
      _checkoutAttachFailed = true;
      _publishHydration();
    });
  }

  Future<void> _rehydrateTerminals() async {
    if (_disposed) return;
    // The re-establish edge, and the only one there is: nothing publishes a
    // transport transition the pane could listen for — `sessionDownEvents`
    // fires from retry exhaustion, not a live socket loss, and StreamTransport
    // never emits `disconnected`. So the refusal latch is cleared by the same
    // hydrator re-drive that reopens the pulls, which is exactly what a
    // recovered send would have needed anyway.
    _syncInputPaused();
    // A checkout that was merely slow is not a broken one, and this path is a
    // fresh attempt at the thing that timed out. The verdict is dropped and
    // re-bounded together — a cleared failure with no deadline behind it would
    // leave the checkout attaching with nothing left to end it. Skipped when
    // neither is live, so a re-drive can never mint the first bound for a
    // service nothing is listening to.
    if (_checkoutAttachDeadline != null || _checkoutAttachFailed) {
      _checkoutAttachFailed = false;
      _armCheckoutAttachDeadline();
    }
    // The geometry is invalidated on the same grounds as the cutoff above: a
    // reattach can hide a resize the agent never applied, and an
    // exit-and-respawn nothing on the wire reported (the seq reasoning in the
    // constructor). Neither is detectable from the app's side, and the driver's
    // gate compares against what it BELIEVES it sent, so an unmoving panel
    // never reopens it. Bumped for every live tab rather than only the
    // re-pulled ones; the bridge folds a resize that changes nothing away, so a
    // bump that proves unnecessary costs no SIGWINCH.
    //
    // The `focusResumed` caller keeps its transport, so nothing was lost there
    // — but it shares this path because the same edge covers a heavy
    // re-subscribe, which an unwitnessed respawn can hide just as a reconnect
    // can.
    final rehydrated = Map<String, TerminalTab>.from(_state.tabs);
    var invalidated = false;
    for (final entry in _state.tabs.entries) {
      if (!_hasLivePty(entry.value)) continue;
      rehydrated[entry.key] = entry.value.copyWith(
        sizeEpoch: entry.value.sizeEpoch + 1,
      );
      invalidated = true;
    }
    if (invalidated) _setState(_state.copyWith(tabs: rehydrated));
    for (final tab in rehydrated.values) {
      // The bridge has not admitted an optimistic start yet; its started
      // event will attach the confirmed run.
      if (_pendingTerminalIds.contains(tab.terminalId)) continue;
      _attachTerminal(tab.terminalId);
    }
  }

  /// Whether a resize aimed at [tab] can reach a PTY.
  ///
  /// A pending id is the app's own optimistic invention the agent has never
  /// confirmed, and an exited tab has no PTY behind it — an agent tab keeps
  /// rendering the terminal view past its own exit, so a geometry
  /// invalidation on either only buys a frame the bridge logs as unknown and
  /// drops.
  bool _hasLivePty(TerminalTab tab) =>
      tab.sessionState == TerminalSessionState.running &&
      !_missingTerminalIds.contains(tab.terminalId) &&
      !_pendingTerminalIds.contains(tab.terminalId);

  /// Retires whatever the driver believes [terminalId]'s geometry is, so its
  /// next build re-sends at an unchanged panel size.
  ///
  /// Called wherever a resize the app already reported as accepted is known
  /// not to have reached the PTY. `sendResize` answers at QUEUE time, and the
  /// 100ms debounce it arms can still be cancelled or discarded afterwards;
  /// the caller has booked the size by then, so nothing but an epoch bump
  /// reopens its gate.
  void _invalidateGeometry(String terminalId) {
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[terminalId] = tab.copyWith(sizeEpoch: tab.sizeEpoch + 1);
    _setState(_state.copyWith(tabs: tabs));
  }

  void _setState(TerminalState state) {
    if (_disposed) return;
    // Focusing a terminal — by ANY path (list tap, pinned/pushed view, agent
    // auto-focus) — marks it read. Centralized here so every activeTerminalId
    // change clears the badge, not just the list-row tap.
    final activeId = state.activeTerminalId;
    if (activeId != null) {
      final activeTab = state.tabs[activeId];
      if (activeTab != null && activeTab.unread) {
        final tabs = Map<String, TerminalTab>.from(state.tabs);
        tabs[activeId] = activeTab.copyWith(unread: false);
        state = state.copyWith(tabs: tabs);
      }
    }
    // Recomputed on every emission rather than carried, because every mutation
    // site funnels through here: a value carried on the state would be wiped by
    // the field-by-field rebuild in _handleAgentStatus, and one carried on a tab
    // by any of the copyWith sites.
    state = state.copyWith(
      hydration: _deriveHydration(state.tabs),
      attach: _deriveAttach(state.tabs),
      inputPaused: _inputPaused,
    );
    _state = state;
    _stateController.add(state);
  }

  Map<String, TerminalHydration> _deriveHydration(
    Map<String, TerminalTab> tabs,
  ) {
    return {
      for (final entry in tabs.entries)
        entry.key: TerminalHydration(
          stage: _stageFor(entry.key),
          requestedAtMs: _frameSubscribeRequestedAtMs[entry.key],
          message: _frameStatusMessage[entry.key],
        ),
    };
  }

  // The paint decides how an outstanding pull reads. A re-pull over an engine
  // that already holds current bytes is routine — every re-establishment and
  // every focus resume issues one for every live tab — and must never present
  // as a wait or escalate to a failure.
  TerminalAttachStage _stageFor(String id) => _frameStageFor(id);

  TerminalAttachStage _frameStageFor(String id) {
    if (_missingTerminalIds.contains(id)) {
      return TerminalAttachStage.unavailable;
    }
    if (_frameEndedIds.contains(id)) return TerminalAttachStage.ended;
    if (_frameFailedIds.contains(id)) return TerminalAttachStage.failed;
    final painted = _framePaintedIds.contains(id);
    if (_frameSubscribePending.contains(id)) {
      return painted
          ? TerminalAttachStage.refreshing
          : TerminalAttachStage.awaitingScreen;
    }
    return painted ? TerminalAttachStage.painted : TerminalAttachStage.cold;
  }

  // Checkout-wide failure means ONLY "no agent:status ever arrived", i.e. there
  // are no tabs to show. One terminal that cannot be snapshotted — a PTY that
  // exited, an id the agent no longer knows — is surfaced on that terminal's own
  // pane and leaves the checkout usable.
  CheckoutAttachStatus _deriveAttach(Map<String, TerminalTab> tabs) {
    if (_checkoutAttachFailed) return CheckoutAttachStatus.failed;
    if (!_sawAgentStatus) return CheckoutAttachStatus.attaching;
    for (final entry in tabs.entries) {
      // Only a wait that something will end may hold the checkout back. A
      // terminal with no PTY behind it is snapshotted on purpose — a retained
      // transcript is always already stopped — and the agent answers a screen
      // it no longer has with no frame at all, so nothing arms a deadline for
      // it and nothing would ever clear an "attaching" taken from it.
      if (!_hasLivePty(entry.value)) continue;
      final stage = _stageFor(entry.key);
      if (stage == TerminalAttachStage.cold ||
          stage == TerminalAttachStage.awaitingScreen) {
        return CheckoutAttachStatus.attaching;
      }
    }
    return CheckoutAttachStatus.ready;
  }

  /// The only truthful synchronous read of "a send will actually leave" —
  /// `transport.currentState` stays `connected` across a relay session-down
  /// window where a send silently drops (see `AgentTransport.isEstablished`).
  /// Idempotent against its own no-op case so a poll tick that finds nothing
  /// changed costs no emission.
  void _syncInputPaused() {
    if (_disposed) return;
    final paused = !session.transport.isEstablished;
    if (paused == _inputPaused) return;
    _inputPaused = paused;
    _publishHydration();
  }

  /// Re-emit the current state so a hydration-only transition reaches the UI.
  ///
  /// Coalesced to one emission per microtask. Neither TerminalState nor
  /// TerminalTab defines `==` and `terminalStateProvider` is a StreamProvider,
  /// so every emission notifies every listener in the workspace; a burst of
  /// discovered terminals would otherwise produce one full rebuild each.
  void _publishHydration() {
    if (_disposed || _hydrationPublishScheduled) return;
    _hydrationPublishScheduled = true;
    scheduleMicrotask(() {
      _hydrationPublishScheduled = false;
      if (_disposed) return;
      _setState(_state);
    });
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    if (_disposed) return;
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    if (parsed is TerminalFrameMessage) {
      _handleTerminalFrame(parsed);
      return;
    }
    if (parsed is TerminalHistoryPageMessage) {
      _handleTerminalHistoryPage(parsed);
      return;
    }
  }

  /// Applies (or drops) one `terminal:frame` and acks it. Ack is delivery,
  /// not proof of rendering (D5): sent whenever a frame is accepted as
  /// belonging to the live attachment, whether or not its geometry let it
  /// actually paint.
  void _handleTerminalFrame(TerminalFrameMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null || tab.mode != TerminalDisplayMode.frame) return;
    final attachment = _frameAttachment[msg.terminalId];
    // D5: never apply or ack a frame for a superseded attachment -- a
    // resubscribe (reconnect, respawn, retry) can still have one of the old
    // attachment's frames in flight, addressed by a runId/attachmentId this
    // client no longer considers live.
    if (attachment == null ||
        attachment.runId != msg.runId ||
        attachment.attachmentId != msg.attachmentId) {
      return;
    }
    final highest = _frameHighestSequence[msg.terminalId] ?? 0;
    // Cumulative, and cheap to be defensive about: a sequence already
    // processed (applied or dropped) needs neither a second apply nor a
    // second ack -- "ack the highest and drop the superseded ones unparsed".
    if (msg.sequence <= highest) return;
    _frameHighestSequence[msg.terminalId] = msg.sequence;
    // Every frame restates the archive boundary, and it is true whether or not
    // this screen's geometry lets it paint -- a deferred frame's rows scrolled
    // off just the same.
    tab.history.applyBoundary(msg.history);
    if (msg.cols != tab.cols || msg.rows != tab.rows) {
      final tabs = Map<String, TerminalTab>.from(_state.tabs);
      tabs[msg.terminalId] = tab.copyWith(cols: msg.cols, rows: msg.rows);
      _setState(_state.copyWith(tabs: tabs));
    }
    _paintFrame(tab, msg);
    _ackFrame(
      msg.terminalId,
      runId: msg.runId,
      attachmentId: msg.attachmentId,
      sequence: msg.sequence,
    );
  }

  /// Writes one frame into [tab]'s engine and moves this terminal's frame-mode
  /// hydration on.
  void _paintFrame(TerminalTab tab, TerminalFrameMessage msg) {
    // A frame is this mode's live output: it is the screen that answers what
    // the user typed, so it closes the echo timer for the same reason the raw
    // byte path does. Without this the perf harness reads zero echo latency in
    // frame mode and leaves every sample pending forever.
    perfRecorder.noteTerminalOutput(
      projectId: session.projectId,
      checkoutId: checkoutId,
      terminalId: msg.terminalId,
    );
    tab.ghostty.resize(cols: msg.cols, rows: msg.rows);
    tab.ghostty.appendOutputBytes(utf8.encode(msg.ansi));
    // D10: every cell a live selection's row/col anchors pointed at was
    // just replaced wholesale. See TerminalTab.replaceEpoch's doc comment.
    tab.replaceEpoch.value++;
    final firstPaint = _framePaintedIds.add(msg.terminalId);
    final recovered = _frameFailedIds.remove(msg.terminalId);
    if (recovered) _frameStatusMessage.remove(msg.terminalId);
    // Gated, not unconditional: a live stream applies up to
    // `TERMINAL_FRAME_INTERVAL_MS` frames a second, and _publishHydration
    // re-emits the whole TerminalState — one full workspace rebuild per frame.
    if (firstPaint || recovered) _publishHydration();
  }

  void _ackFrame(
    String terminalId, {
    required String runId,
    required String attachmentId,
    required int sequence,
  }) {
    detached(
      'terminal',
      'acknowledge consumed frame',
      () => session.sendForCheckout(
        checkoutId,
        createAbMessage('terminal:ack', {
          'terminalId': terminalId,
          'runId': runId,
          'attachmentId': attachmentId,
          'sequence': sequence,
        }),
      ),
    );
  }

  /// Reattaches the terminal with a fresh viewer attachment.
  void _attachTerminal(String terminalId) {
    if (_missingTerminalIds.contains(terminalId) ||
        _pendingTerminalIds.contains(terminalId)) {
      return;
    }
    if (!_state.tabs.containsKey(terminalId)) return;
    _unsubscribeFrame(terminalId);
    _resetFrameTracking(terminalId);
    _subscribeFrame(terminalId);
  }

  /// Drops everything this client believes about [terminalId]'s frame-mode
  /// attachment, short of whether it has ever painted (see
  /// [_framePaintedIds]'s own doc comment for why that survives this).
  void _resetFrameTracking(String terminalId) {
    _endedHistoryAttachment.remove(terminalId);
    _pendingExitCodes.remove(terminalId);
    _historyRequestDeadlines.remove(terminalId)?.cancel();
    _state.tabs[terminalId]?.history.cancelRequest();
    _frameAttachment.remove(terminalId);
    _clearPendingSubscribe(terminalId);
    _frameHighestSequence.remove(terminalId);
    _frameFailedIds.remove(terminalId);
    _frameEndedIds.remove(terminalId);
    _frameStatusMessage.remove(terminalId);
  }

  /// Drops the archive [terminalId] was paging, the bound on its outstanding
  /// request included.
  ///
  /// The archive is addressed by row ids scoped to one run and reachable only
  /// through a live frame attachment, so every exit from frame mode -- a
  /// respawn, a re-attach, a demotion -- leaves every loaded row and the
  /// cursor derived from them naming ids the agent will not serve. Routed
  /// through one call so that holds of the EXITS themselves, rather than of
  /// the order two unrelated helpers happen to run in at one call site.
  void _discardFrameArchive(String terminalId) {
    _historyRequestDeadlines.remove(terminalId)?.cancel();
    _state.tabs[terminalId]?.history.reset();
  }

  /// Retires the bookkeeping for an outstanding `terminal:subscribe`, its
  /// bound included.
  void _clearPendingSubscribe(String terminalId) {
    _frameSubscribeDeadlines.remove(terminalId)?.cancel();
    _frameSubscribePending.remove(terminalId);
    _frameSubscribeRequestId.remove(terminalId);
    _frameSubscribeRequestedAtMs.remove(terminalId);
  }

  /// Sends `terminal:subscribe` for [terminalId] at the highest frame
  /// protocol version this client can render, and bounds the wait.
  void _subscribeFrame(String terminalId) {
    final requestId = const Uuid().v4();
    _clearPendingSubscribe(terminalId);
    _frameSubscribeRequestId[terminalId] = requestId;
    _frameSubscribePending.add(terminalId);
    _frameSubscribeRequestedAtMs[terminalId] =
        DateTime.now().millisecondsSinceEpoch;
    session.sendForCheckout(
      checkoutId,
      createAbMessage('terminal:subscribe', {
        'terminalId': terminalId,
        'version': kTerminalFrameProtocolVersion,
        'requestId': requestId,
      }),
    );
    _frameSubscribeDeadlines[terminalId] = Timer(snapshotAttachTimeout, () {
      if (_disposed) return;
      _frameSubscribeDeadlines.remove(terminalId);
      _failFrameSubscribe(terminalId);
    });
    // The subscribe IS this terminal's attach from here on, so the stage it
    // moves to has to reach the pane — without this a re-subscribe over an
    // already-painted frame tab never republishes, and the UI keeps rendering
    // the stage from before it (see [_frameSubscribeDeadlines]).
    _publishHydration();
  }

  /// Bounds an unanswered subscribe without changing the display protocol.
  void _failFrameSubscribe(String terminalId) {
    _clearPendingSubscribe(terminalId);
    _frameFailedIds.add(terminalId);
    _frameStatusMessage[terminalId] =
        'Terminal connection failed. Reconnect or upgrade the bridge.';
    _publishHydration();
  }

  /// Best-effort `terminal:unsubscribe` for whatever live frame attachment
  /// [terminalId] holds. Fire-and-forget like every other outbound verb here
  /// -- the bridge's own ACK_TIMEOUT and run-exit paths already retire an
  /// attachment nobody explicitly released, so a dropped send here costs
  /// nothing but a slightly later bridge-side cleanup.
  void _unsubscribeFrame(String terminalId) {
    final attachment = _frameAttachment.remove(terminalId);
    if (attachment == null) return;
    session.sendForCheckout(
      checkoutId,
      createAbMessage('terminal:unsubscribe', {
        'terminalId': terminalId,
        'runId': attachment.runId,
        'attachmentId': attachment.attachmentId,
      }),
    );
  }

  bool requestTerminalHistoryPage(String terminalId) {
    if (_disposed) return false;
    final tab = _state.tabs[terminalId];
    if (tab == null || tab.mode != TerminalDisplayMode.frame) return false;
    final attachment =
        _frameAttachment[terminalId] ?? _endedHistoryAttachment[terminalId];
    if (attachment == null) return false;
    final model = tab.history;
    if (!model.canLoadMore) return false;
    final boundary = model.boundary;
    final cursor = model.cursor;
    if (boundary == null || cursor == null) return false;
    final requestId = const Uuid().v4();
    if (!model.markRequested(requestId)) return false;
    // Armed BEFORE the send, never after: the model reads as outstanding from
    // the line above, so a send that throws at the call would otherwise leave
    // the pane waiting on a bound that was never armed.
    _historyRequestDeadlines[terminalId]?.cancel();
    _historyRequestDeadlines[terminalId] = Timer(snapshotAttachTimeout, () {
      if (_disposed) return;
      _historyRequestDeadlines.remove(terminalId);
      // Addressed to the MODEL, not to the terminal: the live screen is
      // unaffected by a page that never came, and demoting a painting
      // terminal because its scrollback stalled would trade the thing that
      // works for the thing that does not.
      //
      // Named, because this map is keyed by terminal while the model is the
      // authority on which request is outstanding: the model can abandon the
      // request behind this bound without the bound's knowledge (an epoch
      // turnover discards the very rows its answer would be addressed by), and
      // a timeout reported for a request the client itself gave up on is a
      // banner nothing on screen explains.
      _state.tabs[terminalId]?.history.noteRequestFailed(
        "The agent didn't answer this scrollback request.",
        requestId: requestId,
      );
    });
    session.sendForCheckout(
      checkoutId,
      createAbMessage('terminal:history:request', {
        'terminalId': terminalId,
        'runId': attachment.runId,
        'attachmentId': attachment.attachmentId,
        'requestId': requestId,
        'epoch': boundary.epoch,
        'beforeRowId': cursor,
      }),
    );
    return true;
  }

  /// One answered `terminal:history:request`.
  void _handleTerminalHistoryPage(TerminalHistoryPageMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null || tab.mode != TerminalDisplayMode.frame) return;
    final attachment =
        _frameAttachment[msg.terminalId] ??
        _endedHistoryAttachment[msg.terminalId];
    // D5, applied to the archive: a page answering an attachment this client
    // has since replaced describes a run it is no longer reading, and its row
    // ids belong to that run's epoch counter, not this one's.
    if (attachment == null ||
        attachment.runId != msg.runId ||
        attachment.attachmentId != msg.attachmentId) {
      return;
    }
    // The model does its own correlation on requestId -- a late answer to a
    // superseded request names this same attachment and must not be inserted.
    // The bound is retired on its verdict and never ahead of it: this map is
    // keyed by terminal alone, so retiring it for a loser would leave the
    // request that IS outstanding with nothing left to end it, and the pane
    // loading for good.
    if (tab.history.applyPage(msg)) {
      _historyRequestDeadlines.remove(msg.terminalId)?.cancel();
    }
  }

  /// Re-drives ONE terminal's screen pull.
  ///
  /// Deliberately not `StreamTransport.refreshSnapshot()`, which re-drives every
  /// hydrator on the stream — including a per-checkout `tree:full` for every
  /// checkout — and would turn a user's tap into a multi-megabyte fan-out.
  void retryAttach(String terminalId) {
    if (_disposed || !_state.tabs.containsKey(terminalId)) return;
    _attachTerminal(terminalId);
  }

  /// Re-drives the whole checkout's attach after its checkout-wide verdict
  /// came back failed.
  ///
  /// Reached only from an explicit tap on a workspace whose terminals never
  /// arrived, because it is the expensive lever: [retryAttach] re-asks for ONE
  /// terminal's screen, and with no tabs at all it has no id to name. This
  /// re-asks for the frame the tabs themselves are built from.
  ///
  /// The bound is re-armed only over a live subscription, the same rule
  /// [_rehydrateTerminals] follows. A bound exists to tell a surface that is
  /// waiting that its wait ended badly, so a service nobody watches must not
  /// hold a live timer for the length of the timeout — and this is a public
  /// method, so the mounted surface the tap usually comes from is not proof
  /// that anything is reading.
  Future<void> retryCheckoutAttach() async {
    if (_disposed) return;
    _checkoutAttachFailed = false;
    if (_stateController.hasListener) _armCheckoutAttachDeadline();
    _publishHydration();
    final transport = session.transport;
    if (transport is StreamTransport) {
      await transport.refreshDurableState();
      return;
    }
    // No relay stream to re-pull on: re-running the hydrator is the only
    // re-drive this transport has, and registering under the live key runs it
    // now rather than adding a second one. Deliberately the key [activate]
    // registers, not a private one, so a checkout that is retried and then
    // loses focus has its heavy hydrator taken away again by [deactivate]
    // rather than kept alive behind the activation gate's back.
    await session.hydrateCheckout(
      checkoutId,
      _frameHydratorKey,
      _rehydrateTerminals,
    );
  }

  // --- Message dispatch ---

  void _onStatusJson(Map<String, dynamic> json) {
    if (_disposed) return;
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    _handle(parsed);
  }

  void _handle(Object message) {
    // terminal:output is heavy-tier and dispatched via _onHeavyJson; never
    // reaches this status-tier handler. agent:hello is consumed by
    // ProjectStatusNotifier, not here.
    if (message is TerminalStartedMessage) {
      _handleTerminalStarted(message);
    } else if (message is TerminalExitedMessage) {
      _handleTerminalExited(message);
    } else if (message is AgentStatusMessage) {
      _handleAgentStatus(message);
    } else if (message is GitBranchesMessage) {
      _handleGitBranches(message);
    } else if (message is GitCheckoutResultMessage) {
      _handleGitCheckoutResult(message);
    } else if (message is TerminalNotificationMessage) {
      _handleNotification(message);
    } else if (message is TerminalBellMessage) {
      if (_frameAttachment[message.terminalId]?.runId == message.runId &&
          _state.tabs[message.terminalId]?.ghostty.isFocused == true) {
        ringTerminalBell();
      }
    } else if (message is NotificationPushMessage) {
      _pushController.add(message);
    } else if (message is TerminalSizeMessage) {
      _handleTerminalSize(message);
    } else if (message is TerminalSubscribedMessage) {
      _handleFrameSubscribed(message);
    } else if (message is TerminalDisplayStatusMessage) {
      _handleFrameDisplayStatus(message);
    }
  }

  /// Accepts a `terminal:subscribe` this client sent, promoting the terminal
  /// to frame mode.
  void _handleFrameSubscribed(TerminalSubscribedMessage msg) {
    final terminalId = msg.terminalId;
    // A late reply to a subscribe this terminal has since superseded (a
    // fresh reconnect, respawn, or retry already sent another one) must
    // never resurrect the attempt it answers.
    if (_frameSubscribeRequestId[terminalId] != msg.requestId) return;
    _clearPendingSubscribe(terminalId);
    final tab = _state.tabs[terminalId];
    if (tab == null) return; // Tab gone since we asked; nothing to attach.
    if (_historyRunId[terminalId] != msg.runId) {
      _discardFrameArchive(terminalId);
      _historyRunId[terminalId] = msg.runId;
    }
    _frameAttachment[terminalId] = (
      runId: msg.runId,
      attachmentId: msg.attachmentId,
    );
    _frameHighestSequence[terminalId] = 0;
    _frameFailedIds.remove(terminalId);
    _frameEndedIds.remove(terminalId);
    _frameStatusMessage.remove(terminalId);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[terminalId] = tab.copyWith(mode: TerminalDisplayMode.frame);
    _setState(_state.copyWith(tabs: tabs));
  }

  /// Handles a subscribe refusal or a live attachment's status.
  void _handleFrameDisplayStatus(TerminalDisplayStatusMessage msg) {
    final terminalId = msg.terminalId;
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    final requestId = msg.requestId;
    // A notice naming a request this client still has outstanding is answering
    // the SUBSCRIBE, and by construction carries no attachment to key on --
    // Refusals carry only the terminal and requestId.
    // Resolved FIRST and regardless of mode, or a tab already committed to
    // frame mode drops the only word it will ever get that its re-subscribe
    // was refused, and then waits out the bound instead.
    if (requestId != null &&
        _frameSubscribeRequestId[terminalId] == requestId) {
      _clearPendingSubscribe(terminalId);
      if (msg.code == 'UNKNOWN_TERMINAL') {
        _handleMissingTerminal(terminalId, tab);
        return;
      }
      _frameFailedIds.add(terminalId);
      _frameStatusMessage[terminalId] = msg.message;
      _publishHydration();
      return;
    }
    // Request replies cannot act on an attachment accepted by a newer attempt.
    if (requestId != null || msg.code == 'UNKNOWN_TERMINAL') return;
    if (tab.mode != TerminalDisplayMode.frame) return;
    final attachment = _frameAttachment[terminalId];
    // Only the LIVE attachment's own notice may act on it -- a superseded
    // attachment's late ENDED/failure racing a fresh resubscribe must never
    // touch the one that replaced it. A notice carrying no attachmentId
    // addresses the terminal itself and is taken at face value (D7: an
    // unrecognized notice must surface, never be dropped).
    if (attachment == null) return;
    if (msg.attachmentId != null &&
        msg.attachmentId != attachment.attachmentId) {
      return;
    }
    if (msg.code == 'HISTORY_DISABLED') {
      // Names exactly what it broke. The live display is unaffected, and
      // badging the whole terminal failed for a scrollback problem would
      // hide a pane that is still painting. No bridge emits this today; the
      // code is in the wire enum, so the app answers it correctly rather than
      // falling through to the generic failure below.
      _historyRequestDeadlines.remove(terminalId)?.cancel();
      // Closes paging as well as recording the sentence: the refusal is
      // addressed at the RUN, so the next scroll tick asking again earns the
      // same refusal and a bound that expires over this message.
      tab.history.noteHistoryUnavailable(msg.message);
      return;
    }
    _frameStatusMessage[terminalId] = msg.message;
    if (msg.code == 'ENDED') {
      // D7: lifecycle, not failure. The only notice that definitionally ends
      // the attachment, so the only one that drops it here.
      _endedHistoryAttachment[terminalId] = attachment;
      _frameAttachment.remove(terminalId);
      _frameEndedIds.add(terminalId);
      final exitCode = _pendingExitCodes.remove(terminalId) ?? msg.exitCode;
      _completeTerminal(terminalId, exitCode);
    } else {
      _frameFailedIds.add(terminalId);
    }
    _publishHydration();
  }

  void _handleMissingTerminal(String terminalId, TerminalTab tab) {
    _missingTerminalIds.add(terminalId);
    _resizeTimers.remove(terminalId)?.cancel();
    _resizeBaseDrivers.remove(terminalId);
    tab.ghostty.setSessionRunning(false);
    final retained =
        _framePaintedIds.contains(terminalId) ||
        tab.history.rows.isNotEmpty ||
        tab.history.boundary != null;
    if (!retained && !_pendingTerminalIds.contains(terminalId)) {
      _removeLocalTerminal(terminalId);
      return;
    }
    _frameStatusMessage[terminalId] = 'Terminal no longer available';
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[terminalId] = tab.copyWith(
      sessionState: _pendingTerminalIds.contains(terminalId)
          ? TerminalSessionState.starting
          : TerminalSessionState.exited,
    );
    _setState(_state.copyWith(tabs: tabs));
  }

  Future<void> _send(Map<String, dynamic> message) async {
    await session.sendForCheckout(checkoutId, message);
  }

  // --- Message handlers ---

  void _handleTerminalStarted(TerminalStartedMessage msg) {
    _missingTerminalIds.remove(msg.terminalId);
    _pendingExitCodes.remove(msg.terminalId);
    _discardFrameArchive(msg.terminalId);
    _historyRunId.remove(msg.terminalId);
    if (_canceledPendingTerminalIds.contains(msg.terminalId)) {
      _settlePendingTerminal(msg.terminalId);
      requestStop(msg.terminalId);
      return;
    }
    // Authoritative revival: agent says this id is running again, so any
    // prior local delete-suppression for it is stale.
    _deletedTerminalIds.remove(msg.terminalId);
    _settlePendingTerminal(msg.terminalId);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    final existing = tabs[msg.terminalId];

    if (existing != null) {
      existing.ghostty.setSessionRunning(true);
      // A start on an id the app already holds is a RESPAWN, and the new PTY
      // carries whatever `TerminalManager.lastDriverGeometry` held — the size
      // of whichever terminal resized last in that bridge process, or 80x24 on
      // a bridge that has never seen a resize — not the one the driver sent the
      // dead one. The driver gates its re-sends on the last size it believes
      // the PTY has, so without this bump it computes the same grid, sees no
      // change, and leaves a wide panel rendering a narrower process.
      tabs[msg.terminalId] = existing.copyWith(
        sessionState: TerminalSessionState.running,
        shell: msg.shell,
        cols: msg.cols,
        rows: msg.rows,
        clearExitCode: true,
        type: msg.terminalType,
        sizeEpoch: existing.sizeEpoch + 1,
        mode: TerminalDisplayMode.frame,
      );
    } else {
      final tab = _createTab(
        terminalId: msg.terminalId,
        name: msg.terminalId,
        running: true,
        shell: msg.shell,
        cols: msg.cols,
        rows: msg.rows,
        type: msg.terminalType,
      );
      tabs[msg.terminalId] = tab;
    }

    final activeId = _state.activeTerminalId ?? msg.terminalId;
    _setState(_state.copyWith(tabs: tabs, activeTerminalId: activeId));
    // A same-id respawn requires a fresh attachment even if its exit was lost.
    _attachTerminal(msg.terminalId);
  }

  void _handleTerminalSize(TerminalSizeMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;
    final clientId = _clientId;
    final pendingBase = _resizeBaseDrivers[msg.terminalId];
    final stalePending =
        clientId == null ||
        (msg.driverClientId != clientId &&
            (pendingBase == null || msg.driverClientId != pendingBase));
    var dropped = false;
    if (stalePending) {
      final queued = _resizeTimers.remove(msg.terminalId);
      queued?.cancel();
      dropped = queued != null;
      _resizeBaseDrivers.remove(msg.terminalId);
    }
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[msg.terminalId] = tab.copyWith(
      cols: _framePaintedIds.contains(msg.terminalId) ? null : msg.cols,
      rows: _framePaintedIds.contains(msg.terminalId) ? null : msg.rows,
      driverClientId: msg.driverClientId,
      // The caller booked that size the moment `sendResize` queued it, so a
      // frame cancelled here would otherwise leave its gate shut against a
      // geometry the PTY never received.
      sizeEpoch: dropped ? tab.sizeEpoch + 1 : null,
    );
    _setState(_state.copyWith(tabs: tabs));
  }

  void _handleTerminalExited(TerminalExitedMessage msg) {
    _settlePendingTerminal(msg.terminalId);
    _canceledPendingTerminalIds.remove(msg.terminalId);
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;

    if (_frameAttachment.containsKey(msg.terminalId) &&
        !_frameEndedIds.contains(msg.terminalId)) {
      tab.ghostty.setSessionRunning(false);
      _pendingExitCodes[msg.terminalId] = msg.exitCode;
      return;
    }
    _completeTerminal(msg.terminalId, msg.exitCode);
  }

  void _completeTerminal(String terminalId, int? exitCode) {
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    tab.ghostty.setSessionRunning(false);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[terminalId] = tab.copyWith(
      sessionState: TerminalSessionState.exited,
      exitCode: exitCode,
    );
    _setState(_state.copyWith(tabs: tabs));
  }

  void _handleAgentStatus(AgentStatusMessage msg) {
    _sawAgentStatus = true;
    // A checkout that was merely slow is not a broken one. The deadline fired
    // before the frame arrived; the frame arriving is the answer.
    _checkoutAttachFailed = false;
    _checkoutAttachDeadline?.cancel();
    _checkoutAttachDeadline = null;
    // Services list is now mirrored into ProjectStatus by ProjectStatusNotifier;
    // consumers read it from projectStatusProvider.
    final newTabs = <String, TerminalTab>{};
    final discovered = <String>[];

    for (final info in msg.terminals) {
      if (_missingTerminalIds.contains(info.terminalId)) {
        final retained = _state.tabs[info.terminalId];
        if (retained != null) newTabs[info.terminalId] = retained;
        continue;
      }
      if (_canceledPendingTerminalIds.contains(info.terminalId)) {
        if (info.running) {
          requestStop(info.terminalId);
        } else {
          _canceledPendingTerminalIds.remove(info.terminalId);
        }
        continue;
      }
      // Honor local deletes: skip stopped sessions the user removed. If the
      // agent reports the session running again (e.g. user revived via Start),
      // drop it from the deleted set and re-surface the tab.
      if (_deletedTerminalIds.contains(info.terminalId)) {
        if (info.running) {
          _deletedTerminalIds.remove(info.terminalId);
        } else {
          continue;
        }
      }
      if (_pendingTerminalIds.contains(info.terminalId) && !info.running) {
        final pending = _state.tabs[info.terminalId];
        if (pending != null) newTabs[info.terminalId] = pending;
        continue;
      }
      if (info.running) _settlePendingTerminal(info.terminalId);
      final existing = _state.tabs[info.terminalId];
      if (existing != null) {
        existing.ghostty.setSessionRunning(info.running);
        // The same respawn `_handleTerminalStarted` bumps on, seen through the
        // status frame instead: a client that missed the live started frame
        // builds its tabs from this replay (see the discovery pull below), so
        // without the bump here the driver's booking survives a PTY that never
        // received it — on the one path a relay app actually uses.
        final respawned =
            info.running &&
            existing.sessionState == TerminalSessionState.exited;
        if (respawned) {
          _discardFrameArchive(info.terminalId);
          _historyRunId.remove(info.terminalId);
          _resetFrameTracking(info.terminalId);
        }
        final awaitingFinal =
            !info.running &&
            _frameAttachment.containsKey(info.terminalId) &&
            !_frameEndedIds.contains(info.terminalId);
        final updated = existing.copyWith(
          name: info.name,
          sessionState: awaitingFinal
              ? existing.sessionState
              : info.running
              ? TerminalSessionState.running
              : TerminalSessionState.exited,
          shell: info.shell,
          cols: !respawned && _framePaintedIds.contains(info.terminalId)
              ? null
              : info.cols,
          rows: !respawned && _framePaintedIds.contains(info.terminalId)
              ? null
              : info.rows,
          type: info.type,
          sizeEpoch: respawned ? existing.sizeEpoch + 1 : null,
          mode: respawned ? TerminalDisplayMode.frame : null,
        );
        newTabs[info.terminalId] = info.driverClientId == null
            ? updated.copyWith(clearDriverClientId: true)
            : updated.copyWith(driverClientId: info.driverClientId);
      } else {
        newTabs[info.terminalId] = _createTab(
          terminalId: info.terminalId,
          name: info.name,
          running: info.running,
          shell: info.shell,
          cols: info.cols,
          rows: info.rows,
          type: info.type,
          driverClientId: info.driverClientId,
        );
        // Only for a tab this frame is the FIRST word of, unlike
        // _handleTerminalStarted's unconditional pull: a relay app builds its
        // tabs from the replayed agent:status rather than from the live started
        // frame it never receives, so without this the tab arrives and stays
        // blank. Requested after _setState below, not here — _applySnapshot
        // drops a reply for a tab it cannot find.
        // Not gated on `running`: a terminal whose scrollback the agent RETAINS
        // past its own exit — a `worktree.setup` transcript, which the "View
        // setup log" action reads after the run — is always stopped by the
        // time a client that missed it first sees it, and this is the only pull
        // that would ever reach it.
        discovered.add(info.terminalId);
      }
    }

    // A status snapshot can have been produced before a just-sent start was
    // applied. Keep optimistic tabs until the terminal's own started/exited
    // event resolves the request, otherwise the newly-opened detail view would
    // briefly lose its tab and navigate back to the list.
    for (final terminalId in _pendingTerminalIds) {
      final pending = _state.tabs[terminalId];
      if (pending != null) newTabs.putIfAbsent(terminalId, () => pending);
    }
    for (final terminalId in _missingTerminalIds) {
      final retained = _state.tabs[terminalId];
      if (retained != null) newTabs.putIfAbsent(terminalId, () => retained);
    }

    var activeId = _state.activeTerminalId;
    if (activeId == null || !newTabs.containsKey(activeId)) {
      activeId = newTabs.isNotEmpty ? newTabs.keys.first : null;
    }

    _setState(
      TerminalState(
        tabs: newTabs,
        activeTerminalId: activeId,
        projectId: msg.projectId ?? _state.projectId,
        agentInfo: msg.agent ?? _state.agentInfo,
        layout: msg.layout ?? _state.layout,
        commands: msg.commands ?? _state.commands,
        gitBranch: msg.git?.branch ?? _state.gitBranch,
        // Taken from the same frame as the branch, never carried: a status with
        // no git block means the checkout stopped being a repository, and
        // keeping the previous counts beside a cleared branch is worse than 0.
        gitAhead: msg.git?.ahead ?? 0,
        gitBehind: msg.git?.behind ?? 0,
        // Carried, not defaulted: a status frame says nothing about an
        // in-flight branch list or a checkout error, and rebuilding without
        // them empties an open branch picker and swallows the failure toast.
        gitBranches: _state.gitBranches,
        gitBranchesLoading: _state.gitBranchesLoading,
        gitBranchesError: _state.gitBranchesError,
        gitCheckoutError: _state.gitCheckoutError,
        needsFirstRun: msg.needsFirstRun,
      ),
    );
    // A tab can leave the status without ever exiting — a service dropped
    // from antgrid.yaml, a slot renamed. Its cutoff would otherwise outlive it
    // and filter the first bytes of whatever later claims the same id.
    for (final terminalId in discovered) {
      // Only the tabs that survived the rebuild: one dropped along the way has
      // nowhere for the reply to land.
      if (newTabs.containsKey(terminalId)) _attachTerminal(terminalId);
    }
  }

  TerminalTab _createTab({
    required String terminalId,
    required String name,
    required bool running,
    String? shell,
    int? cols,
    int? rows,
    String? type,
    String? driverClientId,
    TerminalSessionState? sessionState,
  }) {
    _framePaintedIds.remove(terminalId);
    _resetFrameTracking(terminalId);
    final tab = TerminalTab(
      terminalId: terminalId,
      name: name,
      sessionState:
          sessionState ??
          (running
              ? TerminalSessionState.running
              : TerminalSessionState.exited),
      shell: shell,
      cols: cols ?? 80,
      rows: rows ?? 24,
      type: type,
      driverClientId: driverClientId,
    );

    // Wire the Ghostty controller's user-input path back to the agent.
    //
    // The bridge fronts the PTY and answers the guest's capability queries
    // itself (`vt-capability-responder.ts`) — it has to, since a session with
    // no viewer attached has no engine to answer for it. The engine answers
    // DA1/DA2/DA3/XTVERSION/DSR/DECRQM/kitty on its own too, so forwarding
    // those made the guest see two answers to one question, ours a relay
    // round-trip late. Terminal query protocols are FIFO, so the late one is
    // matched against whichever query is pending by the time it lands.
    tab.ghostty.attachExternalTransport(
      writeBytes: (bytes) {
        // sendInput's refusal is surfaced as pane chrome (inputPaused, the
        // hydration strip), not through this return value: `false` here
        // becomes KeyEventResult.ignored, so the keystroke would escape into
        // the app's global shortcut layer, and the IME/soft-keyboard path
        // discards the bool entirely — the platform this bug bites hardest.
        sendInput(terminalId, utf8.decode(bytes, allowMalformed: true));
        return true;
      },
      onResize: null,
      forwardGuestQueryReplies: false,
    );
    final ghostty = tab.ghostty;
    ghostty.onBellData = () {
      if (!ghostty.isFocused) return;
      ringTerminalBell();
    };
    tab.ghostty.setSessionRunning(running);

    // Agent terminals start "blurred" so a background/never-viewed agent can
    // still raise notifications (TUIs like opencode treat focus-unknown as
    // do-not-notify). The engine latches this until the agent enables DEC 1004;
    // the focus coordinator overrides to focused only while the user is viewing.
    if (tab.isAgent) {
      tab.ghostty.setFocused(false);
    }

    return tab;
  }

  // --- Outbound messages ---

  /// Sends a keystroke, reporting whether the frame actually left.
  ///
  /// False means the transport could not carry it and NOTHING was buffered.
  /// A delayed keystroke replayed against a prompt that has moved on can
  /// confirm something the user never saw, so a refusal is dropped, not
  /// queued, and the pane says so instead. Callers that report success to the
  /// user must honour this.
  bool sendInput(String terminalId, String data) {
    if (_missingTerminalIds.contains(terminalId)) return false;
    if (!session.transport.isEstablished) {
      _syncInputPaused();
      return false;
    }
    // terminal_used = the user actually typed into / drove a terminal. Fire on
    // input, not on terminal:started — the latter replays automatically on
    // every session re-warm, which has nothing to do with user engagement.
    if (!_trackedUse) {
      _trackedUse = true;
      session.analytics?.track(AnalyticsEvents.terminalUsed);
    }
    perfRecorder.noteTerminalInput(
      projectId: session.projectId,
      checkoutId: checkoutId,
      terminalId: terminalId,
    );
    _send(
      createAbMessage('terminal:input', {
        'terminalId': terminalId,
        'data': data,
      }),
    );
    return true;
  }

  /// Forwards to the running agent tab, reporting the same refusal
  /// [sendInput] does — false both when there is no running agent tab and
  /// when the transport refused the send.
  bool sendToAgentTerminal(String text) {
    final agentTabs = _state.tabs.values.where(
      (tab) => tab.isAgent && tab.sessionState == TerminalSessionState.running,
    );
    if (agentTabs.isEmpty) return false;
    // Terminals submit on CR, not bare LF (see `_sanitizePaste` in
    // terminal_view_wrapper.dart) — normalize embedded newlines and append a
    // trailing CR. Unlike a clipboard paste, this is an explicit "Send"
    // action the user already confirmed in a dialog, so it must land in the
    // agent outright rather than sit in the prompt waiting on a manual Enter.
    final normalized = text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
    final data = normalized.endsWith('\r') ? normalized : '$normalized\r';
    return sendInput(agentTabs.first.terminalId, data);
  }

  /// Queues a debounced `terminal:resize`, reporting whether it was QUEUED.
  ///
  /// False means nothing was queued and nothing ever will be for this call —
  /// the per-install client id has not resolved yet (see
  /// `terminalStateProvider`, which pushes it in), or the service is gone. The
  /// caller must not record the size as sent: the wrapper gates re-sends on the
  /// last size it believes the PTY has, so a drop booked as a send strands the
  /// PTY at the previous geometry until the panel happens to change size again.
  ///
  /// True is not a delivery receipt. The 100ms debounce this arms can still be
  /// cancelled (`_handleTerminalSize`, `deleteTerminal`) or discarded by its own
  /// driver guard, and every such path owes the caller an `_invalidateGeometry`
  /// — that bump is what retires a booking the wire never honoured.
  bool sendResize(
    String terminalId,
    int cols,
    int rows, {
    String? baseDriverClientId,
  }) {
    final clientId = _clientId;
    if (_disposed || clientId == null) return false;
    _resizeTimers[terminalId]?.cancel();
    _resizeBaseDrivers[terminalId] = baseDriverClientId;
    _resizeTimers[terminalId] = Timer(const Duration(milliseconds: 100), () {
      _resizeTimers.remove(terminalId);
      _resizeBaseDrivers.remove(terminalId);
      final currentDriver = _state.tabs[terminalId]?.driverClientId;
      if (baseDriverClientId != null &&
          currentDriver != null &&
          currentDriver != baseDriverClientId &&
          currentDriver != clientId) {
        // Discarded, not sent — and the caller booked this size when the queue
        // accepted it, so hand back the invalidation edge that reopens its gate.
        _invalidateGeometry(terminalId);
        return;
      }
      _send(
        createAbMessage('terminal:resize', {
          'terminalId': terminalId,
          'cols': cols,
          'rows': rows,
          'clientId': clientId,
          'baseDriverClientId': ?baseDriverClientId,
        }),
      );
    });
    return true;
  }

  void requestStart(
    String terminalId, {
    String? name,
    String? command,
    List<String>? args,
    String? cwd,
    Map<String, String>? env,
  }) {
    final tab = _state.tabs[terminalId];
    if (tab != null) {
      // A reply to the previous run must not delete a start awaiting admission.
      _clearPendingSubscribe(terminalId);
      _pendingTerminalIds.add(terminalId);
      _pendingTerminalTimers.remove(terminalId)?.cancel();
      _pendingTerminalTimers[terminalId] = Timer(
        terminalStartTimeout,
        () => _expirePendingTerminal(terminalId),
      );
      final tabs = Map<String, TerminalTab>.from(_state.tabs);
      tabs[terminalId] = tab.copyWith(
        sessionState: TerminalSessionState.starting,
        clearExitCode: true,
      );
      _setState(_state.copyWith(tabs: tabs));
    }
    _send(
      createAbMessage('terminal:start', {
        'terminalId': terminalId,
        'name': ?name,
        'command': ?command,
        'args': ?args,
        'cwd': ?cwd,
        'env': ?env,
      }),
    );
  }

  /// Adds a user-created shell to local state before asking the agent to start
  /// it, allowing its detail view to open in the same interaction.
  void createAdHocTerminal(String terminalId, {required String name}) {
    _deletedTerminalIds.remove(terminalId);
    _canceledPendingTerminalIds.remove(terminalId);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    final existing = tabs[terminalId];
    tabs[terminalId] = existing == null
        ? _createTab(
            terminalId: terminalId,
            name: name,
            running: false,
            sessionState: TerminalSessionState.starting,
          )
        : existing.copyWith(
            name: name,
            sessionState: TerminalSessionState.starting,
            clearExitCode: true,
          );
    _setState(_state.copyWith(tabs: tabs, activeTerminalId: terminalId));
    requestStart(terminalId, name: name);
  }

  void _settlePendingTerminal(String terminalId) {
    _pendingTerminalIds.remove(terminalId);
    _pendingTerminalTimers.remove(terminalId)?.cancel();
  }

  void _expirePendingTerminal(String terminalId) {
    _pendingTerminalTimers.remove(terminalId);
    if (!_pendingTerminalIds.remove(terminalId)) return;
    final tab = _state.tabs[terminalId];
    if (tab == null || tab.sessionState != TerminalSessionState.starting) {
      return;
    }
    tab.ghostty.setSessionRunning(false);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[terminalId] = tab.copyWith(sessionState: TerminalSessionState.exited);
    _setState(_state.copyWith(tabs: tabs));
  }

  void requestStop(String terminalId) {
    _send(createAbMessage('terminal:stop', {'terminalId': terminalId}));
  }

  /// Stops the terminal on the agent and disposes the local Ghostty controller
  /// so its scrollback buffer is freed. The tab is removed locally and the id
  /// is added to `_deletedTerminalIds`, so subsequent `agent:status` snapshots
  /// won't re-surface it. The suppression is lifted automatically if the agent
  /// reports the session running again (via `terminal:started` or `running:
  /// true` in a status snapshot), at which point a fresh controller is built.
  void deleteTerminal(String terminalId) {
    _discardFrameArchive(terminalId);
    _historyRunId.remove(terminalId);
    requestStop(terminalId);
    _deletedTerminalIds.add(terminalId);
    if (_pendingTerminalIds.contains(terminalId)) {
      _canceledPendingTerminalIds.add(terminalId);
    }
    _settlePendingTerminal(terminalId);
    _missingTerminalIds.remove(terminalId);
    _removeLocalTerminal(terminalId);
  }

  void _removeLocalTerminal(String terminalId) {
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    _resizeTimers.remove(terminalId)?.cancel();
    _resizeBaseDrivers.remove(terminalId);
    _unsubscribeFrame(terminalId);
    _framePaintedIds.remove(terminalId);
    _resetFrameTracking(terminalId);
    // `replaceEpoch` and `history` are deliberately NOT disposed, while the
    // engine below must be: neither notifier holds a native resource, and
    // `addListener` on a disposed one THROWS where `removeListener` is
    // allowed. Disposing them only here would make this the single path that
    // can fault a widget remounting on a stale tab object — the service's own
    // dispose and a same-id respawn both leave theirs alive, and both are
    // garbage the moment the tab holding them leaves the state.
    tab.ghostty.dispose();
    final tabs = Map<String, TerminalTab>.from(_state.tabs)..remove(terminalId);
    final isActive = _state.activeTerminalId == terminalId;
    if (!isActive) {
      _setState(_state.copyWith(tabs: tabs));
      return;
    }
    final nextActive = tabs.isNotEmpty ? tabs.keys.first : null;
    _setState(
      nextActive == null
          ? _state.copyWith(tabs: tabs, clearActiveTerminal: true)
          : _state.copyWith(tabs: tabs, activeTerminalId: nextActive),
    );
  }

  void setActiveTerminal(String terminalId) {
    // Unread is cleared centrally in _setState when activeTerminalId changes,
    // so this only needs to flip the active id (no tabs-map copy on a plain
    // tab switch).
    if (_state.tabs.containsKey(terminalId)) {
      _setState(_state.copyWith(activeTerminalId: terminalId));
    }
  }

  void requestBranches() {
    _setState(
      _state.copyWith(gitBranchesLoading: true, clearGitBranchesError: true),
    );
    // Tier-2 one-shot: bound the wait on git:branches so a dropped send /
    // session-down clears the spinner instead of stranding it.
    _branchesLatch?.settle();
    final latch = _branchesLatch = ReplyLatch();
    _send(
      createAbMessage('git:list-branches', {'projectId': _state.projectId}),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitActionTimeout).catchError((
        _,
      ) {
        if (_disposed || _branchesLatch != latch) return;
        _branchesLatch = null;
        // Surface the drop, symmetric with checkoutBranch's timeout: an empty
        // gitBranches with the spinner cleared is indistinguishable from a repo
        // that genuinely has no branches, so a lost reply would read as success.
        _setState(
          _state.copyWith(
            gitBranchesLoading: false,
            gitBranchesError:
                'Loading branches timed out — no response from the agent',
          ),
        );
      }),
    );
  }

  void checkoutBranch(String branch) {
    _setState(
      _state.copyWith(gitBranchesLoading: true, clearGitCheckoutError: true),
    );
    _checkoutLatch?.settle();
    final latch = _checkoutLatch = ReplyLatch();
    _send(
      createAbMessage('git:checkout', {
        'projectId': _state.projectId,
        'branch': branch,
      }),
    );
    unawaited(
      session.action(() => latch.done, timeout: gitActionTimeout).catchError((
        _,
      ) {
        if (_disposed || _checkoutLatch != latch) return;
        _checkoutLatch = null;
        _setState(
          _state.copyWith(
            gitBranchesLoading: false,
            gitCheckoutError: 'Checkout timed out — no response from the agent',
          ),
        );
      }),
    );
  }

  void _handleGitBranches(GitBranchesMessage msg) {
    _branchesLatch?.settle();
    _branchesLatch = null;
    _setState(
      _state.copyWith(
        gitBranches: msg.branches,
        gitBranch: msg.current,
        gitBranchesLoading: false,
        clearGitBranchesError: true,
      ),
    );
  }

  void _handleGitCheckoutResult(GitCheckoutResultMessage msg) {
    _checkoutLatch?.settle();
    _checkoutLatch = null;
    if (msg.success) {
      _setState(
        _state.copyWith(
          gitBranch: msg.branch,
          gitBranchesLoading: false,
          clearGitCheckoutError: true,
        ),
      );
    } else {
      _setState(
        _state.copyWith(
          gitBranchesLoading: false,
          gitCheckoutError: msg.error ?? 'Checkout failed',
        ),
      );
    }
  }

  void _handleNotification(TerminalNotificationMessage msg) {
    // Mark the originating tab unread (badge) — unless it's the terminal the
    // user is already viewing — then surface to UI listeners.
    final tab = _state.tabs[msg.terminalId];
    if (tab != null && msg.terminalId != _state.activeTerminalId) {
      final tabs = Map<String, TerminalTab>.from(_state.tabs);
      tabs[msg.terminalId] = tab.copyWith(unread: true);
      _setState(_state.copyWith(tabs: tabs));
    }
    _notificationController.add(msg);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Same reason PreviewService deregisters its own: the registry is the
    // TRANSPORT's, which outlives this service, so a hydrator left behind
    // keeps pulling a dead checkout's snapshots on every reconnect forever.
    session.unhydrateCheckout(checkoutId, _frameHydratorKey);
    await _resumeSub?.cancel();
    _resumeSub = null;
    // Resolve any in-flight git action cleanly so its tier-2 timeout timer is
    // cancelled instead of outliving the service.
    _branchesLatch?.settle();
    _branchesLatch = null;
    _checkoutLatch?.settle();
    _checkoutLatch = null;
    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    // Disown every live frame attachment on the way out — otherwise the
    // bridge keeps ticking an ack budget against a viewer that has stopped
    // listening, and only discovers that the hard way via ACK_TIMEOUT.
    for (final id in _frameAttachment.keys.toList()) {
      _unsubscribeFrame(id);
    }
    for (final timer in _resizeTimers.values) {
      timer.cancel();
    }
    for (final timer in _pendingTerminalTimers.values) {
      timer.cancel();
    }
    for (final timer in _frameSubscribeDeadlines.values) {
      timer.cancel();
    }
    for (final timer in _historyRequestDeadlines.values) {
      timer.cancel();
    }
    _historyRequestDeadlines.clear();
    _checkoutAttachDeadline?.cancel();
    _checkoutAttachDeadline = null;
    _resizeTimers.clear();
    _pendingTerminalTimers.clear();
    _resizeBaseDrivers.clear();
    _deletedTerminalIds.clear();
    _pendingTerminalIds.clear();
    _missingTerminalIds.clear();
    _canceledPendingTerminalIds.clear();
    await _stateController.close();
    await _notificationController.close();
    await _pushController.close();
  }
}
