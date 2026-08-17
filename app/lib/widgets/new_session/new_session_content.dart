import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_separator.dart';
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
/// [onOpenDrawer] is wired on mobile AND any touch platform (a tablet takes
/// the same branch, any width) so the canvas can surface a hamburger that
/// opens the slide-in `ProjectsDrawer`. [showSearchButton] is wired only on a
/// narrow, non-touch (mouse) desktop window, where the drawer is persistent
/// (no hamburger needed) but there's still no title-bar search field to fall
/// back on — see `new_session_screen.dart`.
class NewSessionContent extends ConsumerWidget {
  const NewSessionContent({
    super.key,
    this.onOpenDrawer,
    this.showSearchButton = false,
  });

  final VoidCallback? onOpenDrawer;
  final bool showSearchButton;

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
    // Decided once here and handed BOTH to the bar and (inverted) to the list
    // below it: the fixed bar and the list's own scrolling header carry the
    // same title/chips/badges, so exactly one may mount — and re-deriving that
    // from platform+width in two places is how you end up with two or neither.
    final showTopBar = onOpenDrawer != null || showSearchButton;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            leaveNewSession(ref.container),
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: context.antgrid.bgDeepest,
          child: Column(
            children: [
              // Full width, not capped to _maxWidth like the column below: on
              // a wide tablet the centred column starts well clear of the
              // true left edge, which stranded the hamburger in the middle of
              // the screen instead of at the corner every other screen's menu
              // button occupies. True desktop has no drawer button (the
              // drawer is always on) and no search button (the title bar's
              // field covers it), so the bar collapses away entirely rather
              // than reserving a strip of empty canvas.
              if (showTopBar)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    AbTokens.space16,
                    // Zero on a touch platform: the hamburger/search icons'
                    // 44px tap targets (AbTokens.tapTargetMin) already make
                    // this row 44px tall, matching ProjectsDrawer's own
                    // fixed-44 `_Header` band exactly — any extra top inset
                    // here just pushes this row below the drawer's "antgrid"
                    // logo line instead of sharing it. The narrow-desktop
                    // search-button variant has no such band to match (its
                    // drawer renders no header at all), so it keeps the
                    // breathing room.
                    onOpenDrawer != null ? 0 : AbTokens.space8,
                    AbTokens.space16,
                    0,
                  ),
                  child: _TopBar(onOpenDrawer: onOpenDrawer),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxWidth),
                    child: Column(
                      children: [
                        // The desktop setup checklist moved to the sidebar
                        // (`FirstRunSetupSection` in projects_drawer.dart);
                        // mobile's fills RecentSessionsTab's empty slot below.
                        // Neither is mounted here any more.
                        const RemoteAccessNudgeBanner(),
                        // Recents fill the canvas. RefreshIndicator keeps the
                        // old pull-to-refresh contract (inventory + viewed
                        // machine advert).
                        Expanded(
                          child: RefreshIndicator(
                            onRefresh: () => _refresh(ref),
                            color: context.antgrid.accent,
                            backgroundColor: context.antgrid.bgElevated,
                            // The scrolling header duplicates what the
                            // fixed top bar above already shows, so exactly
                            // one of the two mounts — decided here, where
                            // both answers are in hand.
                            child: RecentSessionsTab(showHeader: !showTopBar),
                          ),
                        ),
                        Padding(
                          // No bottom inset here — SafeArea (wrapping this
                          // whole route) already reserves clearance from the
                          // system gesture bar; stacking this on top of it
                          // only pushed the composer further from the edge
                          // than either alone needed to.
                          padding: const EdgeInsets.fromLTRB(
                            AbTokens.space16,
                            AbTokens.space16,
                            AbTokens.space16,
                            0,
                          ),
                          child: NewSessionComposer(
                            onOpenFolder: () => _addProject(context, ref),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
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

/// Top bar: the mobile drawer button and the session-search icon, sharing
/// the row with either the sessions title + group-by chips + status badges
/// (tablet/desktop, one line) or the old combined title+badges summary line
/// (phone width, no chips — there's no room for a third element on a phone
/// row without overflowing).
///
/// This bar is mobile's navigation bar, which is where both platforms' search
/// guidance puts a search icon — reachable without scrolling, and costing a
/// glyph rather than the full row an inline field would take from a phone. A
/// touch tablet takes the exact same branch as a phone at the CODE level
/// (`onOpenDrawer` non-null either way), but is wide enough
/// (`>= kCompactBreakpoint`) to get the tablet/desktop arrangement below — the
/// width check here, not platform, is what actually picks the layout, since a
/// narrow mouse-desktop window (search-button variant, `onOpenDrawer` null)
/// is never phone-width either (`NewSessionScreen` routes anything that
/// narrow through the phone `Scaffold.drawer` branch regardless of platform).
///
/// Carries no breadcrumb — the composer's project chip already names the
/// target, and the route is self-evidently New Session.
class _TopBar extends StatelessWidget {
  const _TopBar({this.onOpenDrawer});

  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    final isPhoneWidth = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (onOpenDrawer != null) ...[
              AbIconButton(icon: AbIcons.menu, onTap: onOpenDrawer),
              const SizedBox(width: AbTokens.space8),
            ],
            if (isPhoneWidth) ...[
              const Expanded(child: RecentSessionsSummaryLine()),
              const SizedBox(width: AbTokens.space8),
              const SessionSearchButton(),
            ] else ...[
              const Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RecentSessionsTitle(),
                ),
              ),
              const SizedBox(width: AbTokens.space10),
              // Hides itself with no recent sessions to group — see its own doc.
              const RecentGroupByChips(),
              const SizedBox(width: AbTokens.space10),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Flexible, not bare: the badges are a Wrap, and a Wrap
                    // handed unbounded main-axis constraints (a raw child of
                    // this Row) never wraps and overruns the edge — see
                    // RecentSessionsSummaryBadges's own hazard note.
                    const Flexible(child: RecentSessionsSummaryBadges()),
                    const SizedBox(width: AbTokens.space8),
                    const SessionSearchButton(),
                  ],
                ),
              ),
            ],
          ],
        ),
        // A phone has no room for the chips on the row above — the summary
        // line and the search icon already fill it — so they get a row of
        // their own rather than being dropped, which left Recent stuck on its
        // default grouping with nothing anywhere to change it. Right-aligned
        // and self-hiding when there are no sessions to group, exactly as the
        // scrolling header used to render them at this width.
        if (isPhoneWidth) ...[
          const SizedBox(height: AbTokens.space8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [RecentGroupByChips()],
          ),
        ],
        const SizedBox(height: AbTokens.space8),
        const AbSeparator.horizontal(),
      ],
    );
  }
}
