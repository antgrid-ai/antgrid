import 'package:flutter/widgets.dart';

/// Fades [child] in and out while keeping it laid out, leaving no composited
/// layer behind once the fade settles.
///
/// Exists because `AnimatedOpacity` composites unconditionally — its render
/// object reports `alwaysNeedsCompositing` for any child, so a settled pair of
/// them keeps two opacity layers alive at alpha 255 and 0, where both are
/// visually no-ops. Plain `Opacity` composites strictly between 0 and 1, so
/// driving it from a tween costs a layer only while the fade is running.
class AbCrossFade extends StatelessWidget {
  const AbCrossFade({
    super.key,
    required this.visible,
    required this.duration,
    required this.child,
  });

  final bool visible;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // No `begin`: TweenAnimationBuilder seeds it from `end` on the first
      // build, so the widget mounts already settled instead of fading in.
      tween: Tween<double>(end: visible ? 1 : 0),
      duration: duration,
      child: child,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
    );
  }
}
