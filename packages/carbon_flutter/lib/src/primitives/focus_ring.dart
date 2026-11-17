import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';

/// Carbon's keyboard focus indicator: a 2px `focus` outline drawn inside the
/// child's bounds.
///
/// Painted over the child as a foreground layer, so showing or hiding it never
/// changes layout. Drive [visible] from
/// `CarbonInteractionState.focusVisible` rather than plain focus, so mouse
/// clicks do not leave a keyboard ring behind.
class CarbonFocusRing extends StatelessWidget {
  const CarbonFocusRing({
    super.key,
    required this.visible,
    this.onColor = false,
    this.borderRadius,
    required this.child,
  });

  final bool visible;

  /// Adds Carbon's 1px `focusInset` ring inside the outline, which keeps the
  /// indicator visible on filled controls whose fill is close to `focus`
  /// (primary buttons, selected switcher items).
  final bool onColor;

  /// For the few rounded Carbon shapes (pill tags, the toggle track).
  final BorderRadius? borderRadius;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return CustomPaint(
      foregroundPainter: visible
          ? _FocusRingPainter(
              color: colors.focus,
              insetColor: onColor ? colors.focusInset : null,
              borderRadius: borderRadius,
            )
          : null,
      child: child,
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter({
    required this.color,
    required this.insetColor,
    required this.borderRadius,
  });

  final Color color;
  final Color? insetColor;
  final BorderRadius? borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    const width = CarbonBorders.focus;
    final bounds = Offset.zero & size;
    // Strokes are centred on the path, so inset by half the width to keep the
    // whole outline inside the child.
    _stroke(canvas, bounds.deflate(width / 2), color, width);
    final inset = insetColor;
    if (inset != null) {
      _stroke(
        canvas,
        bounds.deflate(width + CarbonBorders.hairline / 2),
        inset,
        CarbonBorders.hairline,
      );
    }
  }

  void _stroke(Canvas canvas, Rect rect, Color color, double width) {
    if (rect.width <= 0 || rect.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final radius = borderRadius;
    if (radius == null) {
      canvas.drawRect(rect, paint);
    } else {
      canvas.drawRRect(radius.toRRect(rect), paint);
    }
  }

  @override
  bool shouldRepaint(_FocusRingPainter old) =>
      old.color != color ||
      old.insetColor != insetColor ||
      old.borderRadius != borderRadius;
}
