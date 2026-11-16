import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../providers/visible_surface.dart';
import 'workspace_tab_bar.dart';

/// The phone's workspace switcher.
///
/// Lists [visibleWorkspaceViewsProvider], the same list the desktop strip and
/// the agent bar's rail read — a permanently present Inbox item here, with the
/// tab absent everywhere else, is precisely what one shared rule prevents.
///
/// Carries its own [AbCarbonScope] at a fixed position, so the shell around it
/// stays Ab chrome.
class MobileBottomNav extends ConsumerWidget {
  const MobileBottomNav({
    super.key,
    required this.selected,
    required this.onSelected,
    this.badges = const {},
    this.onAgent,
  });

  final WorkspaceView selected;
  final ValueChanged<WorkspaceView> onSelected;

  /// Returns to the agent conversation, the PageView's other page. When set,
  /// the bar leads with an item for it: the only other ways back are a swipe
  /// nothing on screen hints at and Android's system Back, which iOS lacks.
  final VoidCallback? onAgent;

  /// Same map the desktop [WorkspaceTabBar] renders. Mobile is the surface
  /// Handler exists for, and the kebab's attention row lives in the agent
  /// header — the OTHER swipe page — so without a count here the focused
  /// session's unanswered escalation has nothing standing for it on the page
  /// the user is looking at.
  ///
  /// The focused session's, not the project's: the Handler tab renders one
  /// session, so a badge counting the rest would name a number that tab cannot
  /// account for. A sibling session speaks on its own drawer row instead
  /// (`CarbonSessionHandlerBadge`).
  final Map<WorkspaceView, int> badges;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(visibleWorkspaceViewsProvider);
    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          final theme = CarbonTheme.of(context);
          return Container(
            // The label and glyph need more than the bare finger target, so the
            // bar sits one step above it on every density.
            height: theme.minTarget + CarbonSpacing.spacing04,
            decoration: BoxDecoration(
              color: theme.colors.layer01,
              border: Border(
                top: BorderSide(color: theme.colors.borderSubtle01),
              ),
            ),
            child: Row(
              children: [
                if (onAgent case final onAgent?)
                  Expanded(
                    child: _NavItem(
                      icon: CarbonIcons.chat,
                      label: 'Agent',
                      semanticLabel: 'Back to agent',
                      onTap: onAgent,
                    ),
                  ),
                for (final view in views)
                  Expanded(
                    child: _NavItem(
                      icon: view.carbonIcon,
                      label: view.label,
                      semanticLabel: workspaceViewSemanticLabel(
                        view,
                        badges[view] ?? 0,
                      ),
                      isActive: view == selected,
                      badgeCount: badges[view] ?? 0,
                      onTap: () => onSelected(view),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.isActive,
    this.badgeCount = 0,
  });

  final CarbonIcons icon;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  /// Null for an action rather than a tab: the agent item leaves this page and
  /// is never the open view, so announcing it as "not selected" would present
  /// it as one more tab.
  final bool? isActive;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final active = isActive ?? false;
    final iconColor = active ? colors.iconPrimary : colors.iconSecondary;
    final textColor = active ? colors.textPrimary : colors.textSecondary;

    return Semantics(
      button: true,
      selected: isActive,
      // The tag is a bare number floating over the glyph, which announces as a
      // stray digit next to the tab name; folding it into the label is what
      // makes it read as this tab's count. A bare GestureDetector announces as
      // nothing at all, so the role and selected state are stated here too.
      label: semanticLabel,
      // Excluding the subtree takes the GestureDetector's tap action with it,
      // which would leave a button assistive tech can see and cannot press.
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: CarbonBorders.indicator,
              child: ColoredBox(
                color: active ? colors.borderInteractive : colors.layer01,
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Overlaid rather than laid out beside the glyph: the items
                  // split the bar evenly, so an inline count would shift this
                  // item's icon out of line with its neighbours.
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CarbonIcon(icon, color: iconColor),
                      if (badgeCount > 0)
                        Positioned(
                          top: -CarbonSpacing.spacing02,
                          left: theme.iconSize - CarbonSpacing.spacing02,
                          child: ExcludeSemantics(
                            child: CarbonTag(
                              label: workspaceViewCountText(badgeCount),
                              size: CarbonTagSize.small,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: CarbonSpacing.spacing01),
                  // The items share the bar's width, so "Terminals" already
                  // runs close to its slot at the default text scale and past
                  // it at any larger one. Ellipsized, it shortens; unbounded,
                  // it overflows.
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.helper.copyWith(
                      color: textColor,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
