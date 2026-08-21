import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_menu.dart';
import '../providers/visible_surface.dart';
// The shared popup-panel chrome (section header + hover/focus row) that the
// composer's environment and branch pickers already use, so every grouped popup
// in the app reads as one control.
import 'new_session/environment_menu.dart' show PanelRow, PanelSectionHeader;
import 'workspace_tab_bar.dart';

/// The agent bar's way into the workspace views: a dropdown naming all five,
/// anchored under the icon (see the popup doc below) — the SAME popup on a
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
/// **The popup is pinned, not modal, and it starts open.** It hangs in the
/// overlay with no barrier, so it survives every click that lands elsewhere —
/// including the ones that drive the agent underneath it — and the icon is
/// the only thing that shuts it. That is why it cannot be a [showAbPanel]
/// route: a [PopupRoute] both closes on the first outside click and swallows
/// that click on the way. The trade is that a pinned popup is invisible in
/// the icon's resting look, so the icon latches on ([AbIconButton.selected])
/// for as long as the menu is up.
///
/// Open/closed is [workspaceMenuOpenProvider], not local state — see there for
/// why the button cannot be trusted to remember it.
///
/// Renders nothing when [workspaceMenuControlProvider] is null — the New
/// Session route and the settings overlay have no workspace to reveal, and a
/// menu there would list five views that don't exist yet.
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

  @override
  void initState() {
    super.initState();
    // The controller is detached here otherwise, so this is a queued show
    // that the OverlayPortal below picks up when it mounts. That queueing is
    // what brings the menu back with the button after a workspace surface
    // took the agent bar down — and what opens it on the first session of the
    // launch, with no click at all.
    if (ref.read(workspaceMenuOpenProvider)) {
      _portal.show();
    }
  }

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
    // The portal can also fall out of step without the flag moving: a workbench
    // surface covering the route unmounts it while THIS State survives, so
    // initState never re-runs to re-queue the show. Repaired after the frame
    // because show/hide must not run during a build.
    if (open != _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(ref.read(workspaceMenuOpenProvider));
      });
    }

    return OverlayPortal(
      controller: _portal,
      // Deliberately no dismiss barrier: a click outside the panel must reach
      // whatever it landed on, unchanged. The Align is what keeps that true —
      // the overlay hands its child the whole screen, and the popup surface's
      // Material paints a shape, whose CustomPaint hit-tests as OPAQUE over
      // every pixel it is given. Screen-sized, it would silently swallow every
      // click in the window while the menu was up. Align loosens the
      // constraints so the surface is only as big as the menu.
      overlayChildBuilder: (_) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          // Right-aligned under the icon. The button lives at the agent bar's
          // trailing edge, so hanging the panel leftward from it is the only
          // placement that stays inside the window.
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, AbTokens.space4),
          child: const AbPopupSurface(child: WorkspaceMenuPanel()),
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

/// Panel content: one row per [WorkspaceView], badged and check-marked to match
/// the tab strip. Live (ConsumerWidget) so a commit landing or an escalation
/// arriving updates the counts while the menu is open.
///
/// Picking a view does not close the menu — only the icon does — so the check
/// mark moving to the row just tapped is the confirmation. Picking a view
/// un-hides the docked context panel if the user had it closed, then selects
/// that view there, alongside the agent.
class WorkspaceMenuPanel extends ConsumerWidget {
  const WorkspaceMenuPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final control = ref.watch(workspaceMenuControlProvider);
    final badges = ref.watch(workspaceBadgesProvider);
    final gitStat = ref.watch(gitDiffTotalsProvider);
    if (control == null) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Workspace', mono: false),
        for (final view in WorkspaceView.values)
          PanelRow(
            icon: view.icon,
            label: view.label,
            selected: view == control.active,
            mono: false,
            // The Git row trades its file count for the worktree's +/-: how
            // much changed is what the row is read for, and one trailing
            // figure is all it has room for. The tab strip deliberately
            // keeps its plain count: five tabs on one scrolling row have no
            // space for a figure this wide.
            trailing: _viewTrailing(
              view: view,
              badge: badges[view],
              gitStat: gitStat,
              active: view == control.active,
            ),
            onTap: () => control.reveal(view),
          ),
      ],
    );
  }

  Widget? _viewTrailing({
    required WorkspaceView view,
    required int? badge,
    required GitDiffTotals gitStat,
    required bool active,
  }) {
    if (view == WorkspaceView.git &&
        (gitStat.additions > 0 || gitStat.deletions > 0)) {
      return AbDiffStat(
        additions: gitStat.additions,
        deletions: gitStat.deletions,
      );
    }
    if (badge == null) return null;
    return WorkspaceViewBadge(count: badge, active: active);
  }
}
