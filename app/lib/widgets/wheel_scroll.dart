import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Moves [controller] by [delta] pixels, held inside its scroll extent.
void jumpScrollBy(ScrollController controller, double delta) {
  final position = controller.position;
  controller.jumpTo(
    (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    ),
  );
}

/// Sends a sideways-dominant wheel/trackpad scroll to [horizontal] ONLY.
///
/// A real trackpad swipe is never perfectly straight. With a vertical list
/// inside a horizontal one, the framework hands any sideways scroll carrying a
/// few pixels of drift to the innermost interested Scrollable — the vertical
/// one — and the content creeps up and down while refusing to move across.
/// A pointer signal goes to the FIRST registrant in hit-test order (innermost
/// out), so this only works from a node below the scrollable it is taking the
/// event away from. A vertical-dominant event is left alone, so the list keeps
/// its own scrolling and fling.
void claimSidewaysScroll(
  PointerSignalEvent event,
  ScrollController? horizontal,
) {
  if (event is! PointerScrollEvent) return;
  final delta = event.scrollDelta;
  if (delta.dx.abs() <= delta.dy.abs()) return;
  if (horizontal == null || !horizontal.hasClients) return;
  GestureBinding.instance.pointerSignalResolver.register(
    event,
    (_) => jumpScrollBy(horizontal, delta.dx),
  );
}
