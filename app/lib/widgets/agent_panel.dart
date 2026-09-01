import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../design/widgets/ab_toolbar.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/handler_state.dart';
import '../models/session_entry.dart';
import '../models/workspace_view.dart';
import '../providers/account_agents.dart';
import '../providers/agent_coordinates.dart';
import '../providers/agent_transport.dart';
import '../providers/demo_mode.dart';
import '../providers/device_provisioning.dart';
import '../providers/first_run.dart';
import '../providers/handler_discovery.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/recent_agents.dart';
import '../providers/session_mode.dart';
import '../providers/sessions.dart';
import '../providers/visible_surface.dart';
import '../screens/terminal_screen.dart';
import '../util/ab_log.dart';
import '../util/device_id.dart';
import '../util/detached.dart';
import '../util/relative_time.dart';
import '../utils/platform_utils.dart';
import 'agent_transcript_view.dart';
import 'command_bar.dart';
import 'command_output_overlay.dart';
import 'handler/handler_arm_explainer.dart';
import 'handler/handler_away_hint.dart';
import 'handler/handler_item_status.dart';
import 'handler/handler_pa_bar.dart';
import 'remote_access_control.dart';
import 'remote_host_chip.dart';
import 'session_agent_mark.dart';
import 'session_approval_badge.dart';
import 'session_mode_control.dart';
import 'session_rename_dialog.dart';
import 'session_setup_banner.dart';
import 'window_title_bar.dart';
import 'workspace_menu_button.dart';

class AgentPanel extends ConsumerWidget {
  const AgentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<bool>(authRevokedBannerProvider, (_, revoked) {
      if (!revoked) return;
      // Reset so a subsequent auth_revoked event re-notifies.
      ref.read(authRevokedBannerProvider.notifier).set(false);
      showAbSnackBar(
        context,
        "This device's access was revoked. Reopen the project to "
        'provision a new device; sign in again if prompted.',
        duration: const Duration(seconds: 6),
      );
    });

    // The transcript is addressed by id alone, and the LIVE row
    // (activeSessionProvider) is null for the whole window in which the session
    // list re-resolves — reading the id from there is what made a chat session
    // render the previous session's terminal instead.
    final activeId = ref.watch(activeSessionIdProvider);
    // The in-flight target while a mode flip is pending, so the panel swaps to
    // the view the user asked for on tap rather than when the bridge acks —
    // holding the old view up for the whole teardown reads as an ignored tap.
    final isChat = ref.watch(activeSessionModeProvider) == 'chat';

    return Column(
      children: [
        // Two headers, one layout: mobile needs a button for its slide-in
        // drawer, desktop toggles that drawer from the window title bar
        // instead. Both carry the same session context (breadcrumb, branch
        // pill, agent mark, mode, handler) — the title bar yields the controls
        // while either is up (see agentBarMountedProvider) and never renders
        // the name at all.
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
              const Expanded(child: TitleBarBreadcrumb()),
              const SizedBox(width: AbTokens.space6),
              const SessionModeControl(),
              const SizedBox(width: AbTokens.space8),
              const HandlerHeaderControl(),
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
              // Overlay is terminal-only; it must never paint over the transcript.
              : const Stack(
                  children: [TerminalScreen(), CommandOutputOverlay()],
                ),
        ),
        const HandlerAwayHint(),
        const HandlerPaBar(),
        const CommandTray(),
      ],
    );
  }
}

/// The agent panel's desktop header, mirroring `WorkspaceTabBar` across the
/// resizable divider: same height, same background, so the two read as one
/// continuous strip.
///
/// Where the workspace side puts tabs, this side puts the session's identity —
/// the breadcrumb and branch pill the window title bar used to carry. Moving
/// them here is what makes them sit above the transcript they describe rather
/// than above the whole window.
///
/// Carries none of the pane-resizing controls, unlike the workspace side: the
/// agent is the PRIMARY view, so every panel mode either shows it or shows
/// only the workspace panel full width, and every affordance that resizes a
/// pane already lives on a surface that stays mounted in every mode — the
/// workspace tab bar, and the window title bar's sidebar and panel controls.
///
/// The one exception is [WorkspaceMenuButton]. It selects a view rather than
/// sizing a pane: a shortcut into the context panel's five tabs from the bar
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
        const SizedBox(width: AbTokens.space6),
        const SessionModeControl(),
        const SizedBox(width: AbTokens.space8),
        const HandlerHeaderControl(),
        const SizedBox(width: AbTokens.space6),
        const WorkspaceMenuButton(),
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
    if (remoteHost != null)
      RemoteHostChip(
        hostMachineName: remoteHost.name,
        platform: remoteHost.platform,
      ),
  ];
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

/// Pill label for a parked session. A park always resumes on its own, so the
/// wake time is the whole message; without a deadline (`selfResuming` parks
/// have none) the bare state is all we can honestly promise.
///
/// "PAUSED", not the wire's "parked": this pill and the Handler tab describe
/// one session from two corners of the same window, so they use
/// [handlerRunStateLabel]'s vocabulary rather than the protocol's.
///
/// Day-aware for the same reason, and it matters more here than anywhere: a
/// rate limit that resets at 05:00 tomorrow, shown as a bare `05:00` tonight,
/// reads as a deadline the session has already blown.
///
/// Top-level so the derivation is exercised directly, like
/// [titleBarProjectActions].
String parkedPillLabel(int? parkedUntil) {
  final head = handlerRunStateLabel(HandlerRunState.parked).toUpperCase();
  if (parkedUntil == null) return head;
  final at = dayAwareTime(DateTime.fromMillisecondsSinceEpoch(parkedUntil));
  return '$head · UNTIL ${at.toUpperCase()}';
}

/// Whether the header shield renders as a labeled 'Handler' button instead of
/// the bare icon: only until the user has armed once, and never while the
/// focused session is armed — an armed shield needs no teaching. Top-level so
/// the form decision is exercised directly, like [titleBarProjectActions].
bool shieldShowsLabel({required bool armedOnce, required bool sessionArmed}) =>
    !armedOnce && !sessionArmed;

/// Handler status pill + shield rendered in the agent panel header, scoped to
/// the FOCUSED session — arming is per-terminal, not per-project.
///
/// Shows a state pill (WATCHING / HANDLING / NEEDS YOU `n`) for the focused
/// session when armed, falling back to the project-wide pending count so
/// escalations on other sessions stay visible. The shield toggles arming for
/// the focused session.
class HandlerHeaderControl extends ConsumerWidget {
  const HandlerHeaderControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(activeSessionIdProvider);
    final state =
        ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
    // Escalations pending on OTHER sessions must stay visible whatever is
    // focused, so no early return here even with nothing armable in focus.
    final session = activeId != null ? state.sessions[activeId] : null;
    final service = serviceWhenReady(ref, handlerServiceProvider);
    // This header is the PRE-arm surface — usually nothing is armed yet, so the
    // catalog's per-agent prediction is the only coverage answer that exists.
    // Shared derivation (focusedSessionCoverageProvider), so this shield, the
    // away hint, and the explainer can never answer coverage differently.
    final coverage = ref.watch(focusedSessionCoverageProvider);
    final armedOnce = ref.watch(
      firstRunProvider.select((s) => s.handlerArmedOnce),
    );
    final p = context.antgrid;

    String? pillLabel;
    Color pillColor = p.textMuted;
    var pillNavigates = false;
    if (session != null) {
      // Words and tone both come from the shared vocabulary, so this pill and
      // the Handler tab never describe one session two ways.
      final state = session.runState;
      pillLabel = handlerRunStateLabel(state).toUpperCase();
      pillColor = handlerRunStateColor(p, state);
      switch (state) {
        case HandlerRunState.needsYou:
          pillLabel = '$pillLabel ${session.pendingEscalations}';
          pillNavigates = true;
          break;
        case HandlerRunState.parked:
          pillLabel = parkedPillLabel(session.parkedUntil);
          break;
        case HandlerRunState.watching:
          // An armed session the bridge cannot observe never leaves "watching",
          // so the shared vocabulary's WATCHING is precisely the "armed and
          // quiet" lie observability exists to end.
          if (session.observability == HandlerObservability.unsupported) {
            pillLabel = 'NOT WATCHED';
            pillColor = p.warning;
          }
          break;
        case HandlerRunState.handling:
          break;
      }
    }
    // Surface escalations on OTHER sessions even when the focused session is
    // armed — an unanswered question must never hide behind this session's
    // WATCHING/HANDLING pill. When it's unarmed, otherPending is the full
    // project-wide count (session-null case).
    //
    // Yields to the focused session when that session is itself waiting: this
    // pill is one label and cannot name two sessions, and the tab it opens
    // renders only the focused one, so a merged count would send the user
    // somewhere that cannot account for it. What the siblings get instead is a
    // count on their own drawer rows (`SessionHandlerBadge`) — the surface
    // that survives whatever is in focus.
    final otherPending =
        state.pendingEscalations - (session?.pendingEscalations ?? 0);
    if (session?.runState != HandlerRunState.needsYou && otherPending > 0) {
      pillLabel = 'NEEDS YOU $otherPending';
      pillColor = p.accent;
      pillNavigates = true;
    }

    // The Handler tab shows the FOCUSED session only, so a pill counting
    // another session has to move focus there or it reveals an empty tab — the
    // one navigation this pill exists to make.
    //
    // The target comes from the SAME branch that wrote the label. A pill
    // carrying the focused session's own count must never move focus at all;
    // `state.escalations` is banded by urgency across the whole project, so its
    // head belongs to whichever session escalated most urgently — take it and a
    // tap on "your session needs you" switches the user's entire workspace to
    // someone else's.
    //
    // A focus change cannot reveal the tab by calling: moving focus arms
    // WorkspaceShell's per-session UI restore, which re-applies the TARGET
    // session's own saved workspace tab from a post-frame callback, and any tab
    // selected before that lands is silently undone by it. So the destination
    // is handed over as pending state instead — the same handover a deep link
    // naming a view uses, drained by the shell after the restore.
    void openHandler() {
      final waiting = session?.runState == HandlerRunState.needsYou
          ? null
          : state.escalations
                .firstWhereOrNull((e) => e.terminalId != activeId)
                ?.terminalId;
      if (waiting == null) {
        ref.read(revealHandlerTabProvider)?.call();
        return;
      }
      ref.read(activeSessionIdProvider.notifier).set(waiting);
      // Read back rather than assumed: `ActiveSessionId.set` REFUSES a session
      // the bridge is already deleting, and such a session keeps its replayed
      // escalations for the seconds before its row goes. Focus then stays put,
      // and the handover below would stamp the session still in focus with a
      // destination picked for a different one.
      if (ref.read(activeSessionIdProvider) != waiting) {
        ref.read(revealHandlerTabProvider)?.call();
        return;
      }
      ref.read(pendingWorkspaceViewProvider.notifier).set((
        target: ref.read(selectedTargetProvider),
        value: WorkspaceView.handler,
      ));
    }

    // A NEEDS YOU pill is a call to action, so it navigates to the Handler
    // tab where the question is answerable; WATCHING/HANDLING are pure
    // status and stay inert.
    final pill = pillLabel == null
        ? null
        : pillNavigates
        ? MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: openHandler,
              child: AbChip.system(label: pillLabel, color: pillColor),
            ),
          )
        : AbChip.system(label: pillLabel, color: pillColor);

    // No armable focus target: hide the shield but keep the project-wide
    // NEEDS YOU pill reachable.
    if (activeId == null) {
      return pill ?? const SizedBox.shrink();
    }

    // Arming is one tap and this control composes no payload — no backlog, no
    // judge override. Everything the session needs is either already stored on
    // the bridge or extracted behind the handoff, so sending any of those keys
    // here would overwrite state this control never showed.
    // The goal is the exception and is not composed here either:
    // armWithFirstRunExplainer carries the session's own opening prompt.
    void toggleArm() {
      if (service == null) return;
      if (session != null) {
        service.disarm(activeId);
        return;
      }
      // Fire-and-forget: past the explainer await everything runs on the
      // container, never this widget's ref, and nothing in the flow can throw.
      unawaited(
        armWithFirstRunExplainer(
          context: context,
          container: ref.container,
          terminalId: activeId,
          agentObservable: coverage.observable,
          agentLabel: coverage.agentLabel,
          judgeCapable: coverage.judgeCapable,
        ),
      );
    }

    final shieldTooltip = handlerShieldTooltip(
      armed: session != null,
      observable: coverage.observable,
      judgeCapable: coverage.judgeCapable,
      agentLabel: coverage.agentLabel,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pill != null) ...[pill, const SizedBox(width: AbTokens.space6)],
        if (shieldShowsLabel(
          armedOnce: armedOnce,
          sessionArmed: session != null,
        ))
          AbTooltip(
            message: shieldTooltip,
            child: AbButton(
              compact: true,
              label: 'Handler',
              leading: AbIcon(
                AbIcons.shield,
                size: AbTokens.iconButtonGlyph,
                // Match AbButton's normal-variant label color — an untinted
                // AbIcon renders the SVG's own fill, not the theme's.
                color: p.textSecondary,
              ),
              onTap: toggleArm,
            ),
          )
        else
          AbIconButton(
            icon: AbIcons.shield,
            tooltip: shieldTooltip,
            tone: session != null
                ? AbIconButtonTone.accent
                : AbIconButtonTone.normal,
            onTap: toggleArm,
          ),
      ],
    );
  }
}

/// The breadcrumb leaf for the active session — tap to rename it via the
/// shared [promptSessionRename] dialog (desktop and mobile alike). The active
/// session belongs to the focused project, so the commit resolves that
/// project's id up front and then routes through [warmServiceFor] — see
/// [_rename] for why the id is captured rather than re-read after the dialog.
class EditableSessionLeaf extends ConsumerStatefulWidget {
  final SessionEntry session;
  const EditableSessionLeaf({super.key, required this.session});

  @override
  ConsumerState<EditableSessionLeaf> createState() =>
      _EditableSessionLeafState();
}

class _EditableSessionLeafState extends ConsumerState<EditableSessionLeaf> {
  /// The name the user asked for while the rename is in flight, else null.
  ///
  /// Shown in place of the committed name and pulsing, which is the same shape
  /// [SessionModeControl] uses for a flip in flight (`activeSessionModeProvider`
  /// hands out the pending mode the same way): the breadcrumb reads as "being
  /// applied" without claiming it landed. A refusal clears it, so the old name
  /// comes back alongside the message rather than a wrong name sticking.
  ///
  /// Local state, not an app-wide provider like `pendingSessionModeProvider`:
  /// nothing outside this leaf renders a rename in flight, and the cost of
  /// losing it (the breadcrumb unmounted mid-rename, e.g. a panel-mode change)
  /// is a missing pulse, not a wrong name.
  String? _pendingName;

  /// Uses `State.context` and guards every post-await UI touch on `mounted`
  /// rather than taking a [BuildContext] parameter — the two are the same
  /// element here, and only the State's own flag is a valid guard for it.
  Future<void> _rename() async {
    final session = widget.session;
    final id = session.id;
    // Container and entry id captured BEFORE the dialog: the breadcrumb can be
    // rebuilt away while it is open, and a `WidgetRef` touched past that point
    // throws. The id is read here rather than after, so the rename commits
    // against the project that owned this session when the dialog opened — a
    // focus switch behind an open dialog must not retarget it at another agent.
    final container = ref.container;
    final entryId = container.read(selectedRegistrationIdProvider);
    final name = await promptSessionRename(context, session.name);
    if (name == null || name == session.name) return;
    // The asked-for name goes up the moment the dialog closes and comes down in
    // the `finally` below, so every outcome ends with the breadcrumb telling the
    // truth: on success the `session:updated` push has already made
    // [widget.session] carry it (the swap back is invisible), and on a refusal
    // or a dropped reply the committed name returns alongside the message.
    // Guarded on `mounted` in both directions rather than bailing: a rename the
    // user confirmed still commits when the breadcrumb was rebuilt away behind
    // the dialog — it just has nowhere to show a pulse.
    if (mounted) setState(() => _pendingName = name);
    try {
      await _commit(container, entryId, id, name);
    } finally {
      if (mounted) setState(() => _pendingName = null);
    }
  }

  Future<void> _commit(
    ProviderContainer container,
    String? entryId,
    String id,
    String name,
  ) async {
    // Resolved AFTER the dialog, and WARMED: the project can transiently
    // re-resolve while the dialog is open (transport reconnect, auth cascade),
    // which makes `sessionsServiceProvider` throw and the synchronous
    // `focusedServiceOrNull` answer null — dropping a rename the user already
    // confirmed. Warming waits that window out instead.
    final svc = entryId == null
        ? null
        : await warmServiceFor(container, entryId, (s) => s.sessionsService);
    // Surfaced to the user, not to the top-level error handler: the tap that
    // got us here discards this future, so a dropped reply (TimeoutException
    // after the service's 15s bound) escaping here is a fatal crash. The
    // breadcrumb still reads the old name, so say why — and the two failures get
    // different copy, since nothing is sent when the project never warms and
    // blaming the agent for not answering would describe a round trip that
    // never happened.
    void report(String reason) {
      if (mounted) {
        showAbSnackBar(context, "Couldn't rename the session — $reason");
      }
    }

    if (svc == null) {
      AbLog.error(
        'AgentPanel',
        'session rename skipped: project did not warm',
        fields: {'sessionId': id, 'entryId': entryId},
      );
      report("couldn't reach this project. Try again in a moment.");
      return;
    }
    try {
      await svc.rename(id, name);
    } on TimeoutException {
      report("the agent didn't answer. Check the connection and try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingName;
    // Style inherited from the breadcrumb leaf's DefaultTextStyle.
    final Widget leaf = Text(
      pending ?? widget.session.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return MouseRegion(
      // Not a click target while committing — the dialog is the only way in and
      // a second one would race the first rename.
      cursor: pending == null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: pending != null
            ? null
            : () => detached('AgentPanel', 'session rename failed', _rename),
        child: pending == null ? leaf : PulsingOpacity(child: leaf),
      ),
    );
  }
}
