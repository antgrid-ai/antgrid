import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_snack_bar.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/projects.dart';
import '../../providers/recent_sessions.dart';
import '../open_folder_button.dart';
import '../recent_sessions/recent_sessions_tab.dart';
import 'first_run_checklist.dart';
import 'new_session_composer.dart';
import 'picker_sources.dart';
import 'remote_access_nudge_banner.dart';

/// Canvas for the New Session page: recent sessions fill the space above a
/// bottom-anchored composer (chip row + prompt input). The composer is the
/// start affordance — there is no separate Start button or tab strip.
///
/// [onOpenDrawer] is wired on mobile so the canvas can surface a hamburger
/// that opens the slide-in `ProjectsDrawer`.
class NewSessionContent extends ConsumerWidget {
  const NewSessionContent({super.key, this.onOpenDrawer});

  final VoidCallback? onOpenDrawer;

  static const double _maxWidth = 680;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Esc cancels new-session mode. `Focus(autofocus: true)` puts focus on the
    // canvas so the shortcut fires without a manual tap; tapping into the
    // composer's prompt field moves focus to that field (so typing/Esc-in-field
    // behave normally) — pressing Esc while not editing still bubbles up here.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            leaveNewSession(ref.container),
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: context.antgrid.bgDeepest,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AbTokens.space16,
                      AbTokens.space16,
                      AbTokens.space16,
                      0,
                    ),
                    child: _TopBar(onOpenDrawer: onOpenDrawer),
                  ),
                  const FirstRunChecklistCard(),
                  const RemoteAccessNudgeBanner(),
                  // Recents fill the canvas. RefreshIndicator keeps the old
                  // pull-to-refresh contract (inventory + viewed machine advert).
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () => _refresh(ref),
                      color: context.antgrid.accent,
                      backgroundColor: context.antgrid.bgElevated,
                      child: const RecentSessionsTab(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(AbTokens.space16),
                    child: NewSessionComposer(
                      onOpenFolder: () => _addProject(context, ref),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Pull-to-refresh handler for the New Session canvas: re-fetch the machine
  /// inventory (newly-added remote machines arrive over HTTPS), connect every
  /// machine behind the cached recent-session rows and re-peek their session
  /// lists ([pullToRefreshRecentSessions]), and re-pull the picker-viewed
  /// remote machine's live project advert alongside (null for Local — its
  /// projects are local folders, no control-plane pull).
  Future<void> _refresh(WidgetRef ref) async {
    final source = ref.read(visiblePickerSourceProvider);
    await pullToRefreshRecentSessions(
      ref,
      extraMachineUuids: [source?.machineUuid],
    );
  }

  /// Opens the OS folder picker directly — on success the picked folder is
  /// set as the session target so the composer's project chip reflects the
  /// selection without a second tap.
  Future<void> _addProject(BuildContext context, WidgetRef ref) async {
    // openFolderPicker upserts the folder and hands back its id (null on
    // cancel), so there's no need to re-derive the pick from provider side
    // effects. select: false — the pick is a composer form input, not "open
    // this project": focusing it here flipped the route to WorkspaceShell
    // (visible flash) and unmounted this widget before the target was set.
    //
    // The container, not `ref`, for everything past the picker: the OS dialog
    // can outlive this widget (a desktop resize across the layout breakpoint
    // tears the canvas down), and a `WidgetRef` read after that throws — yet
    // the target write below must still land.
    final container = ref.container;
    final String? id;
    try {
      id = await openFolderPicker(container, select: false);
    } catch (e) {
      if (context.mounted) {
        showAbSnackBar(context, 'Could not open folder: $e');
      }
      return;
    }
    if (id == null) return; // cancelled the OS picker

    final picked = container
        .read(projectsProvider)
        .where((p) => p.projectId == id)
        .firstOrNull;
    if (picked == null) return;

    container
        .read(selectedTargetProjectProvider.notifier)
        .set(
          PickerProject(
            id: picked.projectId,
            name: picked.displayName,
            detail: picked.folder,
            isLocal: true,
          ),
        );
  }
}

/// Top bar: optional hamburger and a mono breadcrumb.
///
/// Watches [selectedTargetProjectProvider] internally so picking a target only
/// rebuilds this bar, not the whole New Session canvas.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.onOpenDrawer});

  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final breadcrumbTarget =
        ref.watch(selectedTargetProjectProvider)?.name ?? 'no project';
    return Row(
      children: [
        if (onOpenDrawer != null) ...[
          AbIconButton(icon: AbIcons.menu, onTap: onOpenDrawer),
          const SizedBox(width: AbTokens.space8),
        ],
        Expanded(
          child: Text(
            '$breadcrumbTarget / new session',
            overflow: TextOverflow.ellipsis,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: context.antgrid.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}
