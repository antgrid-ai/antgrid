import 'package:flutter/widgets.dart';

import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    if (isMobilePlatform) {
      final compact = AbCompactTapTargets.of(context);
      result = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minSize,
          minHeight: compact ? 0.0 : minSize,
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
