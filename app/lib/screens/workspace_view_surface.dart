import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_toolbar.dart';
import '../navigation/back_intent.dart';
import '../widgets/workspace_panel.dart';
import '../widgets/workspace_tab_bar.dart';

/// One workspace view, given the whole workbench area.
///
/// Opened from the agent bar's workspace menu. It replaces the agent/context
/// split rather than floating over it — the same slot `AppSettingsScreen`
/// occupies, and the same chrome: a panel header carrying the view's name, and
/// the projects drawer left standing beside it.
///
/// The tab strip is deliberately off. The surface shows the ONE view the user
/// named; a strip here would offer to change that in a second place, and the
/// menu that opened it already answers "show me a different one".
class WorkspaceViewSurface extends StatelessWidget {
  const WorkspaceViewSurface({
    super.key,
    required this.view,
    required this.onClose,
    this.panelKey,
  });

  /// Keys, not tooltips, are how tests reach these: the view mounted below
  /// brings its own header, and "Close" is not a name it has to give up.
  @visibleForTesting
  static const backKey = Key('workspace-surface-back');

  @visibleForTesting
  static const closeKey = Key('workspace-surface-close');

  final WorkspaceView view;
  final VoidCallback onClose;

  /// Passed straight to the [WorkspacePanel] so the shell can hand this the
  /// same GlobalKey the docked panel uses — that is what reparents the live
  /// preview WebView and terminals instead of rebuilding them.
  final Key? panelKey;

  @override
  Widget build(BuildContext context) {
    return BackHandler(
      priority: BackPriority.workspaceSurface,
      onBack: () {
        onClose();
        return true;
      },
      child: ColoredBox(
        color: context.antgrid.bgDeep,
        child: Column(
          children: [
            AbToolbar.panel(
              title: view.label,
              leading: AbIconButton(
                key: backKey,
                icon: AbIcons.back,
                tooltip: 'Back to agent',
                onTap: onClose,
              ),
              actions: [
                AbIconButton(
                  key: closeKey,
                  icon: AbIcons.close,
                  tooltip: 'Close',
                  onTap: onClose,
                ),
              ],
            ),
            Expanded(
              child: WorkspacePanel(
                key: panelKey,
                selectedView: view,
                // Nothing can call this with the strip off; the surface's view
                // is fixed for as long as it is up.
                onViewSelected: (_) {},
                showTabBar: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
