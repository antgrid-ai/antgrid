import 'package:flutter/widgets.dart';

import '../ab_status_tone.dart';
import '../ab_tokens.dart';
import 'pulsing_opacity.dart';

enum AbDotSize { sm, md }

enum AbDotStyle { filled, hollow }

/// Canonical colored dot for status/connection indicators.
/// Replaces ad-hoc `Container(width:6, decoration: BoxDecoration(shape: circle))`.
class AbStatusDot extends StatelessWidget {
  const AbStatusDot({
    super.key,
    this.tone = AbStatusTone.neutral,
    this.size = AbDotSize.sm,
    this.style = AbDotStyle.filled,
    this.pulse = false,
  });

  final AbStatusTone tone;
  final AbDotSize size;
  final AbDotStyle style;
  final bool pulse;

  double get _diameter => switch (size) {
    AbDotSize.sm => AbTokens.dotSizeSm,
    AbDotSize.md => AbTokens.dotSizeMd,
  };

  @override
  Widget build(BuildContext context) {
    final color = tone.color(context);
    final dot = Container(
      width: _diameter,
      height: _diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: style == AbDotStyle.filled ? color : null,
        border: style == AbDotStyle.hollow
            ? Border.all(color: color, width: 1)
            : null,
      ),
    );
    // Shrinks as well as dims: the fade alone is only as visible as the tone is
    // bright, so it read as a blink on one preset and as static on another. Size
    // says "alive" at any hue. 0.7 is the floor that still leaves a 6px dot
    // legible at the bottom of the cycle.
    return pulse ? PulsingOpacity(minScale: 0.7, child: dot) : dot;
  }
}
