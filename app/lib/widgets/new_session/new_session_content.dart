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
import '../recent_sessions/recent_sessions_summary.dart';
import '../recent_sessions/recent_sessions_tab.dart';
import '../session_search_modal.dart';
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

  // Matches the Claude desktop conversation column. The cap covers the whole
  // canvas (recents + composer) so the two read as one document rather than a
  // phone layout stranded mid-window.
  static const double _maxWidth = 880;

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
                  // Desktop has no drawer button (the drawer is always on), so
                  // the bar collapses away entirely rather than reserving a
                  // strip of empty canvas.
                  if (onOpenDrawer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AbTokens.space16,
                        AbTokens.space16,
                        AbTokens.space16,
                        0,
                      ),
                      child: _TopBar(onOpenDrawer: onOpenDrawer!),
                    ),
                  // The desktop setup checklist moved to the sidebar
                  // (`FirstRunSetupSection` in projects_drawer.dart); mobile's
                  // fills RecentSessionsTab's empty slot below. Neither is
                  // mounted here any more.
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

/// Top bar: the mobile drawer button and the session-search icon, with the
/// sessions count and its status badges sharing the row rather than costing one
/// of their own.
///
/// This bar is mobile's navigation bar, which is where both platforms' search
/// guidance puts a search icon — reachable without scrolling, and costing a
/// glyph rather than the full row an inline field would take from a phone.
///
/// Carries no breadcrumb — the composer's project chip already names the
/// target, and the route is self-evidently New Session.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.onOpenDrawer});

  final VoidCallback onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AbIconButton(icon: AbIcons.menu, onTap: onOpenDrawer),
        const SizedBox(width: AbTokens.space8),
        const Expanded(child: RecentSessionsSummaryLine()),
        const SizedBox(width: AbTokens.space8),
        const SessionSearchButton(),
      ],
    );
  }
}
