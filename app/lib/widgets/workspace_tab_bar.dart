import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';

enum WorkspaceView { preview, files, git, terminals, handler }

extension WorkspaceViewUI on WorkspaceView {
  String get label => switch (this) {
    WorkspaceView.preview => 'Preview',
    WorkspaceView.files => 'Files',
    WorkspaceView.git => 'Git',
    WorkspaceView.terminals => 'Terminals',
    WorkspaceView.handler => 'Handler',
  };

  String get icon => switch (this) {
    WorkspaceView.preview => AbIcons.preview,
    WorkspaceView.files => AbIcons.files,
    WorkspaceView.git => AbIcons.git,
    WorkspaceView.terminals => AbIcons.terminal,
    WorkspaceView.handler => AbIcons.shield,
  };
}

/// Horizontal tab strip mounted at the top of the workspace panel. Replaces
/// the previous vertical 48px `SidebarRail`. Height matches
/// [AbTokens.statusHeaderHeight] so it sits flush with the agent panel
/// header across the resizable divider.
class WorkspaceTabBar extends StatelessWidget {
  const WorkspaceTabBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.badges = const {},
    this.isExpanded = false,
    this.onToggleExpand,
  });

  final WorkspaceView selected;
  final ValueChanged<WorkspaceView> onSelected;
  final Map<WorkspaceView, int> badges;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AbTokens.statusHeaderHeight,
      decoration: BoxDecoration(
        color: context.antgrid.bgDeep,
        border: Border(bottom: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: Row(
        children: [
          // Tabs live inside a horizontally scrollable region so the Row
          // never overflows when the resizable context panel narrows past
          // the tabs' intrinsic width. Expanded gives the scroll view a
          // bounded width; the trailing expand affordance stays fixed.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  for (final view in WorkspaceView.values)
                    _TabItem(
                      view: view,
                      isActive: view == selected,
                      onTap: () => onSelected(view),
                      badgeCount: badges[view] ?? 0,
                    ),
                ],
              ),
            ),
          ),
          if (onToggleExpand != null)
            Padding(
              padding: const EdgeInsets.only(right: AbTokens.space6),
              child: AbIconButton(
                icon: isExpanded ? AbIcons.close : AbIcons.expand,
                tooltip: isExpanded ? 'Restore' : 'Expand',
                onTap: onToggleExpand,
              ),
            ),
        ],
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  const _TabItem({
    required this.view,
    required this.isActive,
    required this.onTap,
    required this.badgeCount,
  });

  final WorkspaceView view;
  final bool isActive;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final color = (widget.isActive || _hovering)
        ? context.antgrid.textPrimary
        : context.antgrid.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          // Pin each tab to the bar's full height so the active-tab accent
          // underline anchors flush at the bottom edge instead of floating
          // mid-bar at the tab's intrinsic content height.
          height: AbTokens.statusHeaderHeight,
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: widget.isActive ? context.antgrid.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              AbIcon(widget.view.icon, size: 14, color: color),
              const SizedBox(width: AbTokens.space6),
              Text(
                widget.view.label,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: color,
                ),
              ),
              if (widget.badgeCount > 0) ...[
                const SizedBox(width: AbTokens.space6),
                Container(
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
                    widget.badgeCount > 99 ? '99+' : '${widget.badgeCount}',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: widget.isActive
                          ? context.antgrid.textPrimary
                          : context.antgrid.textMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
