import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_branch_pill.dart';
import '../design/widgets/ab_breadcrumb.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/handler_state.dart';
import '../models/session_entry.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/auth.dart';
import '../providers/device_provisioning.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/project_work_status.dart';
import '../screens/terminal_screen.dart';
import '../services/control_plane_client.dart';
import '../utils/platform_utils.dart';
import 'agent_transcript_view.dart';
import 'agent_work_status_dot.dart';
import 'auth_status_pill.dart';
import 'command_bar.dart';
import 'command_output_overlay.dart';
import 'handler/handler_enable_sheet.dart';
import 'mobile_access_toggle.dart';
import 'remote_host_chip.dart';
import 'session_rename_dialog.dart';

class AgentPanel extends ConsumerWidget {
  const AgentPanel({
    super.key,
    this.contextPanelHidden = false,
    this.onToggleContextPanel,
  });

  /// Current visibility of the desktop context panel, for the header toggle's
  /// glyph. Meaningless when [onToggleContextPanel] is null.
  final bool contextPanelHidden;

  /// Shows/hides the desktop context panel. Null on mobile (a PageView with no
  /// panel modes), which is what hides the toggle there. The control lives in
  /// THIS header rather than the context panel's own tab bar because that tab
  /// bar goes off screen with the panel it belongs to — the restore affordance
  /// has to sit on a surface that is always mounted.
  final VoidCallback? onToggleContextPanel;

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
    final isChat = active?.mode == 'chat';

    return Column(
      children: [
        _AgentStatusHeader(
          contextPanelHidden: contextPanelHidden,
          onToggleContextPanel: onToggleContextPanel,
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
        const CommandTray(),
      ],
    );
  }
}

class _AgentStatusHeader extends ConsumerWidget {
  const _AgentStatusHeader({
    required this.contextPanelHidden,
    required this.onToggleContextPanel,
  });

  final bool contextPanelHidden;
  final VoidCallback? onToggleContextPanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalState = ref.watch(terminalStateProvider).value;
    final activeId = ref.watch(selectedRegistrationIdProvider);
    final agentName =
        terminalState?.agentInfo?.name ??
        (activeId != null ? projectNameFromId(activeId) : 'Antgrid');

    final gitBranch = terminalState?.gitBranch;
    final active = ref.watch(activeSessionProvider);
    // Leaf slot must exist for the '/' separator + leafOverride to render; the
    // string is a fallback only — the editable leaf renders the live name.
    final segments = [agentName, if (active != null) active.name];
    // Live work status for the focused project — shows working/attention/error
    // next to the breadcrumb. Omitted when done to keep idle headers clean.
    final workStatus =
        activeId != null ? ref.watch(projectWorkStatusProvider(activeId)) : null;

    return AbToolbar.custom(
      children: [
        if (MediaQuery.sizeOf(context).width < kCompactBreakpoint) ...[
          Builder(
            builder: (innerCtx) => AbIconButton(
              icon: AbIcons.menu,
              tooltip: 'Projects',
              onTap: () => Scaffold.of(innerCtx).openDrawer(),
            ),
          ),
          const SizedBox(width: AbTokens.space6),
        ],
        if (workStatus != null && workStatus != AgentWorkStatus.done) ...[
          AgentWorkStatusDot(status: workStatus),
          const SizedBox(width: AbTokens.space8),
        ],
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: AbBreadcrumb(
                  segments: segments,
                  leafOverride: active == null
                      ? null
                      : _EditableSessionLeaf(session: active),
                ),
              ),
              if (gitBranch != null) ...[
                const SizedBox(width: AbTokens.space8),
                AbBranchPill(
                  branch: gitBranch,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: gitBranch));
                    if (!context.mounted) return;
                    showAbSnackBar(
                      context,
                      'Copied "$gitBranch"',
                      duration: const Duration(seconds: 2),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: AbTokens.space8),
        ..._authStatusWidgets(context, ref),
        const SizedBox(width: AbTokens.space8),
        const HandlerHeaderControl(),
        const SizedBox(width: AbTokens.space8),
        ..._localProjectActions(ref),
        if (onToggleContextPanel != null) ...[
          const SizedBox(width: AbTokens.space8),
          AbIconButton(
            icon: contextPanelHidden
                ? AbIcons.layoutSidebarRightOff
                : AbIcons.layoutSidebarRight,
            // Same emphasis in both states: while hidden this button is the
            // ONLY way back (there is no collapsed strip), so dimming it would
            // make the sole recovery affordance the faintest thing in the
            // header — and hidden is the DEFAULT on tablets and phone
            // landscape, i.e. the first thing those users see.
            tooltip: contextPanelHidden
                ? 'Show context panel'
                : 'Hide context panel',
            onTap: onToggleContextPanel,
          ),
        ],
      ],
    );
  }

  /// Renders the signed-in user's email + tier pill from [currentUserProvider].
  /// Hidden while loading, when the user is not signed in, or when the focused
  /// project is a local folder (login/plan only applies to relay-paired
  /// remote agents).
  List<Widget> _authStatusWidgets(BuildContext context, WidgetRef ref) {
    if (!ref.watch(focusedIsRelayProvider)) return const [];
    final user = ref.watch(currentUserProvider).value;
    if (user == null) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(right: AbTokens.space6),
        child: Text(
          user.email,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXxs,
            color: context.antgrid.textSecondary,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      AuthStatusPill(user),
      const SizedBox(width: AbTokens.space8),
    ];
  }

  List<Widget> _localProjectActions(WidgetRef ref) => localProjectActions(ref);
}

/// Per-project header action for the focused project:
///  - **Local project** → a [MobileAccessToggle] (Enable/Disable mobile access),
///    which drives the paired-phone allowlist for this project.
///  - **Remote project** → a read-only [RemoteHostChip] (the host machine name);
///    you cannot manage another machine's allowlist from here.
///
/// Top-level (and `@visibleForTesting`) rather than a private method so the
/// header's per-project action logic — including the
/// `selectedRegistrationIdProvider` → `projectsProvider` lookup — can be
/// exercised directly in tests without re-implementing it.
@visibleForTesting
List<Widget> localProjectActions(WidgetRef ref) {
  if (isMobilePlatform) return const [];
  final selectedId = ref.watch(selectedRegistrationIdProvider);
  if (selectedId == null) return const [];
  final projects = ref.watch(projectsProvider);
  final matches = projects.where((p) => p.projectId == selectedId);
  if (matches.isEmpty) return const [];
  final project = matches.first;
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  // Still resolving — show nothing to avoid an incorrect flash.
  if (localUuid == null) return const [];
  if (project.isLocalFor(localUuid)) {
    return [MobileAccessToggle(projectId: project.projectId)];
  }
  // TODO(task-13): derive platform from welcome message / agent inventory.
  return [
    RemoteHostChip(hostMachineName: project.hostMachineName, platform: 'macos'),
  ];
}

/// Handler status pill + configure button rendered in the agent panel header.
///
/// Shows a state pill (WATCHING / HANDLING / NEEDS YOU `n`) when Handler is
/// enabled, and an icon button that opens [showHandlerEnableSheet] to
/// reconfigure or disable it.
class HandlerHeaderControl extends ConsumerWidget {
  const HandlerHeaderControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(handlerStateProvider).value;
    final service = serviceWhenReady(ref, handlerServiceProvider);
    final p = context.antgrid;

    String? pillLabel;
    Color pillColor = p.textMuted;
    if (state != null && state.enabled) {
      switch (state.runState) {
        case HandlerRunState.needsYou:
          pillLabel = 'NEEDS YOU ${state.pendingEscalations}';
          pillColor = p.accent;
          break;
        case HandlerRunState.handling:
          pillLabel = 'HANDLING';
          pillColor = p.accent;
          break;
        case HandlerRunState.watching:
          pillLabel = 'WATCHING';
          pillColor = p.textMuted;
          break;
        case HandlerRunState.off:
          pillLabel = null;
          break;
      }
    }

    Future<void> openSheet() async {
      if (service == null) return;
      final cur = state ?? const HandlerState.initial();
      final choice = await showHandlerEnableSheet(
        context,
        enabled: cur.enabled,
        template: cur.template,
        model: cur.model,
      );
      if (choice == null) return;
      service.configure(
        enabled: choice.enabled,
        template: choice.template,
        model: choice.model,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pillLabel != null) ...[
          AbChip.system(label: pillLabel, color: pillColor),
          const SizedBox(width: AbTokens.space6),
        ],
        AbIconButton(
          icon: AbIcons.shield,
          tooltip: 'Configure Handler',
          tone: (state?.enabled ?? false)
              ? AbIconButtonTone.accent
              : AbIconButtonTone.normal,
          onTap: openSheet,
        ),
      ],
    );
  }
}

/// The breadcrumb leaf for the active session — tap to rename it via the
/// shared [promptSessionRename] dialog (desktop and mobile alike). Commits via
/// the focused project's [sessionsServiceProvider] — the active session always
/// belongs to the focused project.
class _EditableSessionLeaf extends ConsumerWidget {
  final SessionEntry session;
  const _EditableSessionLeaf({required this.session});

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final id = session.id;
    final name = await promptSessionRename(context, session.name);
    if (name == null || name == session.name) return;
    // Resolve the service AFTER the dialog without throwing: the focused
    // project can transiently re-resolve while the dialog is open (transport
    // reconnect, auth cascade), which makes `sessionsServiceProvider` throw
    // (_ProjectSessionLoading / StateError). Read the session façade nullably
    // instead — mirroring the kebab/inline rename paths — and await so a slow
    // or failed rename surfaces rather than being swallowed fire-and-forget.
    final projectId = ref.read(selectedRegistrationIdProvider);
    final svc = projectId == null
        ? null
        : ref.read(projectSessionProvider(projectId)).value?.sessionsService;
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
