import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

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

  final Map<String, int> _snapshotSeq = {};
  final Map<String, Timer> _resizeTimers = {};
  final Map<String, String?> _resizeBaseDrivers = {};
  final Map<String, Timer> _pendingTerminalTimers = {};
  final Set<String> _deletedTerminalIds = {};
  final Set<String> _pendingTerminalIds = {};
  final Set<String> _canceledPendingTerminalIds = {};

  /// Terminals whose Ghostty engine has had bytes written into it since the tab
  /// was built. Drives the `history` flag on a snapshot request: the agent's
  /// history blob ERASES before it paints, so asking for one against an engine
  /// that already holds the user's scrollback destroys it, and asking for a
  /// screen-only blob against an empty engine leaves a scrolling build log
  /// showing its last few rows and nothing above them.
  ///
  /// Keyed to the ENGINE's life, not the terminal's: [_createTab] is the only
  /// place a fresh controller is born, and an exit-then-respawn under the same
  /// id keeps the same engine — with the dead run's output still on it, which is
  /// history worth protecting. Deliberately not derived from the engine's own
  /// line contents: a guest that cleared its screen presents as empty while
  /// holding thousands of lines above.
  final Set<String> _paintedTerminalIds = {};

  /// Terminals this client has asked for a history blob and not yet been
  /// answered for.
  ///
  /// A reply fans out to every client, so [_applySnapshot] refuses a history
  /// blob against a painted engine. Without this claim that refusal would
  /// also swallow OUR OWN answer whenever live output lands during the round
  /// trip -- routine on a busy terminal -- leaving the cold attach with a
  /// screen and no history, which is the whole loss the flag exists to fix.
  ///
  /// Consumed by the next snapshot that actually applies, whatever it is: an
  /// older agent strips the request key and answers screen-only, and a claim
  /// nothing retires would later admit ANOTHER device's erase.
  final Set<String> _awaitingHistoryIds = {};

  /// Epoch ms of this client's outstanding screen pull per terminal.
  ///
  /// Deliberately separate from [_awaitingHistoryIds], which answers a
  /// different question: membership there proves the engine was EMPTY when the
  /// pull went out, and it is consumed by any snapshot that applies, including
  /// another device's. This map is retired only where a screen actually
  /// arrives.
  final Map<String, int> _snapshotRequestedAtMs = {};
  final Map<String, Timer> _snapshotDeadlines = {};
  final Set<String> _snapshotFailedIds = {};

  /// True once the bridge has answered `terminal.snapshot` with
  /// `E_UNKNOWN_METHOD` — the ONLY signal that means "old bridge, no RPC
  /// intercept". A pull that goes unanswered for any other reason (the
  /// mobile-access gate, the checkout-routing gate, an over-cap
  /// `SendScheduler` drop) looks identical to a dropped legacy request on a
  /// fully current bridge, so keying this off a timeout would permanently pin
  /// a capable machine to the legacy path. Cleared at the top of every
  /// [_rehydrateTerminals] so a stream re-attach onto a since-upgraded bridge
  /// tries the RPC again.
  bool _rpcSnapshotUnsupported = false;

  /// Per-terminal generation of the outstanding snapshot pull, bumped on
  /// every new pull and every retirement.
  ///
  /// Replaces a deadline timer on the RPC arm: `_pullTerminalSnapshot`'s
  /// `await` re-checks this after every suspension point, so a late-arriving
  /// `E_TIMEOUT` for a pull that live output already retired
  /// ([_handleTerminalOutput]) can never stamp `_snapshotFailedIds` over a
  /// pane that is visibly painting.
  final Map<String, int> _snapshotGeneration = {};
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
    onListen: _armCheckoutAttachDeadline,
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

    // Tier-3 re-drive. This is the terminal's ONLY reconnect recovery: the
    // agent drops terminal output while suppressed but keeps bumping the seq,
    // so a tab that was already on screen when the stream went away renders
    // whatever it held then, forever — nothing else re-pulls it (the discovery
    // pulls only fire for a tab the app has never seen).
    //
    // A seq cutoff is only meaningful against the PTY generation it was taken
    // from, and the agent's counter is per PTY: it is deleted on exit
    // (`ConnState.clearTerminal`), so a same-id respawn starts again at 1. A
    // disconnect is exactly the window in which a terminal can exit and respawn
    // unwitnessed — neither `terminal:exited` nor `terminal:started` arrives —
    // and nothing on the wire distinguishes the new run from the old, so a
    // surviving cutoff sits above every seq the new PTY will ever emit and
    // filters its entire output. The tab then renders blank behind a live
    // process, with no user action that clears it. Dropped wholesale rather
    // than reasoned about per tab: losing a still-valid cutoff costs a few
    // duplicated lines on the next snapshot, keeping a stale one costs the
    // pane.
    session.hydrateCheckout(
      checkoutId,
      _snapshotHydratorKey,
      _rehydrateTerminals,
    );
    _resumeSub = session.focusResumed.listen(
      (_) => detached(
        'TerminalService',
        're-attach snapshot pull on focus resume',
        _rehydrateTerminals,
      ),
    );
  }

  static const _snapshotHydratorKey = 'terminal:snapshots';

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

  /// Drops the checkout bound and every per-terminal one when the last watcher
  /// goes away.
  ///
  /// The pulls themselves are left outstanding — a reply that still lands is
  /// still painted — but nothing is left counting down towards a verdict no
  /// surface would read. A watcher that comes back re-arms the checkout bound
  /// through [_stateController]'s `onListen`, and the per-terminal bounds
  /// return with the re-drive that any reattach already performs.
  void _dropAttachBounds() {
    _cancelCheckoutAttachDeadline();
    for (final timer in _snapshotDeadlines.values) {
      timer.cancel();
    }
    _snapshotDeadlines.clear();
    // The RPC arm's bound is the transport's own request timeout, which this
    // service cannot cancel. Disowning the pulls is the reachable half of the
    // same rule: nothing is left that can stamp a verdict onto a service no
    // surface is reading.
    for (final terminalId in _snapshotRequestedAtMs.keys.toList()) {
      _abandonSnapshotPull(terminalId);
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
    // A stream re-attach can land on a restarted, upgraded bridge, so a
    // verdict earned against the old one must not survive it — otherwise a
    // machine that has since gained the RPC intercept stays pinned to the
    // legacy message path for the life of the client.
    _rpcSnapshotUnsupported = false;
    // The re-establish edge, and the only one there is: nothing publishes a
    // transport transition the pane could listen for — `sessionDownEvents`
    // fires from retry exhaustion, not a live socket loss, and StreamTransport
    // never emits `disconnected`. So the refusal latch is cleared by the same
    // hydrator re-drive that reopens the pulls, which is exactly what a
    // recovered send would have needed anyway.
    _syncInputPaused();
    // Cleared first and unconditionally, because a request is not a promise of
    // a reply: an id the agent no longer knows is answered with a log line and
    // no frame, and a send in a keyless window vanishes. Only the tabs whose
    // reply lands re-arm a cutoff (in _applySnapshot), so a clear made
    // conditional on one would strand a cutoff above every seq a respawned PTY
    // emits and leave the pane blank behind a live process.
    _snapshotSeq.clear();
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
      // A pending tab is the app's own optimistic invention — the agent has
      // never confirmed the id, so it would answer "snapshot requested for
      // unknown terminal" and send nothing. Its own terminal:started carries
      // the pull.
      if (_pendingTerminalIds.contains(tab.terminalId)) continue;
      _requestTerminalSnapshot(tab.terminalId);
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
      for (final id in tabs.keys)
        id: TerminalHydration(
          stage: _stageFor(id),
          requestedAtMs: _snapshotRequestedAtMs[id],
        ),
    };
  }

  // The paint decides how an outstanding pull reads. A re-pull over an engine
  // that already holds current bytes is routine — every re-establishment and
  // every focus resume issues one for every live tab — and must never present
  // as a wait or escalate to a failure.
  TerminalAttachStage _stageFor(String id) {
    final painted = _paintedTerminalIds.contains(id);
    if (_snapshotFailedIds.contains(id)) return TerminalAttachStage.failed;
    if (_snapshotRequestedAtMs.containsKey(id)) {
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

  /// Drops the bookkeeping for [terminalId]'s outstanding pull, reporting
  /// whether anything was actually retired.
  ///
  /// The answer gates the re-emission: this runs on the live-output path, where
  /// republishing per frame would push a full workspace rebuild behind every
  /// byte the guest writes.
  bool _retireSnapshotPull(String terminalId) {
    final deadline = _snapshotDeadlines.remove(terminalId);
    deadline?.cancel();
    final hadRequest = _snapshotRequestedAtMs.remove(terminalId) != null;
    final hadFailure = _snapshotFailedIds.remove(terminalId);
    return deadline != null || hadRequest || hadFailure;
  }

  /// Retires [terminalId]'s pull AND disowns any reply still on the wire for
  /// it, by moving the generation the reply was issued under.
  ///
  /// Only for the cases where the answer has stopped being wanted: the tab is
  /// gone, its engine has been rebuilt, or its PTY exited. Retiring alone must
  /// NOT disown — live output retires the bound, because a visibly streaming
  /// pane needs no failure verdict, but the history that pull is carrying is
  /// exactly what a cold attach is still owed. Dropping it there loses the
  /// scrollback on precisely the busiest terminals, silently.
  void _abandonSnapshotPull(String terminalId) {
    _snapshotGeneration[terminalId] = (_snapshotGeneration[terminalId] ?? 0) + 1;
    _retireSnapshotPull(terminalId);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    if (_disposed) return;
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    if (parsed is TerminalSnapshotMessage) {
      // Arming is _applySnapshot's job, not this one's: it bails on a tab that
      // vanished between request and reply, and a cutoff armed for scrollback
      // nothing rendered filters the live output of the tab that replaces it.
      _applySnapshot(parsed);
      return;
    }
    if (parsed is TerminalOutputMessage) {
      final seq = parsed.seq;
      final cutoff = _snapshotSeq[parsed.terminalId];
      if (seq != null && cutoff != null && seq <= cutoff) {
        return; // stale — already in snapshot
      }
      _handleTerminalOutput(parsed);
    }
  }

  /// Erase for the LEGACY payload only — an older agent's raw byte tail, up to
  /// ten thousand characters of it, which is several screens.
  ///
  /// `CSI 3 J` is in it because a body taller than the screen SCROLLS: `2J`
  /// clears the visible rows, and the tail then pushes each of them into the
  /// buffer above as it draws past the bottom, so every attach stacks another
  /// copy of the same output into the user's history with no way to clear it.
  /// The re-attach now fires on every focus resume, so that is unbounded.
  /// Erasing history the tail is about to reprint is the lesser loss, and it is
  /// what this path did before the composed blob existed.
  ///
  /// A composed blob takes no erase at all — it is exactly one screen and
  /// carries its own preamble, which deliberately stops at `2J` so the app's
  /// own scrollback survives it.
  static final Uint8List _legacyAttachErase = Uint8List.fromList(
    utf8.encode('\x1b[3J\x1b[2J\x1b[H'),
  );

  /// Adapter for the broadcast path: `terminal:snapshot` (the legacy
  /// message-path reply, and the `resyncState` push it shares a wire shape
  /// with) always applies as if it might be fanned out to another device.
  void _applySnapshot(TerminalSnapshotMessage msg) {
    _applySnapshotFields(
      terminalId: msg.terminalId,
      scrollback: msg.scrollback,
      seq: msg.seq,
      composed: msg.composed,
      history: msg.history,
      fromBroadcast: true,
    );
  }

  /// Applies one screen pull's fields to the tab's engine, however it arrived
  /// — a `terminal:snapshot` broadcast (any client's request, or an
  /// unsolicited `resyncState` push) or a `terminal.snapshot` RPC reply.
  ///
  /// [fromBroadcast] gates ONLY the fan-out refusal below: an RPC reply is
  /// correlated by `requestId` and can only ever be the answer to OUR OWN
  /// request (a phase-1 reply, another device's blob and a `resyncState` push
  /// are all structurally incapable of completing it), so the boolean claim
  /// [_awaitingHistoryIds] exists to consume is meaningless on that path —
  /// always false there, so the refusal condition is vacuous and skipped.
  void _applySnapshotFields({
    required String terminalId,
    required String scrollback,
    required int seq,
    required bool composed,
    required bool history,
    required bool fromBroadcast,
  }) {
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    // A blob describes the instant its seq was read, and one terminal has
    // several snapshot producers on a single re-establishment: the agent's
    // resync push, this service's hydrator pull, a focus-resume pull, and any
    // other client's request — replies are published on the project bus, so
    // every attached client gets them. The frame that lands last is not the
    // one that describes the latest instant, and applying an older one both
    // repaints a screen the tab has moved past and lowers the cutoff BELOW
    // frames already applied, which nothing refilters and nothing re-sends.
    //
    // Safe against a respawn's counter reset (the agent's seq is per PTY and
    // starts again at 1) because every path into a new generation drops the
    // cutoff first — terminal:started, the exit handler, and the re-drive.
    // Equal seqs are still applied: a screen-only push and a `history` reply
    // can describe the same instant, and only the second carries the history.
    final held = _snapshotSeq[terminalId];
    if (held != null && seq < held) return;
    // Consumed here, not at the guards above: a frame that never applied
    // leaves the claim standing for the answer that does. Only the legacy
    // send arm ever adds to this set — see its doc comment — so on the RPC
    // path this is always false and the fan-out refusal below never fires.
    final wasAwaited = _awaitingHistoryIds.remove(terminalId);
    // A history blob erases before it paints, and a BROADCAST reply fans out
    // to every client on the project -- so this one may be the answer to
    // another device's cold attach. Only a client whose engine is empty asked
    // for it; for a painted engine the erase would destroy the user's own
    // scrollback, which is exactly what the warm preamble exists to avoid.
    // Dropped rather than degraded: a painted engine has been taking live
    // output all along, so it needs no repaint either.
    if (fromBroadcast &&
        history &&
        !wasAwaited &&
        _paintedTerminalIds.contains(terminalId)) {
      return;
    }
    _snapshotSeq[terminalId] = seq;
    // Deliberately NOT `clear()`. That resets the engine, and a reset takes
    // the guest's MODES with it — alt screen, bracketed paste, focus events,
    // mouse tracking, synchronised output. A fullscreen TUI sets those once at
    // startup and never sends them again, and they are far outside the byte
    // tail this snapshot carries, so nothing here can put them back: the
    // engine would sit on the primary screen with mouse off while the guest
    // draws into an alt screen, until the agent itself is restarted.
    //
    // A composed blob is self-contained: it opens with its own preamble (alt
    // screen exit, margin reset, screen erase, cursor home, SGR reset),
    // repaints the visible screen, restores its own modes, and ends in a
    // RELATIVE cursor placement. Anything prepended lands ahead of that
    // preamble — the wrong-screen bug the preamble exists to fix — and anything
    // appended lands after the cursor is placed, so the blob goes on verbatim.
    if (!composed) tab.ghostty.appendOutputBytes(_legacyAttachErase);
    tab.ghostty.appendOutputBytes(utf8.encode(scrollback));
    // Retired here and nowhere earlier. This method has three other exits — a
    // tab that vanished between request and reply, a blob older than the cutoff,
    // and a history blob aimed at another device's cold attach — and clearing on
    // any of them would report our own outstanding pull as answered by a frame
    // that painted nothing. Leaving it outstanding there is correct; the
    // deadline owns it.
    final retired = _retireSnapshotPull(terminalId);
    final firstPaint = _paintedTerminalIds.add(terminalId);
    if (retired || firstPaint) _publishHydration();
  }

  /// Issues one terminal's screen pull: `terminal.snapshot` RPC unless this
  /// establishment has already learned the bridge doesn't answer it, in which
  /// case the legacy message.
  void _requestTerminalSnapshot(String terminalId) {
    final wantsHistory = !_paintedTerminalIds.contains(terminalId);
    final generation = (_snapshotGeneration[terminalId] ?? 0) + 1;
    _snapshotGeneration[terminalId] = generation;
    if (_rpcSnapshotUnsupported) {
      _sendLegacySnapshotRequest(terminalId, wantsHistory);
    } else {
      _stampSnapshotPull(terminalId);
      detached(
        'TerminalService',
        'terminal snapshot pull',
        () => _pullTerminalSnapshot(terminalId, wantsHistory, generation),
      );
    }
    _publishHydration();
  }

  /// Records the pull's start for hydration purposes, without arming a local
  /// deadline — the RPC arm's bound is `request(timeout: …)` itself, not a
  /// separate timer (see [_snapshotGeneration]'s doc comment).
  void _stampSnapshotPull(String terminalId) {
    _snapshotRequestedAtMs[terminalId] = DateTime.now().millisecondsSinceEpoch;
    _snapshotFailedIds.remove(terminalId);
  }

  /// The legacy `terminal:snapshot:request` message. Claims
  /// [_awaitingHistoryIds] and arms a local [_snapshotDeadlines] timer — both
  /// meaningless on the RPC arm, whose bound is the request's own timeout and
  /// whose "did I ask for history" is carried by the correlated reply itself.
  void _sendLegacySnapshotRequest(String terminalId, bool wantsHistory) {
    if (wantsHistory) {
      _awaitingHistoryIds.add(terminalId);
    } else {
      _awaitingHistoryIds.remove(terminalId);
    }
    session.sendForCheckout(
      checkoutId,
      createAbMessage('terminal:snapshot:request', {
        'terminalId': terminalId,
        // See [_paintedTerminalIds]. An agent that predates the key strips it
        // (the request schema is a `z.object`) and answers with the legacy
        // prelude-plus-byte-tail blob, which `_applySnapshotFields` puts its
        // own erase ahead of.
        'history': wantsHistory,
      }),
    );
    _stampSnapshotPull(terminalId);
    _snapshotDeadlines.remove(terminalId)?.cancel();
    // Bounded only where an unanswered pull is actually a fault. A terminal
    // whose process has exited has no screen left to serialize: the manager
    // disposes the screen on exit unless the transcript is retained, and the
    // handler answers a missing screen with a log line and NO frame. That pull
    // is structurally unanswerable and must never read as a failure.
    final tab = _state.tabs[terminalId];
    if (tab != null && _hasLivePty(tab)) {
      _snapshotDeadlines[terminalId] = Timer(snapshotAttachTimeout, () {
        if (_disposed) return;
        _snapshotDeadlines.remove(terminalId);
        _failSnapshotPull(terminalId);
      });
    }
  }

  /// The RPC arm's pull. Every `await` re-checks [_disposed] and the
  /// terminal's [_snapshotGeneration] before touching state, so a reply for a
  /// pull that has since been disowned ([_abandonSnapshotPull]) or superseded
  /// by a fresh one touches nothing.
  ///
  /// Live output is deliberately NOT such an event: it retires the bound but
  /// leaves the pull owned, because the history this reply carries is what a
  /// cold attach is waiting for and a busy terminal is where it matters most.
  Future<void> _pullTerminalSnapshot(
    String terminalId,
    bool wantsHistory,
    int generation,
  ) async {
    Map<String, dynamic> res;
    try {
      res = await session.transport.request(
        'terminal.snapshot',
        params: {
          'terminalId': terminalId,
          'checkoutId': checkoutId,
          'history': wantsHistory,
        },
        timeout: snapshotAttachTimeout,
        // A rekey-driven re-establish re-drives this same pull for every live
        // tab, and letting a run of timeouts on a link that cannot carry it
        // count toward the session's rekey trigger turns that re-drive into
        // an unbreakable loop (see `AgentTransport.request`'s doc comment).
        countsTowardHealth: false,
      );
    } on RpcException catch (e) {
      if (_disposed) return;
      // Recorded ahead of the generation check, and for every terminal: the
      // verdict is about the BRIDGE, not about this pull. Behind the check, a
      // terminal busy enough to have moved the generation on would keep
      // spending a full round trip per pull without ever learning the peer
      // cannot answer — and the busiest terminal is the agent's own.
      if (e.code == 'E_UNKNOWN_METHOD') {
        // The ONLY code that means an old bridge — see
        // [_rpcSnapshotUnsupported]'s doc comment.
        _rpcSnapshotUnsupported = true;
        if (_snapshotGeneration[terminalId] != generation) return;
        // Re-issued under the SAME generation: a continuation of this pull,
        // not a new one.
        _sendLegacySnapshotRequest(terminalId, wantsHistory);
        return;
      }
      if (_snapshotGeneration[terminalId] != generation) return;
      _failSnapshotPull(terminalId);
      return;
    } catch (_) {
      // Anything the transport can raise that is not an `RpcException` still
      // ends this pull. Without this the stamp in `_snapshotRequestedAtMs`
      // stands with no bound behind it — the RPC arm arms no local timer — and
      // the pane counts up in `awaitingScreen` forever with no strip and no
      // Retry.
      if (_disposed || _snapshotGeneration[terminalId] != generation) return;
      _failSnapshotPull(terminalId);
      return;
    }
    if (_disposed || _snapshotGeneration[terminalId] != generation) return;
    final snap = (res['snapshot'] as Map?)?.cast<String, dynamic>();
    if (snap == null) {
      // Not a failure: the bridge has no screen left to serialize for this
      // terminal (an exited PTY whose screen was disposed, an id it does not
      // know) and has said so explicitly rather than answering with nothing.
      if (_retireSnapshotPull(terminalId)) _publishHydration();
      return;
    }
    _applySnapshotFields(
      terminalId: terminalId,
      scrollback: snap['scrollback'] as String? ?? '',
      seq: snap['seq'] as int? ?? 0,
      composed: snap['composed'] == true,
      // Passed, never recomputed: `_applySnapshotFields` adds this id to
      // `_paintedTerminalIds` on a successful apply, so a recompute after
      // would always read false.
      history: wantsHistory,
      fromBroadcast: false,
    );
  }

  /// Marks [terminalId]'s outstanding pull failed — the legacy arm's deadline
  /// callback, and the RPC arm's non-`E_UNKNOWN_METHOD` catch, both funnel
  /// here. Must never write [_snapshotSeq]: only an applied snapshot may set a
  /// cutoff, and one armed on a request rather than a reply would sit above
  /// every seq a respawned PTY emits.
  void _failSnapshotPull(String terminalId) {
    _snapshotDeadlines.remove(terminalId)?.cancel();
    _snapshotRequestedAtMs.remove(terminalId);
    if (!_paintedTerminalIds.contains(terminalId)) {
      _snapshotFailedIds.add(terminalId);
    }
    _publishHydration();
  }

  /// Re-drives ONE terminal's screen pull.
  ///
  /// Deliberately not `StreamTransport.refreshSnapshot()`, which re-drives every
  /// hydrator on the stream — including a per-checkout `tree:full` for every
  /// checkout — and would turn a user's tap into a multi-megabyte fan-out.
  void retryAttach(String terminalId) {
    if (_disposed || !_state.tabs.containsKey(terminalId)) return;
    // Dropping the cutoff before the request is what lets a fresh reply paint
    // at all, and is precedented: the reconnect re-drive clears every cutoff
    // first and unconditionally, for the same reason.
    _snapshotSeq.remove(terminalId);
    _snapshotFailedIds.remove(terminalId);
    _requestTerminalSnapshot(terminalId);
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
    } else if (message is NotificationPushMessage) {
      _pushController.add(message);
    } else if (message is TerminalSizeMessage) {
      _handleTerminalSize(message);
    }
  }

  Future<void> _send(Map<String, dynamic> message) async {
    await session.sendForCheckout(checkoutId, message);
  }

  // --- Message handlers ---

  void _handleTerminalOutput(TerminalOutputMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;
    // Only the live output path closes an echo timer. Snapshots are a
    // reconnect artifact, not a response to anything the user typed.
    perfRecorder.noteTerminalOutput(
      projectId: session.projectId,
      checkoutId: checkoutId,
      terminalId: msg.terminalId,
    );
    tab.ghostty.appendOutputBytes(utf8.encode(msg.data));
    // Live bytes answer the question an outstanding pull was asking. Without
    // this, a terminal that starts streaming while its snapshot request is in
    // flight — the common case for a busy TUI, and for a request the agent
    // answers with nothing — waits out the whole bound and then reports a
    // failure over a pane that is visibly live.
    final retired = _retireSnapshotPull(msg.terminalId);
    final firstPaint = _paintedTerminalIds.add(msg.terminalId);
    if (retired || firstPaint) _publishHydration();
  }

  void _handleTerminalStarted(TerminalStartedMessage msg) {
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
    // A start means a fresh PTY, and the agent's seq counter is per PTY —
    // deleted on exit, so this one begins again at 1. Any cutoff still held for
    // this id was taken from the previous generation and now sits above every
    // seq the new one will ever emit, filtering its whole output: a blank pane
    // behind a live process. Dropped BEFORE the pull, and unconditionally,
    // because the reply is not guaranteed and losing a live cutoff costs a few
    // duplicated lines where keeping a dead one costs the pane. The exit
    // handler covers the ordinary case; this covers the start whose exit was
    // never delivered, which is every window where outbound frames were dropped
    // (a remote-access flip drops status frames too).
    _snapshotSeq.remove(msg.terminalId);
    // Newly-discovered terminal — fetch its scrollback so we can drop stale
    // terminal:output frames via the per-terminal seq cutoff.
    _requestTerminalSnapshot(msg.terminalId);
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
      cols: msg.cols,
      rows: msg.rows,
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
    // A pull issued before this exit may still be in flight; its eventual
    // reply — success or timeout alike — describes an engine that has just
    // gone stopped, so it is disowned rather than applied.
    _abandonSnapshotPull(msg.terminalId);
    // The agent's seq counter is per PTY, not per terminal id: it is deleted on
    // exit (`ConnState.clearTerminal`), so a same-id respawn restarts at 1.
    // A cutoff kept from the previous run sits above every seq the next one
    // emits, and would filter its entire output as already-snapshotted.
    _snapshotSeq.remove(msg.terminalId);
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;

    tab.ghostty.setSessionRunning(false);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[msg.terminalId] = tab.copyWith(
      sessionState: TerminalSessionState.exited,
      exitCode: msg.exitCode,
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
        final updated = existing.copyWith(
          name: info.name,
          sessionState: info.running
              ? TerminalSessionState.running
              : TerminalSessionState.exited,
          shell: info.shell,
          cols: info.cols,
          rows: info.rows,
          type: info.type,
          sizeEpoch: respawned ? existing.sizeEpoch + 1 : null,
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
    _snapshotSeq.removeWhere((id, _) => !newTabs.containsKey(id));
    _paintedTerminalIds.removeWhere((id) => !newTabs.containsKey(id));
    _awaitingHistoryIds.removeWhere((id) => !newTabs.containsKey(id));
    _snapshotRequestedAtMs.removeWhere((id, _) => !newTabs.containsKey(id));
    _snapshotFailedIds.removeWhere((id) => !newTabs.containsKey(id));
    _snapshotDeadlines.removeWhere((id, timer) {
      if (newTabs.containsKey(id)) return false;
      timer.cancel();
      return true;
    });
    for (final terminalId in discovered) {
      // Only the tabs that survived the rebuild: one dropped along the way has
      // nowhere for the reply to land.
      if (newTabs.containsKey(terminalId)) _requestTerminalSnapshot(terminalId);
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
    // A fresh engine holds nothing, so the next snapshot request for this id is
    // a COLD one. Cleared here rather than at every removal site because this is
    // the single place a controller is built — a stale `true` would cost the
    // user the history the new tab is about to be handed.
    _paintedTerminalIds.remove(terminalId);
    _awaitingHistoryIds.remove(terminalId);
    _abandonSnapshotPull(terminalId);
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
    // A bare BEL rings audibly like a native terminal — it is deliberately not a
    // desktop notification (only OSC 9/777 raise those, via terminal:notification).
    // Ring only the terminal the user is actually viewing: the focus coordinator
    // keeps `isFocused` current (false for background projects, blurred agents,
    // and while the app is backgrounded), so a background bell doesn't sound /
    // buzz the device. `ringTerminalBell` throttles bursts.
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
    return sendInput(agentTabs.first.terminalId, text);
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
    _pendingTerminalIds.add(terminalId);
    _pendingTerminalTimers.remove(terminalId)?.cancel();
    _pendingTerminalTimers[terminalId] = Timer(
      terminalStartTimeout,
      () => _expirePendingTerminal(terminalId),
    );

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
    requestStop(terminalId);
    _deletedTerminalIds.add(terminalId);
    if (_pendingTerminalIds.contains(terminalId)) {
      _canceledPendingTerminalIds.add(terminalId);
    }
    _settlePendingTerminal(terminalId);
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    _resizeTimers.remove(terminalId)?.cancel();
    _resizeBaseDrivers.remove(terminalId);
    _snapshotSeq.remove(terminalId);
    _paintedTerminalIds.remove(terminalId);
    _awaitingHistoryIds.remove(terminalId);
    _abandonSnapshotPull(terminalId);
    _snapshotGeneration.remove(terminalId);
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
    session.unhydrateCheckout(checkoutId, _snapshotHydratorKey);
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
    for (final timer in _resizeTimers.values) {
      timer.cancel();
    }
    for (final timer in _pendingTerminalTimers.values) {
      timer.cancel();
    }
    for (final timer in _snapshotDeadlines.values) {
      timer.cancel();
    }
    _checkoutAttachDeadline?.cancel();
    _checkoutAttachDeadline = null;
    _resizeTimers.clear();
    _pendingTerminalTimers.clear();
    _snapshotDeadlines.clear();
    _snapshotRequestedAtMs.clear();
    _snapshotFailedIds.clear();
    _resizeBaseDrivers.clear();
    _snapshotSeq.clear();
    _deletedTerminalIds.clear();
    _pendingTerminalIds.clear();
    _canceledPendingTerminalIds.clear();
    await _stateController.close();
    await _notificationController.close();
    await _pushController.close();
  }
}
