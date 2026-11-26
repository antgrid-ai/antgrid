import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/pending_nav.dart';
import '../models/workspace_view.dart';
import 'agent_transport.dart' show selectedTargetProvider;
import 'providers.dart';
import 'session_bus_inbox.dart';
import 'sessions.dart' show activeSessionIdProvider;
import 'value_controller.dart';

/// Which workspace tab is actually ON SCREEN, or null when none is.
///
/// [WorkspacePanel] renders every tab inside an `IndexedStack`, so every tab's
/// widgets stay mounted and their state (an open file, a diff, a pushed
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
/// switch, which is why the session kebab's attention row writes here rather
/// than calling [revealWorkspaceViewControlProvider]: a focus change arms the
/// shell's per-session UI restore, and that restore re-applies the target
/// session's own saved tab after any tab the caller selected first. The drain
/// runs after it.
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

/// The agent transcript a navigation named, waiting for WorkspaceShell to show
/// it.
///
/// [WorkspaceView] has no agent member — the transcript is not a workspace tab
/// — so a route that wants it cannot go through [pendingWorkspaceViewProvider],
/// and `switchToAgentProvider` is null whenever the shell is between mounts.
/// Same handover, same [PendingNav] stamp, drained beside the view.
///
/// The value is always true: what is carried is the REQUEST, and the stamp is
/// what makes it self-invalidating, exactly as for the pending view.
final pendingAgentPageProvider =
    NotifierProvider<ValueController<PendingNav<bool>?>, PendingNav<bool>?>(
      () => ValueController(null),
    );

/// Reveals the Handler tab right now, for a caller with no session switch to
/// make.
///
/// The pending agent-page stamp is cleared first and that order is the whole
/// point of the function: the shell drains that stamp LAST, so a request left
/// by an earlier navigation would override the tab this just revealed. Every
/// caller owes that clear, and a second hand-written copy of the pair is where
/// one of them stops owing it.
///
/// The other half of the handover — the one that DOES move focus — belongs to
/// `AgentPanel.openHandler`, which writes [pendingWorkspaceViewProvider]
/// instead for the reason spelled out there.
void revealHandlerTabNow(WidgetRef ref) {
  ref.read(pendingAgentPageProvider.notifier).set(null);
  ref.read(revealWorkspaceViewControlProvider)?.call(WorkspaceView.handler);
}

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

/// The focused session's mailbox, or an empty one while no session is focused.
///
/// One narrowing rule for everything that speaks for the focused session's bus
/// state. Two lookups of their own could answer differently about the same
/// mailbox, which is the failure [workspaceBadgesProvider] already narrows the
/// handler count to avoid.
final focusedSessionInboxProvider = Provider<SessionInboxState>((ref) {
  final sessionId = ref.watch(activeSessionIdProvider);
  if (sessionId == null) return const SessionInboxState();
  return ref.watch(sessionInboxProvider(sessionId));
}, name: 'focusedSessionInbox');

/// Whether the focused session has bus traffic to show — the ONE rule behind
/// the session kebab's Messages row, which is the only door to the mailbox
/// sheet. Nothing else announces a peer's mail.
///
/// A session that has only ever sent still fails it. The app's two reads are
/// the mailbox and one thread by id, and a thread id is reachable only from an
/// inbound post, so there is nothing to open; `session-bus:threads` is the read
/// that would fix it, and until it exists a row here would promise a sheet with
/// nothing in it.
///
/// LATCHING, and this is the whole reason it is a notifier rather than a
/// derived value: the mailbox empties when the AGENT reads its mail, which can
/// land while the menu is open and the user is reaching for the row. A row that
/// vanished under the pointer would take the sheet with it. The latch is
/// dropped when focus moves to another session, and again whenever this
/// provider itself is rebuilt.
class SessionBusActivity extends Notifier<bool> {
  String? _sessionId;
  bool _seen = false;

  @override
  bool build() {
    final sessionId = ref.watch(activeSessionIdProvider);
    if (sessionId != _sessionId) {
      _sessionId = sessionId;
      _seen = false;
    }
    if (sessionId == null) return false;
    // `dropped` is a lifetime total on the store, so the two together answer
    // "has this session ever been on the bus" rather than "does it have mail
    // right now" — which is the question the row is for, since a sheet is worth
    // opening for a receipt on something already read.
    final active = ref.watch(
      focusedSessionInboxProvider.select(
        (s) => s.dropped > 0 || s.posts.isNotEmpty,
      ),
    );
    if (active) _seen = true;
    return _seen;
  }
}

final sessionHasBusActivityProvider =
    NotifierProvider<SessionBusActivity, bool>(
      SessionBusActivity.new,
      name: 'sessionHasBusActivity',
    );

/// The workspace tabs on offer right now, in tab order.
///
/// One provider rather than [WorkspaceView.values] at each of the three
/// surfaces that render the tabs (the desktop tab strip, the phone's bottom
/// nav, the agent bar's workspace rail): they must never disagree, and a
/// condition written into each of them is the bug — an item that appeared on
/// the phone and nowhere else would ship green, because nothing iterating that
/// enum is under test.
///
/// Handler is the conditional view: offered only while the focused session is
/// armed, or has a Handler question of its own still waiting. Disarming hides
/// it at once — a pane showing it falls back to Files. Matched on the session's
/// own id, so another session's Handler never puts the tab here.
///
/// A Handler state that has not been [HandlerState.heard] says nothing about
/// arming, so it keeps the last answer for the same session instead: a host
/// restart or a Retry builds the project a fresh, empty service, and reading
/// that as a disarm blinks the tab away until the first status lands.
final visibleWorkspaceViewsProvider =
    NotifierProvider<_VisibleWorkspaceViews, List<WorkspaceView>>(
      _VisibleWorkspaceViews.new,
      name: 'visibleWorkspaceViews',
    );

/// One shared instance, as [WorkspaceView.values] is for the other branch: a
/// fresh list is never `==` to the last one, so a rebuild that leaves the
/// Handler hidden would still notify every surface rendering the tabs.
final _withoutHandler = List<WorkspaceView>.unmodifiable([
  for (final v in WorkspaceView.values)
    if (v != WorkspaceView.handler) v,
]);

class _VisibleWorkspaceViews extends Notifier<List<WorkspaceView>> {
  String? _answeredFor;
  bool _handlerShown = false;

  @override
  List<WorkspaceView> build() {
    final activeId = ref.watch(activeSessionIdProvider);
    final handler = ref.watch(
      handlerStateProvider.select((v) {
        final s = v.value;
        if (s == null) return (on: false, heard: false);
        final on =
            activeId != null &&
            (s.sessions.containsKey(activeId) ||
                s.escalations.any((e) => e.terminalId == activeId));
        return (on: on, heard: s.heard);
      }),
    );
    final held = !handler.heard && _answeredFor == activeId && _handlerShown;
    _answeredFor = activeId;
    _handlerShown = handler.on || held;
    return _handlerShown ? WorkspaceView.values : _withoutHandler;
  }
}

/// Counts the workspace views advertise on their tab: unstaged git files, and
/// escalations the handler is waiting on.
///
/// Both are scoped to what their tab actually shows — the focused checkout for
/// git, the focused session for the handler. A handler badge counting the whole
/// project would send the user to a tab narrowed past the escalation it
/// promised; the session kebab's attention row is what carries the project-wide
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
    focusedSessionHandlerStateProvider.select((s) => s.escalationBadgeCount),
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
/// keeps its file count) and the git panel's changes header, both read off
/// `GitStatusIndex`.
final gitDiffTotalsProvider = Provider<GitDiffTotals>((ref) {
  return ref.watch(
    fileTreeStateProvider.select((s) {
      final index = s.value?.gitStatus;
      if (index == null) return (additions: 0, deletions: 0);
      return (additions: index.additions, deletions: index.deletions);
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

/// The mounted shell's own "show this tab" — selects it, opens whatever pane
/// holds it, and on a phone swipes the workspace page forward. Published by
/// WorkspaceShell in every layout and retracted when it deactivates, because
/// it closes over that State.
final revealWorkspaceViewControlProvider =
    NotifierProvider<
      ValueController<void Function(WorkspaceView)?>,
      void Function(WorkspaceView)?
    >(() => ValueController(null));

/// Brings [view] forward from inside the workspace, for a tap the user just
/// made. Straight through the shell when one is mounted: the pending handover
/// below exists for navigations that land before a shell can act, and it holds
/// a request back while a queued session id resolves, which a tap on an open
/// workspace has no reason to wait on.
void revealWorkspaceView(WidgetRef ref, WorkspaceView view) {
  final reveal = ref.read(revealWorkspaceViewControlProvider);
  if (reveal != null) {
    reveal(view);
    return;
  }
  ref.read(pendingWorkspaceViewProvider.notifier).set((
    target: ref.read(selectedTargetProvider),
    value: view,
  ));
}

/// Whether the agent bar's workspace rail is up. Shared by a mouse desktop and
/// a touch tablet, whose context panel is a docked pane beside the agent
/// (`WorkspaceShellState._buildTabletTouch`) rather than an overlay covering
/// it. (Mobile phone width never reads this at all — `WorkspaceMenuButton`
/// renders nothing there; see [workspaceMenuControlProvider].)
///
/// Defaults to OPEN, but the shell holds it down for as long as the context
/// pane is on screen — the pane's own [WorkspaceTabBar] lists the same
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
