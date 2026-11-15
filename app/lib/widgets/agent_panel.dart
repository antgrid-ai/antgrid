
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_carbon.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/ab_message.dart' show createAbMessage;
import '../models/device_stats.dart';
import '../project/project_session_registry.dart';
import '../providers/account_agents.dart';
import '../providers/agent_coordinates.dart';
import '../providers/agent_transport.dart';
import '../providers/demo_mode.dart';
import '../providers/device_provisioning.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/recent_agents.dart';
import '../providers/session_mode.dart';
import '../providers/sessions.dart';
import '../screens/terminal_screen.dart';
import '../util/device_id.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'agent_transcript_view.dart';
import 'command_bar.dart';
import 'command_output_overlay.dart';
import 'handler/handler_away_hint.dart';
import 'handler/handler_escalation_overlay.dart';
import 'handler/handler_layout.dart';
import 'handler/handler_pa_bar.dart';
import 'remote_access_control.dart';
import 'remote_host_chip.dart';
import 'session_agent_mark.dart';
import 'session_approval_badge.dart';
import 'workspace_tab_bar.dart' show workspaceStripHeight;
import 'session_setup_banner.dart';
import 'workspace_menu_button.dart';
import 'display_visibility.dart';
import 'workspace_readiness_chip.dart';
import 'session_breadcrumb.dart';
import 'session_overflow_menu.dart';

class AgentPanel extends ConsumerWidget {
  const AgentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The transcript is addressed by id alone, and the LIVE row
    // (activeSessionProvider) is null for the whole window in which the session
    // list re-resolves — reading the id from there is what made a chat session
    // render the previous session's terminal instead.
    final activeId = ref.watch(activeSessionIdProvider);
    // The in-flight target while a mode flip is pending, so the panel swaps to
    // the view the user asked for on tap rather than when the bridge acks —
    // holding the old view up for the whole teardown reads as an ignored tap.
    final isChat = ref.watch(activeSessionModeProvider) == 'chat';
    // A BOOLEAN through `.select`, never the state itself: this build is the
    // whole panel, and a plain watch of the handler state rebuilds the terminal
    // on every judge decision the focused session makes (the hazard
    // `workspaceBadgesProvider` documents for this same provider).
    //
    // A BLOCKING row, not presence: the reserve's whole justification is that
    // the `terminal:resize` it costs lands while the agent is stopped (see the
    // mount below). An ask is raised on a pass that has ALREADY replied to the
    // agent (`raiseAsk`, handler/engine.ts), so the agent is streaming past it
    // right now — reserving for one reflows a running TUI mid-output, and again
    // when it is answered. The card still floats over the terminal either way;
    // what an ask does not get is the terminal's last line back.
    final hasBlockingEscalation = ref.watch(
      focusedSessionHandlerStateProvider.select(
        (s) => s.escalations.any((e) => !e.nonBlocking),
      ),
    );

    return DisplayVisibility(
      child: Column(
        children: [
          // Two headers, one layout: mobile needs a button for its slide-in
          // drawer, desktop toggles that drawer from the window title bar
          // instead. Both carry the same session context (breadcrumb, agent
          // mark, mode, handler); the title bar carries none of it and never
          // renders the name.
          if (MediaQuery.sizeOf(context).width < kCompactBreakpoint)
            AbToolbar.custom(
              children: [
                // Via provider, not Scaffold.of: the mobile drawer is a PageView
                // page, so there is no ScaffoldState holding it.
                AbIconButton(
                  icon: AbIcons.menu,
                  tooltip: 'Projects',
                  onTap: ref.watch(openDrawerProvider),
                ),
                const SizedBox(width: AbTokens.space6),
                const SessionAgentMark(),
                const SizedBox(width: AbTokens.space6),
                const ActiveSessionApprovalBadge(),
                // space12, not space8: the work-status badge overhangs the mark
                // by 2px (see AgentWorkStatusBadge's Positioned offset in
                // SessionAgentMark) and needs the wider gap to actually clear
                // the breadcrumb — same convention as _SessionMark's use of
                // space12 in recent_session_row_widget.dart.
                const SizedBox(width: AbTokens.space12),
                // Branch pill folded into the overflow menu below: it lives
                // inside the breadcrumb on desktop, but on a phone-width row it
                // competes with the title for the one flexible slot.
                const Expanded(
                  child: TitleBarBreadcrumb(showBranchPill: false),
                ),
                const WorkspaceReadinessChip(),
                const SizedBox(width: AbTokens.space6),
                const SessionOverflowButton(compact: true),
              ],
            )
          else
            const AgentBar(),
          const SessionSetupBanner(),
          Expanded(
            child: isChat && activeId != null
                // Keyed by session so switching sessions rebuilds the State —
                // composer draft, expansion/dismiss sets, and scroll position
                // must not leak from one session into another.
                ? AgentTranscriptView(
                    key: ValueKey(activeId),
                    sessionId: activeId,
                  )
                // Both overlays are terminal-only; neither may paint over the
                // transcript, which owns its own inline resolution UI.
                //
                // The escalation card FLOATS and the terminal reserves only the
                // collapsed strip beneath it: a height change on the terminal
                // child sends a `terminal:resize` up the wire (see
                // `_maybeSendResize` in terminal_view_wrapper.dart, whose row
                // count comes off the incoming constraints), so reserving on a
                // BLOCKING row costs one reflow when the question arrives and one
                // when it goes — both at the moment the agent is stopped and
                // drawing nothing — while reserving on expand/collapse would cost
                // one per chevron tap. What the reserve buys is the terminal's
                // last line, which is the line the user collapsed the card in
                // order to read.
                : Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: hasBlockingEscalation
                              ? handlerEscalationCollapsedHeight(context)
                              : 0,
                        ),
                        child: const TerminalScreen(),
                      ),
                      // Both of the following are opaque, full-width and pinned
                      // to the same bottom edge, so their order IS the stacking
                      // contract and belongs here rather than in either of them.
                      // The escalation sits UNDER the command panel because only
                      // one of the two can be dismissed: a failed command's
                      // output stands until the user closes it, so an escalation
                      // painted over it puts the close and rerun buttons out of
                      // reach for as long as the question stands — and reading
                      // that failure is routinely what answering the question
                      // needs. The command panel retires and gives the card back.
                      // Keyed by session for the reason the transcript above is:
                      // the collapse flag must not leak from one session into
                      // another.
                      HandlerEscalationOverlay(key: ValueKey(activeId)),
                      const CommandOutputOverlay(),
                    ],
                  ),
          ),
          const HandlerAwayHint(),
          const HandlerPaBar(),
          const CommandTray(),
          // Last, so nothing above it changes position. Zero-sized: it exists
          // only to give an Antgrid-painted caller a scoped context.
          AbCarbonScope(
            child: SizedBox.shrink(key: ref.watch(handlerSheetHostKeyProvider)),
          ),
        ],
      ),
    );
  }
}

/// The agent panel's desktop header, mirroring `WorkspaceTabBar` across the
/// resizable divider: both take `workspaceStripHeight`, so their tops and
/// bottoms line up.
///
/// Where the workspace side puts tabs, this side puts the session's identity —
/// the breadcrumb and branch pill the window title bar used to carry. Moving
/// them here is what makes them sit above the transcript they describe rather
/// than above the whole window. The mode switch and the Handler arm/disarm
/// row live one tap away, in [SessionOverflowButton]'s kebab — the same menu
/// the phone header opens, so both breakpoints reach them identically.
///
/// Carries none of the pane-resizing controls, unlike the workspace side: the
/// agent is the PRIMARY view, so every panel mode either shows it or shows
/// only the workspace panel full width, and every affordance that resizes a
/// pane already lives on a surface that stays mounted in every mode — the
/// workspace tab bar, and the window title bar's sidebar and panel controls.
///
/// The one exception is [WorkspaceMenuButton]. It selects a view rather than
/// sizing a pane: a shortcut into the context panel's tabs from the bar
/// the user is already looking at, staying reachable in the panel modes where
/// the tab strip is off screen — same popup on a touch tablet as on a mouse
/// desktop, since the tablet's context panel is a docked pane beside the
/// agent (`WorkspaceShellState._buildTabletTouch`), not an overlay covering
/// it. Touch only differs while that pane is closed, where a tap opens it
/// directly (see `WorkspaceMenuButton`'s own doc) — alongside a leading
/// "Projects" button this bar grows only on a touch platform, opening the
/// same kind of docked sidebar pane on a tablet (`open by default`, unlike
/// the context pane) or the swiped-in `Scaffold.drawer` overlay on phone
/// width. A mouse desktop keeps opening/closing the projects drawer from the
/// window title bar instead, so it never needs that button.
class AgentBar extends ConsumerWidget {
  const AgentBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The window title bar only mounts its contents on a non-touch desktop at
    // >= kMediumBreakpoint (app_shell.dart); below that, nothing else hosts
    // its trailing project actions (Remote Access chip + remote host pill) —
    // unlike the sidebar and context panel, which get forced-visible
    // fallbacks in that band. Without this, a narrow mouse-desktop window
    // (well above the 640px minimum window size) has no way to reach Remote
    // Access at all.
    final titleBarMounted =
        !isMobilePlatform &&
        MediaQuery.sizeOf(context).width >= kMediumBreakpoint;
    // Resolved before the list so the separator below can be gated on the
    // actions rather than on the band: the list is empty on every touch
    // platform and on a desktop whose local uuid hasn't resolved yet, and a
    // spacer emitted for nothing ends the bar with a gap.
    final projectActions = titleBarMounted
        ? const <Widget>[]
        : titleBarProjectActions(ref);
    return AbToolbar.custom(
      height: workspaceStripHeight,
      children: [
        if (isMobilePlatform) ...[
          AbIconButton(
            icon: AbIcons.menu,
            tooltip: 'Projects',
            onTap: ref.watch(openDrawerProvider),
          ),
          const SizedBox(width: AbTokens.space6),
        ],
        const SessionAgentMark(),
        const SizedBox(width: AbTokens.space6),
        const ActiveSessionApprovalBadge(),
        // space12, not space8 — see the matching comment in AgentPanel's
        // mobile header above.
        const SizedBox(width: AbTokens.space12),
        const Expanded(child: TitleBarBreadcrumb()),
        const WorkspaceReadinessChip(),
        const SizedBox(width: AbTokens.space6),
        const WorkspaceMenuButton(),
        const SessionOverflowButton(compact: false),
        if (projectActions.isNotEmpty) ...[
          const SizedBox(width: AbTokens.space6),
          ...projectActions,
        ],
      ],
    );
  }
}

/// Trailing actions for the desktop window title bar. The two have DIFFERENT
/// scopes and are therefore derived independently:
///  - [RemoteAccessControl] is machine-wide ("is this machine reachable from
///    your other devices"), so it hangs off `localDeviceUuidProvider` alone and
///    renders regardless of which project is focused. That provider mints an
///    anonymous host uuid on desktop precisely so this affordance can show, and
///    is null on mobile/web where there is no local host.
///  - [RemoteHostChip] is focus-derived: it names the machine hosting the
///    FOCUSED project. It may render next to the switch — a remote project in
///    focus plus your own machine's switch is a coherent pair, since the switch
///    governs your machine, not theirs.
///
/// Desktop only: the mobile early return exists so a phone has no surface to
/// grant itself the machine.
///
/// Top-level rather than a private method so the derivation has one
/// implementation, used by `WindowTitleBarContents`, and can be exercised
/// directly in tests without re-implementing it.
List<Widget> titleBarProjectActions(WidgetRef ref) {
  if (isMobilePlatform) return const [];
  // The demo has no machine to make reachable, and [RemoteAccessControl] is a
  // LIVE switch over the real machine-wide policy — offering it beside canned
  // data invites a reviewer to grant their machine from inside a sample. The
  // guard also precedes the uuid read, which mints an anonymous host identity
  // on desktop purely so this affordance can render.
  if (ref.watch(demoModeProvider)) return const [];
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  final remoteHost = _focusedRemoteHost(ref);

  return [
    // Rendered even while the policy is unloaded — RemoteAccessControl reports
    // "not known yet" rather than vanishing, deliberately (see its build()).
    if (localUuid != null) const RemoteAccessControl(),
    // The spacer belongs to the control it follows, and [_focusedRemoteHost]
    // already withholds the chip until the uuid resolves.
    if (localUuid != null && remoteHost != null)
      const SizedBox(width: AbTokens.space8),
    if (remoteHost != null) _remoteHostChip(ref, remoteHost),
  ];
}

/// A cold project reads the status cache, which never holds the host figures,
/// so its chip shows none.
Widget _remoteHostChip(WidgetRef ref, ({String name, String? platform}) host) {
  final selectedId = ref.watch(selectedRegistrationIdProvider);
  final stats = selectedId == null
      ? null
      : ref.watch(
          projectStatusProvider(
            selectedId,
          ).select((s) => s.value?.machineStats),
        );
  // Captured now: the hover fires long after this build, and a WidgetRef read
  // on a disposed row throws.
  final container = ref.container;
  return RemoteHostChip(
    hostMachineName: host.name,
    platform: host.platform,
    ram: stats == null
        ? null
        : ramLine(total: stats.ramTotalBytes, free: stats.ramAvailableBytes),
    cpuPercent: stats?.cpuPercent,
    // The host samples nothing until asked; the answer lands in machineStats.
    // A passive hover, so a project with no live session is not warmed for it.
    onRequestStats: () =>
        detached('AgentPanel', 'machine:stats request failed', () async {
          await focusedServiceOrNull(
            container,
            (s) => s.send(createAbMessage('machine:stats:request', const {})),
          );
        }),
  );
}

/// The machine hosting the focused project, or null when it is this one (or
/// undecidable yet).
///
/// Two sources, because a project reaches the focus by two routes. A LOCAL
/// store record answers for a folder this app opened — including the legacy
/// case of one recorded against another device. Everything else is a remote
/// focus that was never upserted locally: a machine's advertised project, whose
/// id is `<machineUuid>.<projectId>`, or a machine itself. Asking only the
/// local store — what this used to do — meant the chip never rendered for the
/// route that actually carries remote projects today, so driving another
/// machine looked exactly like driving your own.
({String name, String? platform})? _focusedRemoteHost(WidgetRef ref) {
  final selectedId = ref.watch(selectedRegistrationIdProvider);
  if (selectedId == null) return null;
  // Until the local uuid resolves, local-vs-remote is undecidable — withhold
  // the chip rather than flashing the wrong one.
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  if (localUuid == null) return null;

  for (final project in ref.watch(projectsProvider)) {
    if (project.projectId != selectedId) continue;
    return project.isLocalFor(localUuid)
        ? null
        : (name: project.hostMachineName, platform: null);
  }

  final base = baseDeviceUuid(selectedId);
  if (base == localUuid) return null;
  return resolveMachineDisplay(
    base: base,
    inventory: ref.watch(accountAgentsProvider).value,
    recents: ref.watch(recentAgentsProvider),
  );
}
