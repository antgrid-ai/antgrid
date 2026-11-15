import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/ab_tokens.dart';
import '../models/workspace_view.dart';
import '../providers/visible_surface.dart';

/// The enum is a model — nothing below the widget layer may reach into this
/// file for it — but every widget-layer caller wants it together with the
/// presentation extension defined here, so it arrives through this import too.
export 'package:antgrid/models/workspace_view.dart';

extension WorkspaceViewUI on WorkspaceView {
  String get label => switch (this) {
    WorkspaceView.preview => 'Preview',
    WorkspaceView.files => 'Files',
    WorkspaceView.git => 'Git',
    WorkspaceView.terminals => 'Terminals',
    WorkspaceView.handler => 'Handler',
  };

  CarbonIcons get carbonIcon => switch (this) {
    WorkspaceView.preview => CarbonIcons.applicationWeb,
    WorkspaceView.files => CarbonIcons.folder,
    WorkspaceView.git => CarbonIcons.branch,
    WorkspaceView.terminals => CarbonIcons.terminal,
    WorkspaceView.handler => CarbonIcons.security,
  };
}

/// The count as drawn: capped, so a runaway backlog cannot widen a tab.
String workspaceViewCountText(int count) => count > 99 ? '99+' : '$count';

/// A view's accessible name with its count folded in ("Git, 3"). A bare
/// number beside the name announces as a stray digit; this is what makes it
/// read as the view's own backlog.
String workspaceViewSemanticLabel(WorkspaceView view, int count) =>
    count > 0 ? '${view.label}, ${workspaceViewCountText(count)}' : view.label;

/// The workspace header strip's total height, border included. One source for
/// [WorkspaceTabBar] and the agent bar so their tops and bottoms meet across
/// the resizable divider. Mirrors Carbon's tab height (40 compact, the finger
/// target on touch) from the same platform test [AbCarbonScope] uses, so the
/// agent bar can read it from outside its own scope.
double get workspaceStripHeight =>
    (AbCarbonScope.platformDensity == CarbonDensity.touch
        ? AbTokens.tapTargetMin
        : 40.0) +
    CarbonBorders.hairline;

/// Horizontal tab strip mounted at the top of the workspace panel. Height is
/// [workspaceStripHeight], which the agent bar shares so the two sit flush
/// across the resizable divider.
///
/// Which tabs it lists comes from [visibleWorkspaceViewsProvider] rather than
/// from the caller: the phone's nav and the agent bar's rail read the same
/// provider, and a strip that took the list as a parameter could be handed a
/// different one.
///
/// Its own [AbCarbonScope] sits inside the widget, below the keyed
/// `WorkspacePanel`, so the panel's identity never depends on it.
class WorkspaceTabBar extends ConsumerWidget {
  const WorkspaceTabBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.badges = const {},
    this.isExpanded = false,
    this.onToggleExpand,
    this.onClose,
  });

  final WorkspaceView selected;
  final ValueChanged<WorkspaceView> onSelected;
  final Map<WorkspaceView, int> badges;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(visibleWorkspaceViewsProvider);
    // Read here, outside the scope: the Ab-side token behind it is host layout.
    final stripHeight = workspaceStripHeight;
    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          final theme = CarbonTheme.of(context);
          return Container(
            decoration: BoxDecoration(
              color: theme.colors.background,
              border: Border(
                bottom: BorderSide(color: theme.colors.borderSubtle00),
              ),
            ),
            child: SizedBox(
              height: stripHeight - CarbonBorders.hairline,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Touch and stylus drags are removed so the strip adds no
                  // horizontal drag recognizer beside the tablet's raw-pointer
                  // fling dispatcher; trackpad pans stay, as they never reach
                  // that dispatcher.
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: const <PointerDeviceKind>{
                          PointerDeviceKind.trackpad,
                        },
                      ),
                      child: CarbonTabs<WorkspaceView>(
                        semanticLabel: 'Workspace views',
                        activation: CarbonActivationMode.manual,
                        wheelScrollsSideways: true,
                        value: selected,
                        onChanged: onSelected,
                        // A re-tap re-publishes the selection so a pane that
                        // was closed or scrolled away reacts to the tab it
                        // was already on.
                        onReselect: onSelected,
                        tabs: [
                          for (final view in views)
                            CarbonOption<WorkspaceView>(
                              value: view,
                              label: view.label,
                              // CarbonTabs speaks the name then this, "Git, 3".
                              secondaryLabel: (badges[view] ?? 0) > 0
                                  ? workspaceViewCountText(badges[view]!)
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (onToggleExpand != null)
                    _StripButton(
                      // Expanded means the agent panel is gone from the window
                      // entirely (see `_PanelMode.contextExpanded`), so this
                      // is the only way back.
                      icon: isExpanded
                          ? CarbonIcons.minimize
                          : CarbonIcons.maximize,
                      label: isExpanded ? 'Restore' : 'Expand',
                      onPressed: onToggleExpand,
                    ),
                  // Hides the panel outright (not a collapse to a strip); the
                  // window title bar's panel control is the way back.
                  if (onClose != null)
                    _StripButton(
                      icon: CarbonIcons.close,
                      label: 'Hide panel',
                      onPressed: onClose,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final CarbonIcons icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => CarbonTooltip(
    message: label,
    excludeFromSemantics: true,
    alignment: CarbonTooltipAlignment.end,
    child: CarbonButton.iconOnly(
      icon: CarbonIcon(icon),
      semanticLabel: label,
      onPressed: onPressed,
    ),
  );
}

/// A workspace view's pending-count as a Carbon tag, empty when there is none.
/// Reads the same [workspaceBadgesProvider] the tab strip's count and the
/// workspace menu read, so a count is one figure everywhere. The tag is
/// decoration for a row that already speaks the count through
/// [workspaceViewSemanticLabel], so it carries no semantics of its own.
/// Must sit under an [AbCarbonScope].
class WorkspaceViewCountTag extends ConsumerWidget {
  const WorkspaceViewCountTag({super.key, required this.view});

  final WorkspaceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      workspaceBadgesProvider.select((badges) => badges[view] ?? 0),
    );
    if (count <= 0) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: CarbonTag(
        label: workspaceViewCountText(count),
        size: CarbonTagSize.small,
      ),
    );
  }
}
