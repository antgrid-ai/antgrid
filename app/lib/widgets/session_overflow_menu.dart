import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_status_dot.dart';
import '../design/widgets/ab_tap_target.dart';
import '../models/handler_state.dart';
import '../models/workspace_view.dart';
import '../providers/agent_transport.dart';
import '../providers/handler_discovery.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/visible_surface.dart';
import '../util/detached.dart';
import 'handler/handler_arm_explainer.dart';
import 'handler/handler_item_status.dart';
import 'session_mode_control.dart';

/// Identity of the one node in the agent panel that sits under a Carbon scope.
///
/// The panel itself is Antgrid-painted, and a Carbon modal takes its theme from
/// the context that presents it. The arm flow is started from Antgrid surfaces
/// (the session menu), so it presents from this node rather
/// than from its own context.
final handlerSheetHostKeyProvider = Provider<GlobalKey>(
  (ref) => GlobalKey(debugLabel: 'handlerSheetHost'),
);

/// A context under a Carbon scope to present Handler's sheets from, or
/// [fallback] while the panel is not mounted.
BuildContext _handlerSheetHost(
  ProviderContainer container,
  BuildContext fallback,
) => container.read(handlerSheetHostKeyProvider).currentContext ?? fallback;

/// Escalations waiting on sessions OTHER than the focused one, carried with
/// the session a tap on them should land in.
///
/// The Handler tab and the badge over it are both narrowed to the focused
/// session on purpose — see [workspaceBadgesProvider], which explains why a
/// project-wide count there would send the user to a tab narrowed past the
/// escalation it promised. That leaves a sibling's unanswered question with
/// nothing to speak for it in the header, and this is what does: the count
/// travels WITH its target precisely because the only surface allowed to name
/// it is one that moves focus to the session it counted on the way in.
///
/// The target is the first escalation belonging to another session, taken in
/// `state.escalations` order — `compareEscalations` bands that list by
/// urgency, so the tap lands on the most urgent sibling rather than merely the
/// oldest one.
typedef _OtherSessionEscalations = ({int count, String? target});

/// A record, so the fresh value built here compares by VALUE and a rebuild of
/// the unnarrowed handler state notifies nothing unless the count or the
/// target actually moved — the same churn guard [workspaceBadgesProvider]
/// documents.
final _otherSessionEscalationsProvider = Provider<_OtherSessionEscalations>((
  ref,
) {
  final activeId = ref.watch(activeSessionIdProvider);
  final state =
      ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
  final own = activeId == null
      ? 0
      : state.sessions[activeId]?.pendingEscalations ?? 0;
  final count = state.pendingEscalations - own;
  if (count <= 0) return (count: 0, target: null);
  return (
    count: count,
    target: state.escalations
        .firstWhereOrNull((e) => e.terminalId != activeId)
        ?.terminalId,
  );
});

/// The project-wide half of the Handler's attention, as an ACTION rather than
/// the status pill it used to be.
///
/// Earns its place in an action menu by moving focus to the session it counted
/// before landing, which is the whole reason a count this wide is allowed to
/// exist anywhere: the Handler tab renders one session, so a number naming the
/// rest has to bring that session with it or it opens a tab that cannot
/// account for what it promised.
class _OtherSessionsMenuItem extends ConsumerWidget {
  const _OtherSessionsMenuItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(_otherSessionEscalationsProvider);
    if (waiting.count == 0) return const SizedBox.shrink();

    void go() {
      // The popup route closes first — its own doc says the content pops
      // itself — and everything past the pop runs on the container rather than
      // this widget's ref, the same contract [_HandlerMenuItem.toggleArm] has.
      final container = ref.container;
      Navigator.of(context).pop();
      // Every branch below lands on the Handler tab, by handover or by call,
      // so a pending agent-page stamp left by an earlier navigation must not
      // survive any of them: its drain runs last and would override the tab.
      container.read(pendingAgentPageProvider.notifier).set(null);
      final target = waiting.target;
      if (target == null) {
        container
            .read(revealWorkspaceViewControlProvider)
            ?.call(WorkspaceView.handler);
        return;
      }
      container.read(activeSessionIdProvider.notifier).set(target);
      // Read back rather than assumed: `ActiveSessionId.set` REFUSES a session
      // the bridge is already deleting, and such a session keeps its replayed
      // escalations for the seconds before its row goes. Focus then stays put,
      // and the handover below would stamp the session still in focus with a
      // destination picked for a different one.
      if (container.read(activeSessionIdProvider) != target) {
        container
            .read(revealWorkspaceViewControlProvider)
            ?.call(WorkspaceView.handler);
        return;
      }
      // A focus change cannot reveal the tab by calling: moving focus arms
      // WorkspaceShell's per-session UI restore, which re-applies the TARGET
      // session's own saved workspace tab from a post-frame callback, and any
      // tab selected before that lands is silently undone by it. Handed over
      // as pending state instead — the same handover a deep link naming a view
      // uses, drained by the shell after the restore.
      container.read(pendingWorkspaceViewProvider.notifier).set((
        target: container.read(selectedTargetProvider),
        value: WorkspaceView.handler,
      ));
    }

    return AbLiveMenuRow(
      label: waiting.count == 1
          ? 'Answer another session'
          : 'Answer ${waiting.count} in other sessions',
      icon: AbIcons.bell,
      tooltip: waiting.count == 1
          ? 'Handler is waiting on an answer in a session that is not in '
                'focus.'
          : 'Handler is waiting on ${waiting.count} answers in sessions that '
                'are not in focus.',
      onTap: go,
    );
  }
}

/// Overflow trigger for everything about the session that has no inline home:
/// the terminal/chat mode switch, the Handler arm/disarm row and this session's
/// controls. On a phone (see the comment above its call site in
/// `AgentPanel.build`) it also takes the branch pill, which competes with the
/// session title for the one flexible slot at that width; `AgentBar` has room
/// to keep the pill inside
/// [TitleBarBreadcrumb] instead, so the same kebab there opens a shorter menu.
/// Mounted unconditionally on both breakpoints — the mode switch and Handler
/// row are always present, so every session has a kebab.
class SessionOverflowButton extends ConsumerWidget {
  const SessionOverflowButton({super.key, required this.compact});

  /// True for the phone header. Both breakpoints open the same menu with the
  /// same rows; this only decides whether the branch also renders there as a
  /// header label — on `AgentBar`
  /// the branch stays inline in [TitleBarBreadcrumb], so restating it in the
  /// menu would give it two homes.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The menu is closed by default, so a row inside it cannot call for
    // attention by itself. This dot is what the inline pill used to be: the
    // always-visible sign that something behind the kebab is waiting. ONLY an
    // escalation earns it — a person is stopped until it is answered. Mail from
    // another session deliberately does not: the bus is agent-to-agent, nobody
    // is blocked on the human, and a dot for it would ask for attention that
    // the exchange never needed.
    final waiting = ref.watch(_otherSessionEscalationsProvider).count;
    final button = Builder(
      // AbCompactTapTargets: the toolbar row already owns its height, so the
      // button's mobile tap-target inflation (24px visual -> 44px hit box)
      // must not widen the box this anchors the popup to — without it the
      // popup opened ~10px below where the icon actually sits, reading as a
      // stray gap between the kebab and the menu instead of Chrome's flush
      // hang-under.
      builder: (anchor) => AbCompactTapTargets(
        // Positioned rather than laid out beside the icon, so the dot never
        // widens the box abMenuAnchorRect measures off this Builder and the
        // popup keeps hanging flush under the kebab.
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            AbIconButton(
              icon: AbIcons.more,
              tooltip: 'Session options',
              onTap: () => detached(
                'AgentPanel',
                'session overflow menu failed',
                () => _open(anchor),
              ),
            ),
            if (waiting > 0)
              const Positioned(
                right: -1,
                top: -1,
                child: AbStatusDot(
                  key: Key('session-attention-dot'),
                  tone: AbStatusTone.agentAttention,
                ),
              ),
          ],
        ),
      ),
    );
    // The leading gap belongs to this button rather than to the bar: on
    // desktop it sits directly after WorkspaceMenuButton with no bar-level
    // spacer between them, and the button — not the bar — is the one that
    // knows it needs its own.
    return compact
        ? button
        : Padding(
            padding: const EdgeInsets.only(left: AbTokens.space6),
            child: button,
          );
  }

  Future<void> _open(BuildContext anchor) async {
    final anchorRect = abMenuAnchorRect(anchor);
    if (anchorRect == null) return;
    await showAbPanel<void>(
      context: anchor,
      anchorRect: anchorRect,
      width: 220,
      // Tight, hanging right under the button — the Chrome kebab-menu look —
      // rather than the wider 4px default gap other (non-adjacent) popups use.
      gap: 2,
      preferred: AbMenuPlacement.below,
      builder: (_) => _SessionOverflowMenu(compact: compact),
    );
  }
}

/// The overflow popup's content: the mode switch, the Handler arm/disarm row
/// and the session directory, rather than the header's own
/// button/segmented-control chrome. On a
/// phone this is preceded by the branch as a menu header (Chrome's own
/// tab-context-menu convention — the thing the menu
/// is ABOUT, named once at the top); on `AgentBar` the branch stays inline in
/// [TitleBarBreadcrumb] instead, so this menu opens straight into the mode
/// switch. [AbLiveMenuRow] is what a menu row that has to watch a provider
/// renders as — see its doc for why a static [AbMenuItem] can't do this.
class _SessionOverflowMenu extends ConsumerWidget {
  const _SessionOverflowMenu({required this.compact});

  /// See [SessionOverflowButton.compact]. Gates only the branch header label
  /// — every row below it renders on both breakpoints, since none has an
  /// inline home on `AgentBar` any more than on the phone header.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(terminalStateProvider).value?.gitBranch;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (compact && branch != null) AbMenuHeaderLabel(branch),
        const SessionModeMenuItem(),
        const _HandlerMenuItem(),
        const _OtherSessionsMenuItem(),
        const _TerminalClipboardMenuItems(),
      ],
    );
  }
}

/// Attach file, Select text, Paste and Copy host clipboard for the agent
/// terminal. Absent when nothing is published, i.e. a session without a terminal
/// on screen.
class _TerminalClipboardMenuItems extends ConsumerWidget {
  const _TerminalClipboardMenuItems();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(terminalClipboardActionsProvider);
    if (actions == null) return const SizedBox.shrink();
    final copyHost = actions.copyHostClipboard();
    final attach = actions.attach();

    // The popup closes first so the action lands on the terminal, not under a
    // modal barrier — the contract the rows above keep.
    VoidCallback closing(VoidCallback action) => () {
      Navigator.of(context).pop();
      action();
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (attach != null)
          AbLiveMenuRow(
            label: 'Attach file',
            icon: AbIcons.attach,
            tooltip: 'Attach a file for the agent.',
            onTap: closing(attach),
          ),
        AbLiveMenuRow(
          label: 'Select text',
          icon: AbIcons.selectText,
          onTap: closing(actions.selectText),
        ),
        AbLiveMenuRow(
          label: 'Paste',
          icon: AbIcons.paste,
          onTap: closing(actions.paste),
        ),
        if (copyHost != null)
          AbLiveMenuRow(
            label: 'Copy host clipboard',
            icon: AbIcons.copy,
            tooltip: 'Copy the host machine\'s clipboard to this device.',
            onTap: closing(copyHost),
          ),
      ],
    );
  }
}

/// The Handler arm/disarm action as a single text row. The session's status is
/// not restated here: it stays reachable from the panel's own escalation card,
/// the Handler tab, and the transcript's away-hint/PA bar, and a Chrome-style
/// action menu holds actions only.
class _HandlerMenuItem extends ConsumerWidget {
  const _HandlerMenuItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(activeSessionIdProvider);
    if (activeId == null) return const SizedBox.shrink();

    final state =
        ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
    final armed = state.sessions[activeId] != null;
    final service = serviceWhenReady(ref, handlerServiceProvider);
    // Pre-arm coverage prediction — same shared derivation the away hint
    // and the explainer use, so this row never disagrees with them.
    final coverage = ref.watch(focusedSessionCoverageProvider);

    void toggleArm() {
      if (service == null) return;
      // The popup route closes first — its own doc says the content pops
      // itself — or the menu stays up over the session it just changed,
      // showing the stale label, and the explainer below opens over a live
      // modal barrier. Both the explainer's anchor and the container are taken
      // from surfaces that outlive the popped route.
      final navigator = Navigator.of(context);
      final host = navigator.context;
      final container = ref.container;
      navigator.pop();
      if (armed) {
        service.disarm(activeId);
        return;
      }
      // Fire-and-forget: past the explainer await everything runs on the
      // container, never this widget's ref.
      unawaited(
        armWithSheet(
          context: _handlerSheetHost(container, host),
          container: container,
          terminalId: activeId,
          agentObservable: coverage.observable,
          agentLabel: coverage.agentLabel,
          judgeCapable: coverage.judgeCapable,
        ),
      );
    }

    // A refusal outranks the coverage notice, the order `handlerShieldTooltip`
    // uses: coverage describes what an arm would get, and a
    // refusal decides whether one can happen at all.
    String? tooltip() {
      if (armed) return null;
      final entitlement = state.entitlement;
      if (entitlement != null) return handlerEntitlementNotice(entitlement);
      // Arming an unwatchable agent still works (it just never leaves
      // WATCHING) — the tooltip explains why rather than blocking the tap.
      if (coverage.observable == false) {
        return unwatchableNotice(coverage.agentLabel);
      }
      return null;
    }

    return AbLiveMenuRow(
      label: armed ? 'Disarm Handler' : 'Arm Handler',
      icon: AbIcons.shield,
      tooltip: tooltip(),
      onTap: toggleArm,
    );
  }
}
