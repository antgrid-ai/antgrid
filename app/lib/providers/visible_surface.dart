import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ab_message.dart' show GitFileStatusEntry;
import '../models/pending_nav.dart';
import '../models/workspace_view.dart';
import 'providers.dart';
import 'value_controller.dart';

/// Which workspace tab is actually ON SCREEN, or null when none is.
///
/// [WorkspacePanel] renders all five tabs inside an `IndexedStack`, so every
/// tab's widgets stay mounted and their state (an open file, a diff, a pushed
/// terminal) survives a tab switch. A back handler registered by an offscreen
/// tab would otherwise silently mutate it. Handlers gate on this.
///
/// Null folds together every way a workspace tab can be absent: the New Session
/// route is mounted, a workbench surface overlays the workspace, mobile is on
/// the agent page, or desktop has the context panel hidden.
///
/// Grouped here with the rest of the workspace-view state
/// ([workspaceBadgesProvider], [workspaceMenuControlProvider]) rather than in
/// `ui_attention_providers.dart`, which holds the surface/lifecycle attention
/// state.
final visibleWorkspaceViewProvider =
    NotifierProvider<ValueController<WorkspaceView?>, WorkspaceView?>(
      () => ValueController(null),
    );

/// A workspace tab a navigation named, waiting for WorkspaceShell to show it.
///
/// The nav layer cannot reveal a view itself: [workspaceMenuControlProvider]'s
/// `reveal` is null whenever the shell is unmounted and always on mobile, and a
/// deep link can arrive before the shell mounts at all. Same handover as
/// `pendingActiveSessionIdProvider` — the shell drains it on mount and on
/// change, and clears it on consumption.
///
/// Also the only safe way to reveal a view in the same turn as a SESSION
/// switch, which is why the agent bar's NEEDS YOU pill writes here rather than
/// calling `revealHandlerTab`: a focus change arms the shell's per-session UI
/// restore, and that restore re-applies the target session's own saved tab
/// after any tab the caller selected first. The drain runs after it.
///
/// Null is a written value, not just an absence: a location naming no view
/// writes null so a view left pending by an earlier one is dropped rather than
/// applied to this destination. The [PendingNav] stamp covers the other half —
/// a project switch that never goes through the nav layer at all, and it is
/// what lets a second writer be added safely.
final pendingWorkspaceViewProvider =
    NotifierProvider<
      ValueController<PendingNav<WorkspaceView>?>,
      PendingNav<WorkspaceView>?
    >(() => ValueController(null));

/// A file a navigation named, waiting for the file explorer to open it.
///
/// Grouped with [pendingWorkspaceViewProvider] because a file is only reachable
/// through [WorkspaceView.files], and handed over the same way for the same
/// reason: a link can land before the explorer — or the project's FileService —
/// exists, so there is nothing for the nav layer to call.
///
/// The path is CHECKOUT-relative. `FileExplorerScreen` resolves it against the
/// focused checkout's FileService, so an isolated session opens the file in its
/// own worktree; `navLocationFromUri` has already refused anything that could
/// climb out of that checkout.
///
/// Null is a written value, not just an absence — as for the pending view, and
/// stamped with its project for the same reason.
final pendingFilePathProvider =
    NotifierProvider<ValueController<PendingNav<String>?>, PendingNav<String>?>(
      () => ValueController(null),
    );

/// Counts the workspace views advertise on their tab: unstaged git files, and
/// escalations the handler is waiting on.
///
/// Both are scoped to what their tab actually shows — the focused checkout for
/// git, the focused session for the handler. A handler badge counting the whole
/// project would send the user to a tab narrowed past the escalation it
/// promised; the agent bar's NEEDS YOU pill is what carries the project-wide
/// count, and it moves focus to the session it counted on the way in.
///
/// A provider rather than a WorkspaceShell method because the agent bar's
/// workspace menu lists the same views from outside that State, and a menu that
/// disagreed with the tab strip about how many files changed would be worse than
/// no badge at all.
final workspaceBadgesProvider = Provider<Map<WorkspaceView, int>>((ref) {
  // `.select` so this provider only recomputes when the derived COUNT changes,
  // not on every fileTreeStateProvider/handlerStateProvider emission — a plain
  // `.watch` rebuilt WorkspaceMenuPanel and WorkspaceShellState.build() on any
  // file-tree or handler-state churn, since the fresh `Map` literal returned
  // below is never `==` to the last one and so always notified. Same hazard,
  // same fix as [workspaceMenuControlProvider]'s doc.
  final gitCount = ref.watch(
    fileTreeStateProvider.select((s) => s.value?.gitFileStatuses.length ?? 0),
  );
  // Off the narrowed state rather than a second `sessions[activeId]` lookup of
  // its own: the tab and its badge must never be able to answer differently
  // about what the tab holds, and one narrowing rule is what guarantees it.
  final pending = ref.watch(
    focusedSessionHandlerStateProvider.select((s) => s.pendingEscalations),
  );
  return {
    if (gitCount > 0) WorkspaceView.git: gitCount,
    if (pending > 0) WorkspaceView.handler: pending,
  };
});

/// Lines added and removed across the whole worktree vs HEAD.
///
/// A record, not a class, so the `.select` below compares by VALUE — a fresh
/// object per emission would notify on every file-tree message, the same churn
/// [workspaceBadgesProvider] documents.
typedef GitDiffTotals = ({int additions, int deletions});

/// The worktree's total +/-, for the workspace menu's Git row (the tab strip
/// keeps its file count) and, recomputed from the same rule, the git panel's
/// changes header.
///
/// Sums over DISTINCT paths: a file changed on both sides has a staged and an
/// unstaged entry carrying the SAME combined-vs-HEAD counts (the bridge
/// computes one diff per path), so summing entries doubles it.
final gitDiffTotalsProvider = Provider<GitDiffTotals>((ref) {
  return ref.watch(
    fileTreeStateProvider.select((s) {
      final entries = s.value?.gitFileEntries;
      if (entries == null || entries.isEmpty) {
        return (additions: 0, deletions: 0);
      }
      final perPath = <String, GitFileStatusEntry>{};
      for (final e in entries) {
        perPath.putIfAbsent(e.path, () => e);
      }
      var additions = 0;
      var deletions = 0;
      for (final e in perPath.values) {
        additions += e.additions;
        deletions += e.deletions;
      }
      return (additions: additions, deletions: deletions);
    }),
  );
});

/// What the agent bar's workspace menu needs to render and act, or null when
/// this route has no workspace to reveal (the New Session route, or a workbench
/// surface covering it) — which is what hides the control there.
///
/// Published by WorkspaceShell for the same reason as
/// [contextPanelControlProvider]: the menu is mounted inside the agent bar,
/// which cannot reach that State.
///
/// Deliberately carries no badge map: this record is re-published from a
/// post-frame callback on every build, and a fresh `Map` is never `==` to the
/// last one, so it would notify → rebuild → notify forever. Badges come from
/// [workspaceBadgesProvider] instead. `reveal` is safe here because a tear-off
/// of the same instance method on the same object compares equal.
typedef WorkspaceMenuControl = ({
  /// The view on screen right now — a context-panel tab, or the chat-mode
  /// floating card — so the menu can mark it. Null when none is up.
  WorkspaceView? active,
  void Function(WorkspaceView) reveal,
});

final workspaceMenuControlProvider =
    NotifierProvider<
      ValueController<WorkspaceMenuControl?>,
      WorkspaceMenuControl?
    >(() => ValueController(null));

/// Whether the agent bar's workspace rail is up. Shared by a mouse desktop and
/// a touch tablet, whose context panel is a docked pane beside the agent
/// (`WorkspaceShellState._buildTabletTouch`) rather than an overlay covering
/// it. (Mobile phone width never reads this at all — `WorkspaceMenuButton`
/// renders nothing there; see [workspaceMenuControlProvider].)
///
/// Defaults to OPEN, but the shell holds it down for as long as the context
/// pane is on screen — the pane's own [WorkspaceTabBar] lists the same five
/// views, so the rail would be a second switcher floating over the transcript
/// (`WorkspaceShellState._syncMenuToContextPane`). On a mouse desktop, whose
/// pane starts open, that means the rail's first appearance is the first time
/// the user closes the pane. The icon still takes it away by hand.
///
/// App state rather than the button's own `State` because the button does not
/// survive the thing this flag controls: a workbench surface takes the whole
/// agent bar off screen, and the shell swaps `WorkspaceShell` out entirely on
/// the way to a new session. A flag held in the widget would die with the bar
/// and come back at its default, so the rail could neither stay down where the
/// user shut it nor come back up where they left it. Held here, the button
/// resolves the rail's state against this on its next mount — which is also why
/// `WorkspaceShellState._menuAutoHidden`, and not this value, is what says
/// whether the shell may reopen it.
final workspaceMenuOpenProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(true),
);
