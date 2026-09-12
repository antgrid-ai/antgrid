import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/workspace_view.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/visible_surface.dart';

/// Layout visibility is independent of keyboard focus and widget mounting.
class DisplayVisibility extends ConsumerWidget {
  const DisplayVisibility({super.key, this.workspaceView, required this.child});
  final WorkspaceView? workspaceView;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = workspaceView == null
        ? ref.watch(agentSurfaceVisibleProvider)
        : ref.watch(visibleWorkspaceViewProvider) == workspaceView;
    return DisplayVisibilityScope(visible: visible, child: child);
  }
}

class DisplayVisibilityScope extends InheritedWidget {
  const DisplayVisibilityScope({
    super.key,
    required this.visible,
    required super.child,
  });
  final bool visible;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DisplayVisibilityScope>()
          ?.visible ??
      true;
  @override
  bool updateShouldNotify(DisplayVisibilityScope oldWidget) =>
      visible != oldWidget.visible;
}
