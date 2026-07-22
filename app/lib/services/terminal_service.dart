import 'dart:async';
import 'dart:convert';

import '../analytics/events.dart';
import '../models/terminal_models.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import '../utils/terminal_bell.dart';

class TerminalService {
  final ProjectSession session;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _disposed = false;

  final Map<String, int> _snapshotSeq = {};
  final Map<String, Timer> _resizeTimers = {};
  final Map<String, String?> _resizeBaseDrivers = {};
  final Set<String> _deletedTerminalIds = {};
  bool _trackedUse = false;

  String? _clientId;
  void setClientId(String id) => _clientId = id;

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

  TerminalService.fromSession(this.session) {
    // Heavy tier — terminal:output + terminal:snapshot (HEAVY tier messages).
    _heavySub = session.heavyStream.listen(_onHeavyJson);

    // Status tier — terminal:started, terminal:exited, agent:status,
    // git:branches, git:checkout-result. Routed through the focus-gated
    // router status stream so all dispatch goes through one path.
    _statusSub = session.statusStream.listen(_onStatusJson);
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
      _snapshotSeq[parsed.terminalId] = parsed.seq;
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

  void _applySnapshot(TerminalSnapshotMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;
    tab.ghostty.clear();
    tab.ghostty.appendOutputBytes(utf8.encode(msg.scrollback));
  }

  void _requestTerminalSnapshot(String terminalId) {
    session.send(
      createAbMessage('terminal:snapshot:request', {'terminalId': terminalId}),
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
    await session.send(message);
  }

  // --- Message handlers ---

  void _handleTerminalOutput(TerminalOutputMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;
    tab.ghostty.appendOutputBytes(utf8.encode(msg.data));
  }

  void _handleTerminalStarted(TerminalStartedMessage msg) {
    // Authoritative revival: agent says this id is running again, so any
    // prior local delete-suppression for it is stale.
    _deletedTerminalIds.remove(msg.terminalId);
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    final existing = tabs[msg.terminalId];

    if (existing != null) {
      tabs[msg.terminalId] = existing.copyWith(
        sessionState: TerminalSessionState.running,
        shell: msg.shell,
        cols: msg.cols,
        rows: msg.rows,
        clearExitCode: true,
        type: msg.terminalType,
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
    if (stalePending) {
      _resizeTimers.remove(msg.terminalId)?.cancel();
      _resizeBaseDrivers.remove(msg.terminalId);
    }
    final tabs = Map<String, TerminalTab>.from(_state.tabs);
    tabs[msg.terminalId] = tab.copyWith(
      cols: msg.cols,
      rows: msg.rows,
      driverClientId: msg.driverClientId,
    );
    _setState(_state.copyWith(tabs: tabs));
  }

  void _handleTerminalExited(TerminalExitedMessage msg) {
    final tab = _state.tabs[msg.terminalId];
    if (tab == null) return;

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

    for (final info in msg.terminals) {
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
      final existing = _state.tabs[info.terminalId];
      if (existing != null) {
        final updated = existing.copyWith(
          name: info.name,
          sessionState: info.running
              ? TerminalSessionState.running
              : TerminalSessionState.exited,
          shell: info.shell,
          cols: info.cols,
          rows: info.rows,
          type: info.type,
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
      }
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
        needsFirstRun: msg.needsFirstRun,
      ),
    );
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
  }) {
    final tab = TerminalTab(
      terminalId: terminalId,
      name: name,
      sessionState: running
          ? TerminalSessionState.running
          : TerminalSessionState.exited,
      shell: shell,
      cols: cols ?? 80,
      rows: rows ?? 24,
      type: type,
      driverClientId: driverClientId,
    );

    // Wire the Ghostty controller's user-input path back to the agent.
    tab.ghostty.attachExternalTransport(
      writeBytes: (bytes) {
        sendInput(terminalId, utf8.decode(bytes, allowMalformed: true));
        return true;
      },
      onResize: null,
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

  void sendResize(
    String terminalId,
    int cols,
    int rows, {
    String? baseDriverClientId,
  }) {
    final clientId = _clientId;
    if (clientId == null) return;
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
    final tab = _state.tabs[terminalId];
    if (tab == null) return;
    _resizeTimers.remove(terminalId)?.cancel();
    _resizeBaseDrivers.remove(terminalId);
    _snapshotSeq.remove(terminalId);
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
    _setState(_state.copyWith(gitBranchesLoading: true));
    _send(
      createAbMessage('git:list-branches', {'projectId': _state.projectId}),
    );
  }

  void checkoutBranch(String branch) {
    _setState(
      _state.copyWith(gitBranchesLoading: true, clearGitCheckoutError: true),
    );
    _send(
      createAbMessage('git:checkout', {
        'projectId': _state.projectId,
        'branch': branch,
      }),
    );
  }

  void _handleGitBranches(GitBranchesMessage msg) {
    _setState(
      _state.copyWith(
        gitBranches: msg.branches,
        gitBranch: msg.current,
        gitBranchesLoading: false,
      ),
    );
  }

  void _handleGitCheckoutResult(GitCheckoutResultMessage msg) {
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
    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    for (final timer in _resizeTimers.values) {
      timer.cancel();
    }
    _resizeTimers.clear();
    _resizeBaseDrivers.clear();
    _snapshotSeq.clear();
    _deletedTerminalIds.clear();
    await _stateController.close();
    await _notificationController.close();
    await _pushController.close();
  }
}
