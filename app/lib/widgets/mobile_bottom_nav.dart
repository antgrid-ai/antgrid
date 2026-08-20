import 'package:flutter/material.dart';
import '../design/widgets/ab_icon.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import 'workspace_tab_bar.dart';

const _navIconSize = 18.0;

class MobileBottomNav extends StatelessWidget {
  const MobileBottomNav({
    super.key,
    required this.selected,
    required this.onSelected,
    this.badges = const {},
  });

  final WorkspaceView selected;
  final ValueChanged<WorkspaceView> onSelected;

  /// Same map the desktop [WorkspaceTabBar] renders. Mobile is the surface
  /// Handler exists for, and its `NEEDS YOU` pill lives in the agent header —
  /// the OTHER swipe page — so without a count here an unanswered escalation
  /// has nothing standing for it on the page the user is looking at.
  final Map<WorkspaceView, int> badges;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AbTokens.bottomNavHeight,
      decoration: BoxDecoration(
        color: context.antgrid.bgDeepest,
        border: Border(top: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: Row(
        children: [
          for (final view in WorkspaceView.values)
            Expanded(
              child: _NavItem(
                icon: view.icon,
                label: view.label,
                isActive: view == selected,
                badgeCount: badges[view] ?? 0,
                onTap: () => onSelected(view),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.badgeCount,
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool isActive;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? context.antgrid.accent : context.antgrid.textMuted;

    return Semantics(
      button: true,
      selected: isActive,
      // The badge is a bare number floating over the glyph, which announces as
      // a stray digit next to the tab name; folding it into the label is what
      // makes it read as this tab's count. A bare GestureDetector announces as
      // nothing at all, so the role and selected state are stated here too.
      label: badgeCount > 0 ? '$label, $badgeCount' : label,
      // Excluding the subtree takes the GestureDetector's tap action with it,
      // which would leave a button assistive tech can see and cannot press.
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Overlaid rather than laid out beside the glyph: the five items
            // split the bar evenly, so an inline count would shift this item's
            // icon out of line with its four neighbours.
            Stack(
              clipBehavior: Clip.none,
              children: [
                AbIcon(icon, size: _navIconSize, color: color),
                if (badgeCount > 0)
                  Positioned(
                    top: -AbTokens.space4,
                    left: _navIconSize - AbTokens.space4,
                    child: _NavBadge(count: badgeCount),
                  ),
              ],
            ),
            const SizedBox(height: AbTokens.space2),
            // Five items share the bar's width, so "Terminals" already runs
            // close to its slot at the default text scale and past it at any
            // larger one. Ellipsized, it shortens; unbounded, it overflows.
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AbTokens.fontSans,
                fontFamilyFallback: AbTokens.fontSansFallbacks,
                fontSize: AbTokens.fontXxs,
                color: color,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Deliberately the same neutral chrome as the desktop [WorkspaceTabBar]
/// badge. The map behind it is generic — Handler's pending count and Git's
/// changed-file tally share it — so an alarm tone here would be spent on both.
class _NavBadge extends StatelessWidget {
  const _NavBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space4,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: context.antgrid.bgRaised,
        border: Border.all(color: context.antgrid.borderSubtle),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXxs,
          color: context.antgrid.textPrimary,
        ),
      ),
    );
  }
}
