import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_focus_ring.dart';
import 'ab_icon.dart';

/// Tone variants — replace the deprecated `size` param.
enum AbIconButtonTone { normal, muted, accent, danger, success }

/// Minimal icon button using Iconify (SVG-rendered).
///
/// Visual box defaults to [AbTokens.iconButtonBox] (24px) and glyph to
/// [AbTokens.iconButtonGlyph] (14px) — the canonical chrome sizing. Use
/// [tone] for color variation. [boxSize]/[glyphSize] override the defaults
/// ONLY for touch affordances that need a larger hit target and glyph (e.g.
/// the mobile terminal quick-actions bar); keep chrome on the defaults.
///
/// Pass `onTap: null` to render the button in a disabled state
/// (opacity 0.4, no hover, no focus, basic cursor). See the
/// design system disabled-state contract.
class AbIconButton extends StatefulWidget {
  const AbIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tone = AbIconButtonTone.normal,
    this.color,
    this.tooltip,
    this.boxSize,
    this.glyphSize,
  });

  final String icon;
  final VoidCallback? onTap;
  final AbIconButtonTone tone;

  /// Overrides [tone] when provided. Prefer [tone] for consistency.
  final Color? color;
  final String? tooltip;

  /// Visual box / hit-target size. Defaults to [AbTokens.iconButtonBox].
  final double? boxSize;

  /// Glyph size. Defaults to [AbTokens.iconButtonGlyph].
  final double? glyphSize;

  @override
  State<AbIconButton> createState() => _AbIconButtonState();
}

class _AbIconButtonState extends State<AbIconButton> {
  bool _hovered = false;
  bool _focused = false;

  Color _toneColor() {
    switch (widget.tone) {
      case AbIconButtonTone.normal:
        return context.antgrid.textSecondary;
      case AbIconButtonTone.muted:
        return context.antgrid.textMuted;
      case AbIconButtonTone.accent:
        return context.antgrid.accent;
      case AbIconButtonTone.danger:
        return context.antgrid.error;
      case AbIconButtonTone.success:
        return context.antgrid.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final glyphColor = widget.color ?? _toneColor();

    final Widget visual = SizedBox.square(
      dimension: widget.boxSize ?? AbTokens.iconButtonBox,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _hovered && !disabled
              ? context.antgrid.bgElevated
              : const Color(0x00000000),
          borderRadius: AbTokens.borderRadius3,
        ),
        child: Center(
          child: AbIcon(
            widget.icon,
            size: widget.glyphSize ?? AbTokens.iconButtonGlyph,
            color: glyphColor,
          ),
        ),
      ),
    );

    Widget button;
    if (disabled) {
      button = Opacity(opacity: 0.4, child: visual);
    } else {
      button = FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        onShowHoverHighlight: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AbFocusRing(
            focused: _focused,
            borderRadius: AbTokens.borderRadius3,
            child: visual,
          ),
        ),
      );
    }

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }

    return button;
  }
}
