import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// Null is a written value, not just an absence: a location naming no view
/// writes null so a view left pending by an earlier one is dropped rather than
/// applied to this destination. The [PendingNav] stamp covers the other half —
/// a project switch that never goes through the nav layer at all.
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
    NotifierProvider<
      ValueController<PendingNav<String>?>,
      PendingNav<String>?
    >(() => ValueController(null));

/// Counts the workspace views advertise on their tab: unstaged git files, and
/// escalations the handler is waiting on.
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
    fileTreeStateProvider.select(
      (s) => s.value?.gitFileStatuses.length ?? 0,
    ),
  );
  final pending = ref.watch(
    handlerStateProvider.select((s) => s.value?.pendingEscalations ?? 0),
  );
  return {
    if (gitCount > 0) WorkspaceView.git: gitCount,
    if (pending > 0) WorkspaceView.handler: pending,
  };
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

/// Whether the agent bar's workspace menu is up. Defaults to OPEN: the five
/// views are on screen the moment a session is, and the icon is the only thing
/// that takes them away.
///
/// App state rather than the button's own `State` because the button does not
/// survive the thing its menu does. Revealing a view replaces the agent panel,
/// which unmounts the bar the button lives in; a flag held in the widget would
/// die with it and come back closed, so the menu would silently shut itself
/// every time it was used. Held here, the button re-opens the menu as soon as it
/// is mounted again.
final workspaceMenuOpenProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(true),
);
