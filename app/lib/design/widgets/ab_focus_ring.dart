import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';

/// Keyboard-only focus outline used internally by all interactive Antgrid
/// primitives (button, icon button, list row, badge). Renders a crisp
/// 1px [context.antgrid.accent] outline, 2px outset from the child.
///
/// Hidden when the focus highlight strategy is not "traditional" — i.e.
/// mouse/touch interaction suppresses the ring, keyboard reveals it. This
/// is the standard Flutter way to mimic CSS `:focus-visible`.
///
/// Wrap the child's gesture/Focus chain so this widget sits *inside* the
/// FocusableActionDetector/Focus node that owns focus. The primitive
/// supplies the focusNode; this widget just paints based on its state.
class AbFocusRing extends StatelessWidget {
  const AbFocusRing({
    super.key,
    required this.focused,
    required this.child,
    this.borderRadius,
    this.inset = false,
  });

  /// Whether the wrapped element currently has visible keyboard focus.
  /// Callers typically wire this from `FocusableActionDetector.onShowFocusHighlight`.
  final bool focused;

  /// Optional border radius matched to the child's own corners. Null = square.
  final BorderRadius? borderRadius;

  /// Paint the ring just inside the child's bounds instead of 2px outside.
  /// For children under an ancestor clip (e.g. a segmented control's
  /// ClipRRect) where the default outset ring would be clipped away.
  final bool inset;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!focused) return child;
    return CustomPaint(
      foregroundPainter: _FocusRingPainter(
        color: context.antgrid.accent,
        width: AbTokens.focusRingWidth,
        offset: inset ? -AbTokens.focusRingOffset : AbTokens.focusRingOffset,
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  _FocusRingPainter({
    required this.color,
    required this.width,
    required this.offset,
    required this.borderRadius,
  });

  final Color color;
  final double width;
  final double offset;
  final BorderRadius? borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    final rect = Rect.fromLTWH(
      -offset,
      -offset,
      size.width + offset * 2,
      size.height + offset * 2,
    );
    if (borderRadius != null) {
      // Expand corners by offset so the ring traces parallel to the child
      // edge. A negative offset (inset ring) shrinks them instead; clamp at
      // square rather than folding a corner inside out.
      final r = borderRadius!;
      double rad(double corner) {
        final v = corner + offset;
        return v < 0 ? 0 : v;
      }

      final rr = RRect.fromRectAndCorners(
        rect,
        topLeft: Radius.circular(rad(r.topLeft.x)),
        topRight: Radius.circular(rad(r.topRight.x)),
        bottomLeft: Radius.circular(rad(r.bottomLeft.x)),
        bottomRight: Radius.circular(rad(r.bottomRight.x)),
      );
      canvas.drawRRect(rr, paint);
    } else {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_FocusRingPainter old) =>
      old.color != color ||
      old.width != width ||
      old.offset != offset ||
      old.borderRadius != borderRadius;
}
