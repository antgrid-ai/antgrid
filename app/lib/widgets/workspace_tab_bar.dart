import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../models/workspace_view.dart';

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
    this.onClose,
  });

  final WorkspaceView selected;
  final ValueChanged<WorkspaceView> onSelected;
  final Map<WorkspaceView, int> badges;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onClose;

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
          if (onToggleExpand != null || onClose != null)
            Padding(
              padding: const EdgeInsets.only(right: AbTokens.space6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: AbTokens.space2,
                children: [
                  if (onToggleExpand != null)
                    AbIconButton(
                      icon: isExpanded ? AbIcons.collapse : AbIcons.expand,
                      tooltip: isExpanded ? 'Restore' : 'Expand',
                      onTap: onToggleExpand,
                    ),
                  // Hides the panel outright (not a collapse to a strip); the
                  // window title bar's panel control is the way back.
                  if (onClose != null)
                    AbIconButton(
                      icon: AbIcons.close,
                      tooltip: 'Hide panel',
                      onTap: onClose,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A workspace view's pending-count badge. Shared by the tab strip's
/// [_TabItem] and the agent bar's workspace menu (`WorkspaceMenuPanel` in
/// `workspace_menu_button.dart`) so a count reads identically — same shape,
/// and [active] (the view's selected state, not hover) drives the same
/// dim-unless-selected foreground in both places rather than two widgets that
/// could quietly diverge.
class WorkspaceViewBadge extends StatelessWidget {
  const WorkspaceViewBadge({super.key, required this.count, this.active = false});

  final int count;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space4,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: p.bgRaised,
        border: Border.all(color: p.borderSubtle),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: active ? p.textPrimary : p.textMuted,
        ),
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

    return Semantics(
      button: true,
      selected: widget.isActive,
      // The badge is drawn as a bare number, which announces as a stray digit
      // after the tab name; folding it into the label is what makes it read as
      // this tab's count. A bare GestureDetector announces as nothing at all,
      // so both the role and the selected state have to be stated here.
      label: widget.badgeCount > 0
          ? '${widget.view.label}, ${widget.badgeCount}'
          : widget.view.label,
      // Excluding the subtree takes the GestureDetector's tap action with it,
      // which would leave a button assistive tech can see and cannot press.
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
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
                  color: widget.isActive
                      ? context.antgrid.accent
                      : Colors.transparent,
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
                  WorkspaceViewBadge(
                    count: widget.badgeCount,
                    active: widget.isActive,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
