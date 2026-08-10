import 'dart:async';

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
import '../design/widgets/ab_toolbar.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/handler_state.dart';
import '../models/session_entry.dart';
import '../providers/agent_catalog.dart';
import '../providers/agent_transport.dart';
import '../providers/device_provisioning.dart';
import '../providers/first_run.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/session_mode.dart';
import '../providers/sessions.dart';
import '../screens/terminal_screen.dart';
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
import 'session_mode_control.dart';
import 'session_rename_dialog.dart';
import 'window_title_bar.dart';

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

    final active = ref.watch(activeSessionProvider);
    // The in-flight target while a mode flip is pending, so the panel swaps to
    // the view the user asked for on tap rather than when the bridge acks —
    // holding the old view up for the whole teardown reads as an ignored tap.
    final isChat = ref.watch(activeSessionModeProvider) == 'chat';

    return Column(
      children: [
        // Desktop replaced the old shared header with the window title bar,
        // but on mobile no title bar mounts, so the drawer button and
        // project/session context (breadcrumb, branch pill) must survive here.
        if (MediaQuery.sizeOf(context).width < kCompactBreakpoint)
          AbToolbar.custom(
            children: [
              Builder(
                builder: (innerCtx) => AbIconButton(
                  icon: AbIcons.menu,
                  tooltip: 'Projects',
                  onTap: () => Scaffold.of(innerCtx).openDrawer(),
                ),
              ),
              const SizedBox(width: AbTokens.space6),
              const Expanded(child: TitleBarBreadcrumb()),
              const SizedBox(width: AbTokens.space8),
              const SessionAgentMark(),
              const SizedBox(width: AbTokens.space6),
              const SessionModeControl(),
              const SizedBox(width: AbTokens.space8),
              const HandlerHeaderControl(),
            ],
          ),
        Expanded(
          child: isChat
              // Keyed by session so switching sessions rebuilds the State —
              // composer draft, expansion/dismiss sets, and scroll position
              // must not leak from one session into another.
              ? AgentTranscriptView(
                  key: ValueKey(active!.id),
                  sessionId: active.id,
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
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  final selectedId = ref.watch(selectedRegistrationIdProvider);
  final projects = ref.watch(projectsProvider);

  // A null selectedId matches nothing: projectId is non-nullable.
  final matches = projects.where((p) => p.projectId == selectedId);
  final focused = matches.isEmpty ? null : matches.first;
  // Until the local uuid resolves, local-vs-remote is undecidable — withhold the
  // chip rather than flashing the wrong one.
  final remoteHost =
      focused != null && localUuid != null && !focused.isLocalFor(localUuid)
      ? focused.hostMachineName
      : null;

  return [
    // Rendered even while the policy is unloaded — RemoteAccessControl reports
    // "not known yet" rather than vanishing, deliberately (see its build()).
    if (localUuid != null) const RemoteAccessControl(),
    if (localUuid != null && remoteHost != null)
      const SizedBox(width: AbTokens.space8),
    if (remoteHost != null)
      // TODO(task-13): derive platform from welcome message / agent inventory.
      RemoteHostChip(hostMachineName: remoteHost, platform: 'macos'),
  ];
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
    // A SessionEntry carries `tool` only when it OVERRODE the project default,
    // so an absent one resolves to the project's, as the bridge's own thunk
    // does.
    final catalog = ref.watch(agentCatalogProvider);
    final entry = ref.watch(activeSessionProvider);
    final agent = entry?.tool ?? state.defaultTool;
    final agentObservable = handlerObservableFromCatalog(
      catalog,
      agent,
      chat: entry?.mode == 'chat',
    );
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
    // WATCHING/HANDLING pill. When the focused session itself needs the user its
    // own count already shows; when it's unarmed, otherPending is the full
    // project-wide count (session-null case).
    final otherPending =
        state.pendingEscalations - (session?.pendingEscalations ?? 0);
    if (session?.runState != HandlerRunState.needsYou && otherPending > 0) {
      pillLabel = 'NEEDS YOU $otherPending';
      pillColor = p.accent;
      pillNavigates = true;
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
                  onTap: () => ref.read(revealHandlerTabProvider)?.call(),
                  child: AbChip.system(label: pillLabel, color: pillColor),
                ),
              )
            : AbChip.system(label: pillLabel, color: pillColor);

    // No armable focus target: hide the shield but keep the project-wide
    // NEEDS YOU pill reachable.
    if (activeId == null) {
      return pill ?? const SizedBox.shrink();
    }

    // Spec §4.1: arming is one tap and carries no payload — no goal, no
    // backlog, no judge override. Everything the session needs is either
    // already stored on the bridge or extracted behind the handoff, so sending
    // any of those keys here would overwrite state this control never showed.
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
          service: service,
          terminalId: activeId,
          notifyOnly: state.defaultNotifyOnly,
          agentObservable: agentObservable,
          agentLabel: catalog[agent]?.label,
        ),
      );
    }

    // Arming is one tap, so this tooltip is the only place the pre-arm
    // coverage answer can reach the user — an agent that reports nothing
    // arms just as silently as one that is merely quiet.
    final shieldTooltip = session != null
        ? 'Disarm Handler'
        : agentObservable == false
        ? unwatchableNotice(catalog[agent]?.label)
        : 'Arm Handler';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pill != null) ...[
          pill,
          const SizedBox(width: AbTokens.space6),
        ],
        if (shieldShowsLabel(armedOnce: armedOnce, sessionArmed: session != null))
          AbTooltip(
            message: shieldTooltip,
            child: AbButton(
              compact: true,
              label: 'Handler',
              leading: AbIcon(AbIcons.shield, size: AbTokens.iconButtonGlyph),
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
/// shared [promptSessionRename] dialog (desktop and mobile alike). Commits via
/// the focused project's [sessionsServiceProvider] — the active session always
/// belongs to the focused project.
class EditableSessionLeaf extends ConsumerWidget {
  final SessionEntry session;
  const EditableSessionLeaf({super.key, required this.session});

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final id = session.id;
    // Container captured BEFORE the dialog: the breadcrumb can be rebuilt away
    // while it is open, and a `WidgetRef` touched past that point throws.
    final container = ref.container;
    final name = await promptSessionRename(context, session.name);
    if (name == null || name == session.name) return;
    // Resolve the service AFTER the dialog without throwing: the focused
    // project can transiently re-resolve while the dialog is open (transport
    // reconnect, auth cascade), which makes `sessionsServiceProvider` throw
    // (_ProjectSessionLoading / StateError). Await so a slow or failed rename
    // surfaces rather than being swallowed fire-and-forget.
    final svc = focusedServiceOrNull(container, (s) => s.sessionsService);
    await svc?.rename(id, name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _rename(context, ref),
        // Style inherited from the breadcrumb leaf's DefaultTextStyle.
        child: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
