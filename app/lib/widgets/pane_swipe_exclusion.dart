import 'package:flutter/widgets.dart';

/// Marks [child] as a strip whose horizontal drags are its own, so a sideways
/// fling that STARTS on it never opens or closes a pane.
///
/// The shell's pane flings watch raw pointers, which is what lets them fire
/// over a terminal or list that already won the gesture arena — and also what
/// made a swipe along the touch key bar's scrolling strip open the sidebar. An
/// arena win cannot stop a raw listener, so the strip says so directly: a
/// pointer-down reaches the deepest listener first, so this records the pointer
/// before any ancestor dispatcher sees the same down and checks [claims].
class PaneSwipeExclusion extends StatelessWidget {
  const PaneSwipeExclusion({super.key, required this.child});

  final Widget child;

  static final Set<int> _claimed = {};

  /// Whether [pointer] went down inside an exclusion zone. Only meaningful at
  /// pointer-down time: the zone forgets the pointer on up, which reaches it
  /// before any ancestor.
  static bool claims(int pointer) => _claimed.contains(pointer);

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => _claimed.add(e.pointer),
      onPointerUp: (e) => _claimed.remove(e.pointer),
      onPointerCancel: (e) => _claimed.remove(e.pointer),
      child: child,
    );
  }
}
