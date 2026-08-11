import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../screens/file_explorer_screen.dart';
import '../screens/preview_screen.dart';
import 'git_panel.dart';
import 'handler/handler_screen.dart';
import 'terminal_list_view.dart';
import 'workspace_tab_bar.dart';

/// Renders the workspace area. The horizontal [WorkspaceTabBar] sits at the
/// top on desktop; on mobile the caller hides it and uses [MobileBottomNav]
/// instead.
class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({
    super.key,
    required this.selectedView,
    required this.onViewSelected,
    this.viewBadges = const {},
    this.isExpanded = false,
    this.onToggleExpand,
    this.onClose,
    this.showTabBar = true,
  });

  final WorkspaceView selectedView;
  final ValueChanged<WorkspaceView> onViewSelected;
  final Map<WorkspaceView, int> viewBadges;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onClose;
  final bool showTabBar;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.antgrid.bgDeep,
      child: Column(
        children: [
          if (showTabBar)
            WorkspaceTabBar(
              selected: selectedView,
              onSelected: onViewSelected,
              badges: viewBadges,
              isExpanded: isExpanded,
              onToggleExpand: onToggleExpand,
              onClose: onClose,
            ),
          Expanded(
            child: IndexedStack(
              index: selectedView.index,
              children: const [
                PreviewScreen(),
                FileExplorerScreen(),
                GitPanel(),
                TerminalListView(),
                HandlerScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
