import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  bool _trackedUse = false;

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
  ReplyLatch? _branchesLatch;
  ReplyLatch? _checkoutLatch;

  final _stateController = StreamController<TerminalState>.broadcast();
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

  Future<void> _rehydrateTerminals() async {
    if (_disposed) return;
    // Cleared first and unconditionally, because a request is not a promise of
    // a reply: an id the agent no longer knows is answered with a log line and
    // no frame, and a send in a keyless window vanishes. Only the tabs whose
    // reply lands re-arm a cutoff (in _applySnapshot), so a clear made
    // conditional on one would strand a cutoff above every seq a respawned PTY
    // emits and leave the pane blank behind a live process.
    _snapshotSeq.clear();
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
    _state = state;
    _stateController.add(state);
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

  void _applySnapshot(TerminalSnapshotMessage msg) {
    final tab = _state.tabs[msg.terminalId];
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
    final held = _snapshotSeq[msg.terminalId];
    if (held != null && msg.seq < held) return;
    // Consumed here, not at the guards above: a frame that never applied
    // leaves the claim standing for the answer that does.
    final wasAwaited = _awaitingHistoryIds.remove(msg.terminalId);
    // A history blob erases before it paints, and replies fan out to every
    // client on the project -- so this one may be the answer to another
    // device's cold attach. Only a client whose engine is empty asked for
    // it; for a painted engine the erase would destroy the user's own
    // scrollback, which is exactly what the warm preamble exists to avoid.
    // Dropped rather than degraded: a painted engine has been taking live
    // output all along, so it needs no repaint either.
    if (msg.history &&
        !wasAwaited &&
        _paintedTerminalIds.contains(msg.terminalId)) {
      return;
    }
    _snapshotSeq[msg.terminalId] = msg.seq;
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
    if (!msg.composed) tab.ghostty.appendOutputBytes(_legacyAttachErase);
    tab.ghostty.appendOutputBytes(utf8.encode(msg.scrollback));
    _paintedTerminalIds.add(msg.terminalId);
  }

  void _requestTerminalSnapshot(String terminalId) {
    final wantsHistory = !_paintedTerminalIds.contains(terminalId);
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
        // prelude-plus-byte-tail blob, which `_applySnapshot` puts its own
        // erase ahead of.
        'history': wantsHistory,
      }),
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
    _paintedTerminalIds.add(msg.terminalId);
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

  void sendInput(String terminalId, String data) {
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
  }

  void sendToAgentTerminal(String text) {
    final agentTabs = _state.tabs.values.where(
      (tab) => tab.isAgent && tab.sessionState == TerminalSessionState.running,
    );
    if (agentTabs.isEmpty) return;
    sendInput(agentTabs.first.terminalId, text);
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
    _resizeTimers.clear();
    _pendingTerminalTimers.clear();
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
