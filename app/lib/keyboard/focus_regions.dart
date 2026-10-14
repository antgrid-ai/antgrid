import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three areas F6 moves the keyboard between, in screen order.
enum AppFocusArea { projects, agent, context }

/// Where each [AppFocusArea] is mounted, so a chord can put the keyboard in
/// one without the chord's handler being able to reach that widget.
class FocusAreaRegistry {
  final _nodes = <AppFocusArea, List<FocusNode>>{};

  void _add(AppFocusArea area, FocusNode node) =>
      (_nodes[area] ??= []).add(node);

  void _remove(AppFocusArea area, FocusNode node) => _nodes[area]?.remove(node);

  /// The most recently mounted node for [area]: a route pushed over another
  /// mounts its own copy, and that is the one on screen.
  FocusNode? _node(AppFocusArea area) => _nodes[area]?.lastOrNull;

  bool isMounted(AppFocusArea area) => _node(area) != null;

  /// The area holding the keyboard right now, or null.
  AppFocusArea? get current {
    for (final area in AppFocusArea.values) {
      if (_node(area)?.hasFocus ?? false) return area;
    }
    return null;
  }

  /// Puts the keyboard on [area]'s first focusable control. False when the
  /// area is not mounted or has nothing to focus.
  bool focus(AppFocusArea area) {
    final node = _node(area);
    if (node == null) return false;
    final target = node.traversalDescendants
        .where((n) => n.canRequestFocus && !n.skipTraversal)
        .firstOrNull;
    if (target == null) return false;
    target.requestFocus();
    return true;
  }
}

final focusAreaRegistryProvider = Provider<FocusAreaRegistry>(
  (ref) => FocusAreaRegistry(),
  name: 'focusAreaRegistry',
);

/// Marks [child] as [area] for the focus-area chords. Takes no focus itself.
class FocusArea extends ConsumerStatefulWidget {
  const FocusArea({super.key, required this.area, required this.child});

  final AppFocusArea area;
  final Widget child;

  @override
  ConsumerState<FocusArea> createState() => _FocusAreaState();
}

class _FocusAreaState extends ConsumerState<FocusArea> {
  late final FocusAreaRegistry _registry;
  late final FocusNode _node = FocusNode(
    debugLabel: 'focus-area-${widget.area.name}',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void initState() {
    super.initState();
    _registry = ref.read(focusAreaRegistryProvider);
    _registry._add(widget.area, _node);
  }

  @override
  void didUpdateWidget(FocusArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.area != widget.area) {
      _registry._remove(oldWidget.area, _node);
      _registry._add(widget.area, _node);
    }
  }

  @override
  void dispose() {
    _registry._remove(widget.area, _node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _node, child: widget.child);
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
