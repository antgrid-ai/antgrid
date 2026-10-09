import 'package:flutter/widgets.dart';

import '../utils/platform_utils.dart';

/// Terminal scrollback that stops where the finger lifts.
///
/// A flung terminal glides through rows faster than they can be read, and on a
/// phone it kept moving after the user's hand had stopped. Clamping still
/// settles a position pushed past either end; only the glide is dropped.
class FingerTrackingScrollPhysics extends ClampingScrollPhysics {
  const FingerTrackingScrollPhysics({super.parent});

  @override
  FingerTrackingScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FingerTrackingScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    return null;
  }
}

/// What a terminal view's scrollable should use: no glide on a phone, the
/// view's own default elsewhere.
ScrollPhysics? get terminalScrollPhysics =>
    isMobilePlatform ? const FingerTrackingScrollPhysics() : null;
