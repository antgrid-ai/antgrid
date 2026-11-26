import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';
import 'ab_touch_sizing.dart';

/// Marks a subtree whose host already owns the vertical touch dimension — a
/// list row that spans the full width and is tappable across its whole height.
/// Inside it [AbTapTarget] inflates width only, so a trailing icon cluster
/// can't drive the row's height past the height its density asked for.
///
/// Without this, a 24px icon button inflating to 44px sets the row's height:
/// a `sm` drawer row measured 40px on desktop and 60px on mobile.
class AbCompactTapTargets extends InheritedWidget {
  const AbCompactTapTargets({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AbCompactTapTargets>() != null;

  @override
  bool updateShouldNotify(AbCompactTapTargets oldWidget) => false;
}

/// Guarantees a [minSize]-square interactive area around [child] on mobile;
/// on desktop it is a pixel-identical passthrough (precise pointers don't
/// need the inflation, and dense toolbars must stay compact).
///
/// Layout-affecting on purpose: Flutter hit-tests the laid-out render
/// geometry, so hit-slop that occupies no layout space is unreliable —
/// ancestors clip it or a sibling painted over the slop wins the hit.
/// Reserving real space and centering the visual is the only robust way
/// to guarantee the target.
///
/// A bounded parent caps the inflation on its own ([ConstrainedBox] enforces
/// the additional constraints against the incoming ones), which is why a
/// fixed-height host like a tab needs no opt-out. Hosts that size to their
/// children — a [Row] in a list row — must declare [AbCompactTapTargets].
///
/// Platform branching uses [isMobilePlatform], which reads
/// `defaultTargetPlatform` — so widget tests can flip it with
/// `debugDefaultTargetPlatformOverride`.
class AbTapTarget extends StatelessWidget {
  const AbTapTarget({
    super.key,
    this.minSize = AbTokens.tapTargetMin,
    this.onTap,
    required this.child,
  });

  final double minSize;

  /// When set, the whole inflated target (not just [child]) is tappable —
  /// the gesture surface sits outside the constraint with
  /// [HitTestBehavior.opaque] so the padding margin claims hits. Leave null
  /// for non-interactive children (e.g. a disabled button that must keep the
  /// same footprint as its enabled twin).
  final VoidCallback? onTap;

  final Widget child;

  /// Edge of the square a target reserves in [context]: 0 on desktop, else
  /// [minSize] raised to the phone touch extent.
  ///
  /// The one place the rule lives, so a caller reserving a button's width
  /// ([AbIconButton.footprintWidth]) cannot drift from what the button lays
  /// out. A [minSize] below the default is a height the caller has budgeted
  /// — a full-width header whose extra height would come out of a list — and
  /// the touch extent does not override it.
  static double minExtent(
    BuildContext context, {
    double minSize = AbTokens.tapTargetMin,
  }) {
    if (!isMobilePlatform) return 0;
    if (minSize < AbTokens.tapTargetMin) return minSize;
    return math.max(AbTouchSizing.extentOf(context), minSize);
  }

  /// Run spacing for a [Wrap] of tap targets. Where each target reserves the
  /// touch height, its footprint already separates the lines and [base] on top
  /// would read as detached rows; inside [AbCompactTapTargets] the targets
  /// keep their own height and still need it.
  static double wrapRunSpacing(BuildContext context, double base) =>
      AbTouchSizing.extentOf(context) > 0 && !AbCompactTapTargets.of(context)
      ? 0
      : base;

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    if (isMobilePlatform) {
      final extent = minExtent(context, minSize: minSize);
      result = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: extent,
          minHeight: AbCompactTapTargets.of(context) ? 0.0 : extent,
        ),
        // Factors force Center to shrink-wrap the child; without them Align
        // expands to fill any bounded parent, blowing up row layouts.
        child: Center(widthFactor: 1, heightFactor: 1, child: result),
      );
    }
    if (onTap != null) {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: result,
      );
    }
    return result;
  }
}
