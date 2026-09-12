import 'package:flutter/foundation.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'layout_models.dart';
import 'ab_message.dart';
import 'terminal_history_model.dart';

enum TerminalSessionState { starting, running, exited }

/// Mirrors the bridge's `TERMINAL_PROTOCOL_VERSION`
/// (`bridge/src/terminal-frames/protocol.ts`) -- the highest frame wire
/// version this client can render, sent on every `terminal:subscribe`. Bump
/// only in lockstep with that constant; a mismatch answers
/// `terminal:display:status` `UPGRADE_REQUIRED` rather than a screen.
const int kTerminalFrameProtocolVersion = 2;

/// Independent frames are the sole terminal display protocol.
enum TerminalDisplayMode { frame }

/// Mirrors the bridge terminal:resize intent contract.
enum TerminalResizeIntent { resize, takeover }

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

  /// Which wire protocol currently owns this terminal's screen. See
  /// [TerminalDisplayMode].
  final TerminalDisplayMode mode;

  /// Bumped every time this tab's engine content was REPLACED wholesale
  /// rather than appended to -- currently only an applied frame-mode
  /// `terminal:frame` (one `appendOutputBytes` call, self-contained). A
  /// `ValueNotifier`, not a `TerminalState`/`copyWith` field: a live frame
  /// replaces the screen up to 20x/s (`TERMINAL_FRAME_INTERVAL_MS`), and
  /// running that through `TerminalService._setState` would reintroduce the
  /// exact per-byte provider-rebuild cost this branch exists to remove.
  /// Threaded through [copyWith] as the SAME instance, exactly like
  /// [ghostty].
  ///
  /// The view layer owns terminal selection (there is no selection state on
  /// the engine controller itself), and must treat any change here as "the
  /// screen underneath a live selection is now different content" and CLEAR
  /// the selection rather than re-resolve it from row/col anchors that now
  /// point at the wrong glyphs -- Ctrl+C and `SendToAgentButton` read that
  /// selection, and handing the user the wrong text on copy is worse than
  /// losing the selection.
  final ValueNotifier<int> replaceEpoch;

  /// The scrollback this terminal's engine no longer holds.
  ///
  /// Frame mode replaces the whole screen on every frame and keeps nothing
  /// above it, so [ghostty]'s own `maxScrollbackLines` budget goes unused and
  /// the rows that scrolled off live only in the agent's archive. This is the
  /// app's window onto that archive, paged on demand.
  ///
  /// Threaded through [copyWith] as the SAME instance, exactly like [ghostty]
  /// and [replaceEpoch]: a page the user is reading must survive every state
  /// emission, and the boundary arrives on the frame path, which must never
  /// reach `_setState`.
  final TerminalHistoryModel history;

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
    this.mode = TerminalDisplayMode.frame,
    GhosttyTerminalController? ghostty,
    ValueNotifier<int>? replaceEpoch,
    TerminalHistoryModel? history,
  }) : history = history ?? TerminalHistoryModel(),
       ghostty =
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
           ),
       replaceEpoch = replaceEpoch ?? ValueNotifier<int>(0);

  bool get isAgent => type == 'agent';

  TerminalTab copyWith({
    GhosttyTerminalController? ghostty,
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
    TerminalDisplayMode? mode,
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
      mode: mode ?? this.mode,
      ghostty: ghostty ?? this.ghostty,
      replaceEpoch: replaceEpoch,
      history: history,
    );
  }
}

/// How far one terminal has got towards showing the user its screen.
///
/// Two orthogonal facts are folded in here: whether the engine holds bytes, and
/// whether a screen pull is outstanding. The paint decides how the pull reads —
/// an outstanding pull over an engine that already holds current bytes is a
/// routine refresh, not a wait.
enum TerminalAttachStage {
  /// The bridge confirmed the terminal is absent; retain readable content.
  unavailable,

  /// No pull has gone out and nothing has painted.
  cold,

  /// A pull is outstanding and the engine is empty. The user is waiting.
  awaitingScreen,

  /// A pull is outstanding over an engine that already holds current bytes.
  /// Routine: every re-establishment and every mobile focus resume re-pulls
  /// every live tab. Never dimmed, never escalated.
  refreshing,

  /// The engine holds bytes and nothing is outstanding.
  painted,

  /// A pull over an empty engine went unanswered past its bound. Only ever
  /// reachable for a terminal that has never painted.
  failed,

  /// A frame-mode attachment's run completed (`terminal:display:status`
  /// code `ENDED`) rather than failed. Lifecycle, not failure: the pane's
  /// last painted frame IS its true final state, and unlike [failed] it must
  /// never be dimmed or offered a retry. Unreachable in legacy mode, which
  /// has no equivalent notice.
  ended,
}

/// Whether the checkout has enough to show anything at all.
enum CheckoutAttachStatus {
  /// No TerminalService has derived anything yet — the const default of a
  /// TerminalState nobody produced. Renders the neutral empty copy: a stubbed
  /// or absent state must not claim progress it cannot bound, because the
  /// timers that bound it live in the service that does not exist.
  unknown,
  attaching,
  ready,
  failed,
}

class TerminalHydration {
  const TerminalHydration({
    required this.stage,
    this.requestedAtMs,
    this.message,
  });

  final TerminalAttachStage stage;

  /// Epoch ms this client's outstanding pull went out, for an elapsed readout.
  /// An immutable stamp, never a ticking value: the seconds counter lives in a
  /// widget ticker so a 1 Hz rebuild never reaches the terminal beside it.
  final int? requestedAtMs;

  /// The frame protocol's own text for [TerminalAttachStage.failed] /
  /// [TerminalAttachStage.ended] (`terminal:display:status.message`), so the
  /// view layer can show the agent's own reason instead of (or beside) a
  /// generic label. Always null in legacy mode, which has no equivalent.
  final String? message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalHydration &&
          other.stage == stage &&
          other.requestedAtMs == requestedAtMs &&
          other.message == message);

  @override
  int get hashCode => Object.hash(stage, requestedAtMs, message);
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

  /// Per-terminal attach stage, recomputed by `TerminalService._setState` on
  /// every emission — never carried and never copied forward, so no mutation
  /// site can strand a stale one.
  final Map<String, TerminalHydration> hydration;

  /// Whether this checkout has enough to show anything at all. Defaults to
  /// [CheckoutAttachStatus.unknown] so a state nobody derived cannot claim
  /// progress the timers that would bound it are not there to end.
  final CheckoutAttachStatus attach;

  /// True while the transport cannot carry a keystroke. Checkout-wide, because
  /// it is a property of the transport and not of any one terminal.
  final bool inputPaused;

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
    this.hydration = const {},
    this.attach = CheckoutAttachStatus.unknown,
    this.inputPaused = false,
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
    Map<String, TerminalHydration>? hydration,
    CheckoutAttachStatus? attach,
    bool? inputPaused,
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
      hydration: hydration ?? this.hydration,
      attach: attach ?? this.attach,
      inputPaused: inputPaused ?? this.inputPaused,
    );
  }
}
