import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../providers/visible_surface.dart';
import 'carbon_diff_stat.dart';
import 'workspace_tab_bar.dart';

/// The agent bar's way into the workspace views: a rail naming those on offer,
/// anchored under the icon (see the popup doc below) — the SAME rail on a
/// touch tablet as on a mouse desktop, since the touch tablet's context panel
/// is now a docked pane beside the agent (see `WorkspaceShellState._buildTabletTouch`),
/// not an overlay covering it, so the two no longer compete for the same
/// screen space. (Mobile phone width never reaches this widget at all —
/// [workspaceMenuControlProvider] is always null there, since the workspace
/// is a swiped-to page, not a docked panel with a menu into it.)
///
/// A tap ALWAYS just toggles the popup — on every platform, regardless of
/// whether the touch tablet's docked context pane happens to be open or
/// closed. It used to also open the pane directly on a touch tablet when the
/// pane was closed (skipping the popup on the theory that there was nothing
/// to anchor a "pick a view" menu to yet), but that meant a tap could dock
/// the context pane instead of showing the popup the icon is for — the icon
/// must only ever show/hide its own popup, never take a side-effecting
/// shortcut on the pane. Opening the pane is still one tap away: pick any row
/// in the (now visible) popup, which un-hides it — see
/// [WorkspaceMenuPanel]'s doc.
///
/// **The popup is pinned, not modal.** It hangs in the overlay with no
/// barrier, so it survives every click that lands elsewhere — including the
/// ones that drive the agent underneath it — and the icon is the only thing
/// that shuts it BY HAND. That is why it cannot be a [showAbPanel] route: a
/// [PopupRoute] both closes on the first outside click and swallows that click
/// on the way. The trade is that a pinned popup is invisible in the icon's
/// resting look, so the icon latches on ([AbIconButton.selected]) for as long
/// as the rail is up.
///
/// The shell keeps it down for as long as the context pane is on screen, since
/// the pane's own [WorkspaceTabBar] already lists the same views (see
/// `WorkspaceShellState._syncMenuToContextPane`). What is left for the rail is
/// the one job nothing else can do — the way back to the workspace once the
/// pane is closed.
///
/// Open/closed is [workspaceMenuOpenProvider], not local state — see there for
/// why the button cannot be trusted to remember it.
///
/// Renders nothing when [workspaceMenuControlProvider] is null — the New
/// Session route and the settings overlay have no workspace to reveal, and a
/// menu there would list views that don't exist yet.
class WorkspaceMenuButton extends ConsumerStatefulWidget {
  const WorkspaceMenuButton({super.key});

  @visibleForTesting
  static const buttonKey = Key('workspace-menu-button');

  @override
  ConsumerState<WorkspaceMenuButton> createState() =>
      _WorkspaceMenuButtonState();
}

class _WorkspaceMenuButtonState extends ConsumerState<WorkspaceMenuButton> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  /// Guarded rather than a bare show/hide: hiding an already-hidden controller
  /// asserts while it is detached, which it is whenever no workspace is
  /// published.
  void _sync(bool open) {
    if (open == _portal.isShowing) return;
    open ? _portal.show() : _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final control = ref.watch(workspaceMenuControlProvider);
    if (control == null) return const SizedBox.shrink();

    final open = ref.watch(workspaceMenuOpenProvider);
    ref.listen(workspaceMenuOpenProvider, (_, next) => _sync(next));
    // Every way the portal can be out of step with the flag, including the
    // first build of all: the flag is app state that outlives this State (see
    // [workspaceMenuOpenProvider]), so a rail that was up when a workbench
    // surface took the agent bar down has to come back up with it, and a
    // session's first rail has to appear with no click at all. Repaired after
    // the frame because show/hide must not run during a build — which also
    // lets the shell's own post-frame pass, registered first from an ancestor
    // build, settle whether the context pane is up before the rail appears
    // over it for a frame.
    if (open != _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(ref.read(workspaceMenuOpenProvider));
      });
    }

    return OverlayPortal(
      controller: _portal,
      // Deliberately no dismiss barrier: a click outside the panel must reach
      // whatever it landed on, unchanged. The Align is what keeps that true —
      // the overlay hands its child the whole screen, and the panel's filled
      // box hit-tests as OPAQUE over every pixel it is given. Screen-sized, it
      // would silently swallow every click in the window while the menu was
      // up. Align loosens the constraints so the surface is only as big as the
      // rail.
      overlayChildBuilder: (_) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          // Right edges flush, hanging under the button. The button lives at
          // the agent bar's trailing edge, so leftward is the only direction
          // the panel can grow and stay inside the window.
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, AbTokens.space4),
          child: const WorkspaceMenuPanel(),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: AbIconButton(
          key: WorkspaceMenuButton.buttonKey,
          icon: AbIcons.workspace,
          selected: open,
          tooltip: 'Workspace',
          onTap: () => ref.read(workspaceMenuOpenProvider.notifier).set(!open),
        ),
      ),
    );
  }
}

/// The workspace rail: one row per [WorkspaceView], counted and marked to match
/// the tab strip. Live (a Consumer) so a commit landing or an escalation
/// arriving updates the counts while it is up.
///
/// A Carbon side-nav column on its own `layer01` surface, bordered and shadowed
/// so it reads over the transcript; the view on screen carries the selected
/// fill and start bar.
///
/// Picking a view opens the context pane, which is what takes the rail away —
/// the pane's own tab strip carries on from there (see
/// `WorkspaceShellState._syncMenuToContextPane`).
class WorkspaceMenuPanel extends ConsumerWidget {
  const WorkspaceMenuPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final control = ref.watch(workspaceMenuControlProvider);
    final badges = ref.watch(workspaceBadgesProvider);
    final gitStat = ref.watch(gitDiffTotalsProvider);
    final views = ref.watch(visibleWorkspaceViewsProvider);

    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          if (control == null) return const SizedBox.shrink();
          final theme = CarbonTheme.of(context);
          return Semantics(
            role: SemanticsRole.navigation,
            container: true,
            explicitChildNodes: true,
            label: 'Workspace views',
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colors.layer01,
                border: Border.all(color: theme.borderSubtle(1)),
                boxShadow: [
                  BoxShadow(
                    color: theme.colors.shadow,
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              // Shrink-wrapped rather than laid out at a fixed width, so the
              // rail ends where its longest label does. A fixed width has to
              // be sized for the widest row the rail can ever hold — the Git
              // row's whole-worktree `+N -M` — which leaves it two thirds
              // empty every other time.
              child: IntrinsicWidth(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: CarbonSpacing.spacing02,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final view in views)
                        _RailRow(
                          view: view,
                          selected: view == control.active,
                          count: badges[view] ?? 0,
                          gitStat: gitStat,
                          onTap: () => control.reveal(view),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The count pill, drawn from the tag's gray tokens rather than a CarbonTag:
/// the rail is intrinsically sized and CarbonTag's truncation tooltip is a
/// LayoutBuilder, which cannot report an intrinsic width.
class _RailCount extends StatelessWidget {
  const _RailCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final palette = theme.colors.tagGray;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.all(CarbonShape.pill),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: CarbonTagSize.small.height),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CarbonSpacing.spacing03,
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              workspaceViewCountText(count),
              style: theme.typography.label.copyWith(color: palette.foreground),
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }
}

/// One view's row.
class _RailRow extends StatelessWidget {
  const _RailRow({
    required this.view,
    required this.selected,
    required this.count,
    required this.gitStat,
    required this.onTap,
  });

  final WorkspaceView view;

  /// Whether this is the view on screen — not the row under the pointer.
  final bool selected;
  final int count;
  final GitDiffTotals gitStat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The Git row trades its file count for the worktree's +/-: how much
    // changed is what the row is read for, and one trailing figure is all it
    // has room for. The tab strip deliberately keeps its plain count — several
    // tabs on one scrolling row have no space for a figure this wide.
    final showStat =
        view == WorkspaceView.git &&
        (gitStat.additions > 0 || gitStat.deletions > 0);
    // The figures draw bare, which announce as a stray digit or as
    // punctuation after the view's name; folding them into the row's label is
    // what makes them read as this row's own count.
    final spoken = showStat
        ? '${view.label}, '
              '${CarbonDiffStat.describe(gitStat.additions, gitStat.deletions)}'
        : workspaceViewSemanticLabel(view, count);
    return CarbonSideNavLink(
      label: spoken,
      content: Text(view.label),
      icon: view.carbonIcon,
      current: selected,
      onPressed: onTap,
      trailing: [
        if (showStat)
          ExcludeSemantics(
            child: CarbonDiffStat(
              additions: gitStat.additions,
              deletions: gitStat.deletions,
            ),
          )
        else if (count > 0)
          ExcludeSemantics(child: _RailCount(count: count)),
      ],
    );
  }
}
