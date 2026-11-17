import 'package:flutter/widgets.dart';

import 'pulse_builder.dart';

/// Repeats a 0.45 → 1.0 opacity pulse so a glyph can convey "running" without
/// fully disappearing. 900ms in each direction, easeInOut.
class PulsingOpacity extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return PulseBuilder(
      builder: (context, value, child) {
        final faded = Opacity(opacity: 0.45 + 0.55 * value, child: child);
        final minScale = this.minScale;
        if (minScale == null) return faded;
        return Transform.scale(
          scale: minScale + (1 - minScale) * value,
          child: faded,
        );
      },
      child: child,
    );
  }
}
