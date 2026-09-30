import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
