import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The areas F6 moves the keyboard between, in order.
///
/// Arrow keys cannot do this job: the agent's terminal owns them while it has
/// focus (shell history, TUI menus, the cursor). So F6 is the way OUT of the
/// terminal, and arrows take over once the keyboard is on the app's own rows.
enum FocusRegion { sidebar, agent, panel }

/// Wraps the projects sidebar, so "is the keyboard in the sidebar" is one
/// `hasFocus` away. Provider-owned for the same reason as the session search
/// node: the sidebar and the key handling live in unrelated subtrees.
final sidebarRegionFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(
    debugLabel: 'sidebar-region',
    canRequestFocus: false,
    skipTraversal: true,
  );
  ref.onDispose(node.dispose);
  return node;
}, name: 'sidebarRegionFocus');

/// Wraps the context panel (tab strip and the tab's content).
final panelRegionFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(
    debugLabel: 'panel-region',
    canRequestFocus: false,
    skipTraversal: true,
  );
  ref.onDispose(node.dispose);
  return node;
}, name: 'panelRegionFocus');

/// Puts the keyboard on the workspace tab strip, published by the mounted
/// `WorkspaceTabBar`. [focus] is null while no strip is on screen (context
/// panel hidden, phone layout) — which is also how F6 knows to skip the panel.
///
/// A plain holder rather than provider STATE: the strip has to publish from
/// `initState` and retract from `dispose`, and Riverpod refuses a state write
/// in either. Nothing needs notifying — it is read when a key is pressed.
class WorkspaceTabsFocus {
  VoidCallback? _focus;

  VoidCallback? get focus => _focus;

  void publish(VoidCallback focus) => _focus = focus;

  /// Only its own (a tear-off of the same method compares equal): a strip
  /// mounting in the same frame as the outgoing one's
  /// dispose may already have published.
  void retract(VoidCallback focus) {
    if (_focus == focus) _focus = null;
  }
}

final workspaceTabsFocusProvider = Provider<WorkspaceTabsFocus>(
  (ref) => WorkspaceTabsFocus(),
  name: 'workspaceTabsFocus',
);

/// Wraps a region's subtree with its region node.
class FocusRegionScope extends ConsumerWidget {
  const FocusRegionScope({super.key, required this.region, required this.child})
    : assert(region != FocusRegion.agent);

  final FocusRegion region;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = region == FocusRegion.sidebar
        ? ref.watch(sidebarRegionFocusProvider)
        : ref.watch(panelRegionFocusProvider);
    return Focus(
      focusNode: node,
      canRequestFocus: false,
      skipTraversal: true,
      child: child,
    );
  }
}

/// Gives a tree row → to expand and ← to collapse.
///
/// Only when the key has something to do: → on an open row and ← on a closed
/// one fall through to ordinary arrow navigation, so the same keys still move
/// between rows and on across areas.
class TreeArrowKeys extends StatelessWidget {
  const TreeArrowKeys({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        // Only from the row itself — its focus node sits directly under this
        // one. A button inside the row (a project's trash, a file's stage)
        // sits a level deeper, and ← from one must move focus back to the
        // row, not collapse it.
        if (FocusManager.instance.primaryFocus?.parent != node) {
          return KeyEventResult.ignored;
        }
        final keyboard = HardwareKeyboard.instance;
        if (keyboard.isControlPressed ||
            keyboard.isAltPressed ||
            keyboard.isMetaPressed ||
            keyboard.isShiftPressed) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if ((key == LogicalKeyboardKey.arrowRight && !expanded) ||
            (key == LogicalKeyboardKey.arrowLeft && expanded)) {
          onToggle();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
