import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../models/handler_state.dart';
import '../models/workspace_view.dart';
import '../providers/agent_transport.dart';
import '../providers/handler_discovery.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/visible_surface.dart';
import 'handler/handler_arm_explainer.dart';
import 'session_mode_control.dart';

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
CarbonMenuEntry? _otherSessionsEntry(WidgetRef ref) {
  final waiting = ref.watch(_otherSessionEscalationsProvider);
  if (waiting.count == 0) return null;
  // Everything the row does runs on the container rather than this build's
  // ref, the same contract [_handlerEntry] has.
  final container = ref.container;

  void go() {
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

  return CarbonMenuItem(
    label: waiting.count == 1
        ? 'Answer another session'
        : 'Answer ${waiting.count} in other sessions',
    icon: const CarbonIcon(CarbonIcons.notification),
    onPressed: go,
  );
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
class SessionOverflowButton extends StatelessWidget {
  const SessionOverflowButton({super.key, required this.compact});

  /// True for the phone header. Both breakpoints open the same menu with the
  /// same rows; this only decides whether the branch also renders there as a
  /// menu heading — on `AgentBar` the branch stays inline in
  /// [TitleBarBreadcrumb], so restating it in the menu would give it two
  /// homes.
  final bool compact;

  @override
  Widget build(BuildContext context) => AbCarbonScope(
    // The leading gap belongs to this button rather than to the bar: on
    // desktop it sits directly after WorkspaceMenuButton with no bar-level
    // spacer between them, and the button — not the bar — is the one that
    // knows it needs its own.
    child: Padding(
      padding: EdgeInsets.only(left: compact ? 0 : CarbonSpacing.spacing03),
      child: _SessionOverflowMenu(compact: compact),
    ),
  );
}

/// The kebab and its rows. The entries are built here, inside the consumer
/// that owns the trigger, so a provider change rebuilds them and an open menu
/// follows live state.
///
/// Rows that present UI do so from this widget's context, which sits under the
/// Carbon scope and outlives the menu: [CarbonMenuItem.onPressed] runs after
/// the menu has closed, and the menu is an overlay rather than a route, so no
/// row pops anything.
class _SessionOverflowMenu extends ConsumerWidget {
  const _SessionOverflowMenu({required this.compact});

  /// See [SessionOverflowButton.compact]. Gates only the branch heading — every
  /// row below it renders on both breakpoints, since none has an inline home on
  /// `AgentBar` any more than on the phone header.
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
    final branch = ref.watch(terminalStateProvider).value?.gitBranch;
    final rows = <CarbonMenuEntry>[
      ?sessionModeMenuEntry(context, ref),
      ?_handlerEntry(context, ref),
      ?_otherSessionsEntry(ref),
      ..._terminalClipboardEntries(ref),
    ];
    return CarbonOverflowMenu(
      semanticLabel: 'Session options',
      // Same fact in the same colour as the drawer's Handler count.
      badgeCount: waiting > 0 ? 0 : null,
      badgeTone: CarbonBadgeTone.brand,
      entries: [
        if (compact && branch != null)
          CarbonMenuGroup(label: branch, children: rows)
        else
          ...rows,
      ],
    );
  }
}

/// Attach file, Select text, Paste and Copy host clipboard for the agent
/// terminal. Absent when nothing is published, i.e. a session without a terminal
/// on screen.
List<CarbonMenuEntry> _terminalClipboardEntries(WidgetRef ref) {
  final actions = ref.watch(terminalClipboardActionsProvider);
  if (actions == null) return const [];
  final copyHost = actions.copyHostClipboard();
  final attach = actions.attach();
  return [
    if (attach != null)
      CarbonMenuItem(
        label: 'Attach file',
        icon: const CarbonIcon(CarbonIcons.attachment),
        onPressed: attach,
      ),
    CarbonMenuItem(
      label: 'Select text',
      icon: const CarbonIcon(CarbonIcons.stringText),
      onPressed: actions.selectText,
    ),
    CarbonMenuItem(
      label: 'Paste',
      icon: const CarbonIcon(CarbonIcons.paste),
      onPressed: actions.paste,
    ),
    if (copyHost != null)
      CarbonMenuItem(
        label: 'Copy host clipboard',
        icon: const CarbonIcon(CarbonIcons.copy),
        onPressed: copyHost,
      ),
  ];
}

/// The Handler arm/disarm action as a single text row. The session's status is
/// not restated here: it stays reachable from the panel's own escalation card,
/// the Handler tab, and the transcript's away-hint/PA bar, and a Chrome-style
/// action menu holds actions only.
///
/// The row carries no hover hint: the entitlement refusal and the
/// unwatchable-agent notice are both repeated by the arm sheet it opens.
CarbonMenuEntry? _handlerEntry(BuildContext context, WidgetRef ref) {
  final activeId = ref.watch(activeSessionIdProvider);
  if (activeId == null) return null;

  final state =
      ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
  final armed = state.sessions[activeId] != null;
  final service = serviceWhenReady(ref, handlerServiceProvider);
  // Pre-arm coverage prediction — same shared derivation the away hint
  // and the explainer use, so this row never disagrees with them.
  final coverage = ref.watch(focusedSessionCoverageProvider);
  final container = ref.container;

  void toggleArm() {
    if (service == null) return;
    if (armed) {
      service.disarm(activeId);
      return;
    }
    // Fire-and-forget: past the explainer await everything runs on the
    // container, never this build's ref. The sheets present from the kebab's
    // own context, so a header swap (rotation, unfold) while one is up
    // disposes it and the flow ends at its `context.mounted` check.
    unawaited(
      armWithSheet(
        context: context,
        container: container,
        terminalId: activeId,
        agentObservable: coverage.observable,
        agentLabel: coverage.agentLabel,
        judgeCapable: coverage.judgeCapable,
      ),
    );
  }

  return CarbonMenuItem(
    label: armed ? 'Disarm Handler' : 'Arm Handler',
    icon: const CarbonIcon(CarbonIcons.security),
    onPressed: toggleArm,
  );
}
