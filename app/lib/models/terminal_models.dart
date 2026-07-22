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
    GhosttyTerminalController? ghostty,
  }) : ghostty =
           ghostty ??
           GhosttyTerminalController(
             initialCols: cols,
             initialRows: rows,
             maxLines: 10000,
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
  final List<String> gitBranches;
  final bool gitBranchesLoading;
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
    this.gitBranches = const [],
    this.gitBranchesLoading = false,
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
    List<String>? gitBranches,
    bool? gitBranchesLoading,
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
      gitBranches: gitBranches ?? this.gitBranches,
      gitBranchesLoading: gitBranchesLoading ?? this.gitBranchesLoading,
      gitCheckoutError: clearGitCheckoutError
          ? null
          : (gitCheckoutError ?? this.gitCheckoutError),
      needsFirstRun: needsFirstRun ?? this.needsFirstRun,
    );
  }
}
