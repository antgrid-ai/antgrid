import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'layout_models.dart';
import 'ab_message.dart';

enum TerminalSessionState { starting, running, exited }

class TerminalTab {
  final String terminalId;
  final String name;
  final TerminalSessionState sessionState;
  final String? shell;
  final int cols;
  final int rows;
  final String? driverClientId;
  final int? exitCode;
  final String? type; // "agent" | "service"
  final bool unread;

  /// Bumped whenever what the app knew about this PTY's geometry stops being
  /// trustworthy — a reconnect, a same-id respawn, or a resize the service
  /// queued and then discarded.
  ///
  /// The driver only re-sends `terminal:resize` when its computed grid differs
  /// from the last size it believes the PTY received, so a size that never
  /// arrived (a send dropped in a keyless window, or a queued one cancelled
  /// before it reached the wire) and one a fresh PTY never had (a respawn takes
  /// the bridge's `lastDriverGeometry`, which is whatever terminal resized
  /// last — 80x24 only on a bridge that has never seen a resize) are both
  /// disagreements nothing else can detect: the panel is not moving, so the
  /// wrapper computes the same grid forever and the gate stays shut. The
  /// counter is the invalidation edge that reopens it, invalidated by the same
  /// events as the snapshot-seq cutoff in `TerminalService._rehydrateTerminals`
  /// and for the same reason.
  final int sizeEpoch;

  /// Ghostty controller — the agent's PTY bytes are fed in via
  /// `ghostty.appendOutputBytes(...)` from terminal_service, and user
  /// input is routed back through `attachExternalTransport` to the
  /// service's `sendInput`.
  final GhosttyTerminalController ghostty;

  TerminalTab({
    required this.terminalId,
    required this.name,
    this.sessionState = TerminalSessionState.starting,
    this.shell,
    this.cols = 80,
    this.rows = 24,
    this.driverClientId,
    this.exitCode,
    this.type,
    this.unread = false,
    this.sizeEpoch = 0,
    GhosttyTerminalController? ghostty,
  }) : ghostty =
           ghostty ??
           GhosttyTerminalController(
             initialCols: cols,
             initialRows: rows,
             maxLines: 10000,
             // Rows, not bytes: at an agent-sized 202 columns a 10k-row
             // history is roughly 17 MB, so the ceiling is generous enough
             // that the row budget is what actually binds. Sizing this in
             // bytes instead would retain ~2.5x fewer rows on a wide terminal
             // than a narrow one.
             maxScrollback: 64 << 20,
             maxScrollbackLines: 10000,
           );

  bool get isAgent => type == 'agent';

  TerminalTab copyWith({
    String? name,
    TerminalSessionState? sessionState,
    String? shell,
    int? cols,
    int? rows,
    String? driverClientId,
    bool clearDriverClientId = false,
    int? exitCode,
    bool clearExitCode = false,
    String? type,
    bool? unread,
    int? sizeEpoch,
  }) {
    return TerminalTab(
      terminalId: terminalId,
      name: name ?? this.name,
      sessionState: sessionState ?? this.sessionState,
      shell: shell ?? this.shell,
      cols: cols ?? this.cols,
      rows: rows ?? this.rows,
      driverClientId: clearDriverClientId
          ? null
          : (driverClientId ?? this.driverClientId),
      exitCode: clearExitCode ? null : (exitCode ?? this.exitCode),
      type: type ?? this.type,
      unread: unread ?? this.unread,
      sizeEpoch: sizeEpoch ?? this.sizeEpoch,
      ghostty: ghostty,
    );
  }
}

class TerminalState {
  final Map<String, TerminalTab> tabs;
  final String? activeTerminalId;
  final String? projectId;
  final AgentInfo? agentInfo;
  final LayoutConfig? layout;
  final List<CommandInfo>? commands;
  final String? gitBranch;

  /// Ahead/behind for [gitBranch], carried on the same `agent:status` frame it
  /// comes from. Local counts, so as fresh as the last fetch — see
  /// `GitSyncState` for why nothing on this path may reach the network.
  final int gitAhead;
  final int gitBehind;
  final List<String> gitBranches;
  final bool gitBranchesLoading;
  final String? gitBranchesError;
  final String? gitCheckoutError;
  final bool? needsFirstRun;

  const TerminalState({
    this.tabs = const {},
    this.activeTerminalId,
    this.projectId,
    this.agentInfo,
    this.layout,
    this.commands,
    this.gitBranch,
    this.gitAhead = 0,
    this.gitBehind = 0,
    this.gitBranches = const [],
    this.gitBranchesLoading = false,
    this.gitBranchesError,
    this.gitCheckoutError,
    this.needsFirstRun,
  });

  TerminalTab? get activeTab =>
      activeTerminalId != null ? tabs[activeTerminalId] : null;

  List<TerminalTab> get sortedTabs {
    final list = tabs.values.toList();
    list.sort((a, b) {
      final cmp = a.name.compareTo(b.name);
      return cmp != 0 ? cmp : a.terminalId.compareTo(b.terminalId);
    });
    return list;
  }

  TerminalState copyWith({
    Map<String, TerminalTab>? tabs,
    String? activeTerminalId,
    String? projectId,
    AgentInfo? agentInfo,
    LayoutConfig? layout,
    List<CommandInfo>? commands,
    String? gitBranch,
    int? gitAhead,
    int? gitBehind,
    List<String>? gitBranches,
    bool? gitBranchesLoading,
    String? gitBranchesError,
    bool clearGitBranchesError = false,
    String? gitCheckoutError,
    bool clearGitCheckoutError = false,
    bool clearActiveTerminal = false,
    bool? needsFirstRun,
  }) {
    return TerminalState(
      tabs: tabs ?? this.tabs,
      activeTerminalId: clearActiveTerminal
          ? null
          : (activeTerminalId ?? this.activeTerminalId),
      projectId: projectId ?? this.projectId,
      agentInfo: agentInfo ?? this.agentInfo,
      layout: layout ?? this.layout,
      commands: commands ?? this.commands,
      gitBranch: gitBranch ?? this.gitBranch,
      gitAhead: gitAhead ?? this.gitAhead,
      gitBehind: gitBehind ?? this.gitBehind,
      gitBranches: gitBranches ?? this.gitBranches,
      gitBranchesLoading: gitBranchesLoading ?? this.gitBranchesLoading,
      gitBranchesError: clearGitBranchesError
          ? null
          : (gitBranchesError ?? this.gitBranchesError),
      gitCheckoutError: clearGitCheckoutError
          ? null
          : (gitCheckoutError ?? this.gitCheckoutError),
      needsFirstRun: needsFirstRun ?? this.needsFirstRun,
    );
  }
}
