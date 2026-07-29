import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/handler_state.dart';
import '../models/session_entry.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/device_provisioning.dart';
import '../providers/projects.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../screens/terminal_screen.dart';
import '../utils/platform_utils.dart';
import 'agent_transcript_view.dart';
import 'command_bar.dart';
import 'command_output_overlay.dart';
import 'handler/handler_enable_sheet.dart';
import 'mobile_access_toggle.dart';
import 'remote_host_chip.dart';
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
    final isChat = active?.mode == 'chat';

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
        const CommandTray(),
      ],
    );
  }
}

/// Per-project header action for the focused project:
///  - **Local project** → a [MobileAccessToggle] (Enable/Disable mobile access),
///    which drives the paired-phone allowlist for this project.
///  - **Remote project** → a read-only [RemoteHostChip] (the host machine name);
///    you cannot manage another machine's allowlist from here.
///
/// Top-level rather than a private method so the per-project action logic —
/// including the `selectedRegistrationIdProvider` → `projectsProvider`
/// lookup — has one implementation, used by `WindowTitleBarContents`, and can
/// be exercised directly in tests without re-implementing it.
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

/// Handler status pill + configure button rendered in the window title bar.
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
class EditableSessionLeaf extends ConsumerWidget {
  final SessionEntry session;
  const EditableSessionLeaf({super.key, required this.session});

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
