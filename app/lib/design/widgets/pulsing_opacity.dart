import 'package:flutter/widgets.dart';

/// Repeats a 0.45 → 1.0 opacity pulse so a glyph can convey "running" without
/// fully disappearing. 900ms cycle, easeInOut.
class PulsingOpacity extends StatefulWidget {
  final Widget child;

  /// Bottom of a matching size pulse, painted on top of the fade; null for the
  /// fade alone.
  ///
  /// Opt-in because how much of a blink a fade produces depends entirely on how
  /// bright the thing is — it swings a near-white accent from brilliant to
  /// mid-gray and barely moves a mid-tone one, so the same animation reads as a
  /// blink on one theme preset and static on another. Scale is what makes it
  /// palette-independent. Only shapes whose size carries no meaning may take it:
  /// a dot, never text or a control, which would resize under the reader.
  ///
  /// Paint-time (Transform), so it never reflows anything around it.
  final double? minScale;

  const PulsingOpacity({super.key, required this.child, this.minScale});

  @override
  State<PulsingOpacity> createState() => _PulsingOpacityState();
}

class _PulsingOpacityState extends State<PulsingOpacity>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  // Started here (not initState) so the reduce-motion flag is readable, and
  // because didChangeDependencies re-fires on MediaQuery change — a live
  // reduce-motion flip stops/restarts the pulse without extra plumbing.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.stop();
      // Pin at full opacity (and full size) — the glyph itself already conveys
      // "running".
      _ctrl.value = 1.0;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        final faded = Opacity(opacity: 0.45 + 0.55 * t, child: child);
        final minScale = widget.minScale;
        if (minScale == null) return faded;
        return Transform.scale(
          scale: minScale + (1 - minScale) * t,
          child: faded,
        );
      },
      child: widget.child,
    );
  }
}
