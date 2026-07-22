import 'package:flutter/material.dart';
import '../design/widgets/ab_icon.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import 'workspace_tab_bar.dart';

class MobileBottomNav extends StatelessWidget {
  const MobileBottomNav({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final WorkspaceView selected;
  final ValueChanged<WorkspaceView> onSelected;

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
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? context.antgrid.accent : context.antgrid.textMuted;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AbIcon(icon, size: 18, color: color),
          const SizedBox(height: AbTokens.space2),
          Text(
            label,
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
    );
  }
}
