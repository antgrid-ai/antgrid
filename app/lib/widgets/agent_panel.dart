import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_carbon.dart';
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
      // The column's own height is the only honest bound for the setup panel
      // in chat: a non-flex child is otherwise measured unbounded and would
      // size itself against the screen, keyboard and all.
      child: LayoutBuilder(
        builder: (context, box) => Column(
        children: [
          // Two headers, one layout: mobile needs a button for its slide-in
          // drawer, desktop toggles that drawer from the window title bar
          // instead. Both carry the same session context (breadcrumb, agent
          // mark, mode, handler); the title bar carries none of it and never
          // renders the name.
          if (MediaQuery.sizeOf(context).width < kCompactBreakpoint)
            const _AgentStrip(
              children: [
                _ProjectsButton(),
                SizedBox(width: CarbonSpacing.spacing03),
                SessionAgentMark(),
                // Brings its own leading gap, so nothing sits between the two.
                ActiveSessionApprovalBadge(),
                // Clears the work-status dot that overhangs the mark's corner
                // and, with no badge, is the whole gap to the breadcrumb.
                SizedBox(width: CarbonSpacing.spacing04),
                // Branch pill folded into the overflow menu below: it lives
                // inside the breadcrumb on desktop, but on a phone-width row it
                // competes with the title for the one flexible slot.
                Expanded(child: _TitleAndReadiness()),
                SizedBox(width: CarbonSpacing.spacing03),
                SessionOverflowButton(compact: true),
              ],
            )
          else
            const AgentBar(),
          // In the column ONLY for chat: overlays never paint over the
          // transcript, so the strip makes room for it there. Terminal mode
          // floats it inside the Stack below instead.
          if (isChat && activeId != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight),
              child: const SessionSetupBanner(),
            ),
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
                      // Floats for the reason the escalation card does: a
                      // height change on the terminal sends `terminal:resize`,
                      // and a strip that appears, expands or goes would cost
                      // one each time. Last, so its panel paints over the
                      // bottom overlays too.
                      //
                      // Filled and top-aligned rather than pinned by `top`: a
                      // Stack measures a child pinned on one edge unbounded, so
                      // the panel could not tell how much terminal it floats
                      // over. Align takes no hits of its own, so the terminal
                      // below the strip stays reachable.
                      const Positioned.fill(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: SessionSetupBanner(),
                        ),
                      ),
                    ],
                  ),
          ),
          const HandlerAwayHint(),
          const HandlerPaBar(),
          const CommandTray(),
        ],
        ),
      ),
    );
  }
}

/// The phone header's one flexible slot, shared by the session title and the
/// readiness chip. The chip keeps its whole label while it can, because what
/// it reports ("Couldn't reach agent") is why the user is looking; it gives way
/// only so the title keeps [_titleFloor] on the narrowest phones, and never
/// below half the slot, which keeps it above a tag's own minimum width. The chip is
/// not a flex child of its own: a flex child is allotted its share of the row
/// whether or not it draws anything, and the chip draws nothing whenever the
/// checkout is ready, i.e. nearly always.
class _TitleAndReadiness extends StatelessWidget {
  const _TitleAndReadiness();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Row(
      children: [
        const Expanded(child: TitleBarBreadcrumb(showBranchPill: false)),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.max(box.maxWidth - _titleFloor, box.maxWidth / 2),
          ),
          child: const WorkspaceReadinessChip(),
        ),
      ],
    ),
  );
}

/// What the session title keeps beside the readiness chip: a few characters and
/// the ellipsis, so the row still says which session it is.
const _titleFloor = CarbonSpacing.spacing10;

/// The strip's own box, for tests that measure its height and rule.
@visibleForTesting
const agentStripKey = Key('agent-strip');

/// The agent panel's header strip, one Carbon surface for both breakpoints.
///
/// Drawn the way [WorkspaceTabBar] draws its strip across the divider: the
/// `background` layer, a `borderSubtle00` rule under it, and
/// [workspaceStripHeight] in total, so on desktop their tops and bottoms meet.
/// On a touch platform that height is the 44pt target plus the rule, which is
/// what lets the kebab's touch trigger keep its full size.
class _AgentStrip extends StatelessWidget {
  const _AgentStrip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Read here, outside the scope: the Ab-side token behind it is host layout.
    final stripHeight = workspaceStripHeight;
    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          final colors = CarbonTheme.of(context).colors;
          return Container(
            key: agentStripKey,
            decoration: BoxDecoration(
              color: colors.background,
              border: Border(bottom: BorderSide(color: colors.borderSubtle00)),
            ),
            child: SizedBox(
              height: stripHeight - CarbonBorders.hairline,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing02,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: children,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The leading "Projects" button, which opens the projects drawer.
class _ProjectsButton extends ConsumerWidget {
  const _ProjectsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => CarbonTooltip(
    message: 'Projects',
    excludeFromSemantics: true,
    child: CarbonButton.iconOnly(
      icon: const CarbonIcon(CarbonIcons.menu),
      semanticLabel: 'Projects',
      // Via provider, not Scaffold.of: the mobile drawer is a PageView page,
      // so there is no ScaffoldState holding it.
      onPressed: ref.watch(openDrawerProvider),
    ),
  );
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
    return _AgentStrip(
      children: [
        if (isMobilePlatform) ...[
          const _ProjectsButton(),
          const SizedBox(width: CarbonSpacing.spacing03),
        ],
        const SessionAgentMark(),
        const ActiveSessionApprovalBadge(),
        // See the matching gap in AgentPanel's phone header above.
        const SizedBox(width: CarbonSpacing.spacing04),
        const Expanded(child: TitleBarBreadcrumb()),
        const WorkspaceReadinessChip(),
        const SizedBox(width: CarbonSpacing.spacing03),
        const WorkspaceMenuButton(),
        const SessionOverflowButton(compact: false),
        if (projectActions.isNotEmpty) ...[
          const SizedBox(width: CarbonSpacing.spacing03),
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
      const SizedBox(width: CarbonSpacing.spacing03),
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
