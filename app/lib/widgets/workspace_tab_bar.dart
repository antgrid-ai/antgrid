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
///
/// Stateful for the strip's scroll position: the tabs outgrow the bar well
/// before the panel reaches its narrowest (the touch tablet's docked context
/// pane is a quarter of the window), so the last tabs sit off the right edge
/// and the selected one has to be scrolled back to whenever it changes —
/// picking Terminals from `WorkspaceMenuButton`'s popup otherwise swapped the
/// body while every visible tab stayed unselected.
class WorkspaceTabBar extends StatefulWidget {
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
  State<WorkspaceTabBar> createState() => _WorkspaceTabBarState();
}

class _WorkspaceTabBarState extends State<WorkspaceTabBar> {
  final _tabKeys = {for (final view in WorkspaceView.values) view: GlobalKey()};
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // The pane can open onto a tab that was never on screen (the popup selects
    // while the pane is closed), so the first layout needs the same reveal a
    // later selection change gets.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealSelected(animate: false),
    );
  }

  @override
  void didUpdateWidget(covariant WorkspaceTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      // After the frame: the newly selected tab has to be laid out before
      // ensureVisible can measure where to scroll it.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealSelected(animate: true),
      );
    }
  }

  void _revealSelected({required bool animate}) {
    if (!mounted) return;
    final tabContext = _tabKeys[widget.selected]?.currentContext;
    if (tabContext == null) return;
    Scrollable.ensureVisible(
      tabContext,
      // Centred rather than nudged to the nearest edge: the strip holds five
      // tabs in a pane that fits three, so centring keeps a neighbour visible
      // on either side and makes it obvious the rest scroll.
      alignment: 0.5,
      duration: animate ? AbTokens.motionDefault : Duration.zero,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
          //
          // The RawScrollbar is what makes that scrollability discoverable
          // and mouse-draggable rather than a dead end: without it, a narrow
          // panel with the selection centred (see [_revealSelected]) can push
          // BOTH end tabs off screen with nothing on screen hinting there's
          // more to scroll to, and a mouse (no touch drag, no trackpad
          // gesture) has no obvious way to get there. Top-anchored so it
          // never competes with each tab's own bottom active-state
          // underline; `thumbVisibility: true` only ever draws when the
          // strip actually overflows — a scrollbar has nothing to paint once
          // every tab already fits.
          Expanded(
            child: RawScrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              thickness: 3,
              radius: const Radius.circular(2),
              scrollbarOrientation: ScrollbarOrientation.top,
              child: SingleChildScrollView(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: Row(
                  children: [
                    for (final view in WorkspaceView.values)
                      _TabItem(
                        key: _tabKeys[view],
                        view: view,
                        isActive: view == widget.selected,
                        onTap: () => widget.onSelected(view),
                        badgeCount: widget.badges[view] ?? 0,
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.onToggleExpand != null || widget.onClose != null)
            Padding(
              padding: const EdgeInsets.only(right: AbTokens.space6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: AbTokens.space2,
                children: [
                  if (widget.onToggleExpand != null)
                    AbIconButton(
                      icon: widget.isExpanded
                          ? AbIcons.collapse
                          : AbIcons.expand,
                      tooltip: widget.isExpanded ? 'Restore' : 'Expand',
                      onTap: widget.onToggleExpand,
                    ),
                  // Hides the panel outright (not a collapse to a strip); the
                  // window title bar's panel control is the way back.
                  if (widget.onClose != null)
                    AbIconButton(
                      icon: AbIcons.close,
                      tooltip: 'Hide panel',
                      onTap: widget.onClose,
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
  const WorkspaceViewBadge({
    super.key,
    required this.count,
    this.active = false,
  });

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
    super.key,
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
