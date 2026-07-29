import 'dart:math' as math;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../window/window_capabilities.dart';
import '../../window/window_chrome.dart';
import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Minimize / maximize / close for platforms where we hid the OS controls.
///
/// Renders nothing on macOS (real traffic lights are kept) and on Linux (the
/// native bar is retained), so the caller never needs a platform branch.
///
/// Deliberately not built from `AbIconButton`: these mimic the Windows caption
/// block, which is flush to the window's top-right corner — full bar height,
/// no gaps, no radius, no inset — so the hit target reaches the screen corner
/// and Fitts's-law corner-slamming works the way it does in every other app.
class AbWindowControls extends ConsumerWidget {
  const AbWindowControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!paintsWindowControls) return const SizedBox.shrink();

    final chrome = ref.watch(windowChromeProvider);
    final maximized = ref.watch(windowMaximizedProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Fill the bar, but never overflow it: the bar's 1px bottom border
        // leaves its content one pixel shorter than titleBarHeight, and an
        // unbounded host (a test harness) has no height to fill at all.
        final height = math.min(constraints.maxHeight, titleBarHeight);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CaptionButton(
              glyph: CaptionGlyph.minimize,
              tooltip: 'Minimize',
              onTap: chrome.minimize,
              height: height,
            ),
            _CaptionButton(
              glyph: maximized ? CaptionGlyph.restore : CaptionGlyph.maximize,
              tooltip: maximized ? 'Restore' : 'Maximize',
              onTap: chrome.toggleMaximize,
              height: height,
            ),
            _CaptionButton(
              glyph: CaptionGlyph.close,
              tooltip: 'Close',
              onTap: chrome.close,
              height: height,
              destructive: true,
            ),
          ],
        );
      },
    );
  }
}

/// One caption button: a bare hover/press fill behind a small glyph.
///
/// No focus ring and no tab stop — the OS caption block is not in the tab
/// order either, and Alt+Space (the window menu, also on right-click) is the
/// keyboard route to these actions.
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.tooltip,
    required this.onTap,
    required this.height,
    this.destructive = false,
  });

  final CaptionGlyph glyph;
  final String tooltip;
  final VoidCallback onTap;
  final double height;

  /// Close: the red fill appears on hover only, so an idle bar has no alarm
  /// colour in it.
  final bool destructive;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setHovered(bool v) {
    if (_hovered != v) setState(() => _hovered = v);
  }

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;

    final Color? background;
    if (_pressed) {
      background = widget.destructive
          ? AbTokens.captionClosePressed
          : colors.bgPressed;
    } else if (_hovered) {
      background = widget.destructive
          ? AbTokens.captionCloseHover
          : colors.bgHover;
    } else {
      background = null;
    }

    // Full-contrast, not textSecondary: Windows paints caption glyphs at the
    // same weight as primary text, and a dimmer grey reads as a disabled
    // control beside a real caption block.
    final glyphColor = widget.destructive && (_hovered || _pressed)
        ? AbTokens.captionCloseForeground
        : colors.textPrimary;

    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          // Arrow, not a hand: the OS caption block never switches cursor.
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => _setHovered(true),
          onExit: (_) {
            _setHovered(false);
            _setPressed(false);
          },
          child: GestureDetector(
            // Opaque so a drag that starts here is absorbed rather than
            // falling through to the title bar's drag region beneath.
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapDown: (_) => _setPressed(true),
            onTapCancel: () => _setPressed(false),
            onTap: () {
              _setPressed(false);
              widget.onTap();
            },
            child: SizedBox(
              width: AbTokens.captionButtonWidth,
              height: widget.height,
              child: ColoredBox(
                color: background ?? const Color(0x00000000),
                // The painter spans the whole button and centres the glyph
                // itself. Centering with a widget instead would place the
                // canvas origin on a half pixel whenever the button's height
                // and the glyph box disagree in parity, and every horizontal
                // hairline would smear across two device pixels.
                child: CustomPaint(
                  painter: CaptionGlyphPainter(
                    glyph: widget.glyph,
                    color: glyphColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The four caption glyphs, drawn rather than sourced from the icon set.
///
/// Codicons carry ~30% internal padding and a heavier stroke, which reads as a
/// visibly smaller, blunter glyph beside a real Windows caption block. These
/// are hairline strokes that fill their box edge to edge, matching Segoe's
/// caption glyphs without depending on a system font being installed.
enum CaptionGlyph { minimize, maximize, restore, close }

@visibleForTesting
class CaptionGlyphPainter extends CustomPainter {
  const CaptionGlyphPainter({required this.glyph, required this.color});

  final CaptionGlyph glyph;
  final Color color;

  /// Half-pixel offsets so a 1px stroke lands on a device pixel instead of
  /// straddling two and rendering as a 2px blur.
  static double _crisp(double v) => v.floorToDouble() + 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      // Always 1px, never scaled with the box: Windows caption glyphs are
      // hairlines at every size.
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // The glyph box, centred in the button and snapped so every edge falls on
    // a device-pixel boundary.
    const s = AbTokens.captionButtonGlyph;
    final left = _crisp((size.width - s) / 2);
    final top = _crisp((size.height - s) / 2);
    final right = left + s - 1;
    final bottom = top + s - 1;

    switch (glyph) {
      case CaptionGlyph.minimize:
        final y = _crisp((top + bottom) / 2);
        canvas.drawLine(Offset(left, y), Offset(right, y), paint);
      case CaptionGlyph.maximize:
        canvas.drawRRect(
          RRect.fromLTRBR(left, top, right, bottom, const Radius.circular(1)),
          paint,
        );
      case CaptionGlyph.restore:
        // Front square, then only the edges of the rear one that clear it —
        // drawing the rear square whole would show its hidden edges straight
        // through the front, which has no fill.
        const offset = 2.0;
        canvas.drawRRect(
          RRect.fromLTRBR(
            left,
            top + offset,
            right - offset,
            bottom,
            const Radius.circular(1),
          ),
          paint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(left + offset, top + offset)
            ..lineTo(left + offset, top)
            ..lineTo(right, top)
            ..lineTo(right, bottom - offset)
            ..lineTo(right - offset, bottom - offset),
          paint,
        );
      case CaptionGlyph.close:
        canvas.drawLine(Offset(left, top), Offset(right, bottom), paint);
        canvas.drawLine(Offset(right, top), Offset(left, bottom), paint);
    }
  }

  @override
  bool shouldRepaint(CaptionGlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
