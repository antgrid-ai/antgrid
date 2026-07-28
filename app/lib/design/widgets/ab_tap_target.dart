import 'package:flutter/widgets.dart';

import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    if (isMobilePlatform) {
      result = ConstrainedBox(
        constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
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
