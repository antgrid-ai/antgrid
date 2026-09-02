import 'dart:math' as math;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';

import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_focus_ring.dart';
import 'ab_icon.dart';
import 'ab_tap_target.dart';

/// Tone variants — replace the deprecated `size` param.
enum AbIconButtonTone { normal, muted, accent, danger, success }

/// Minimal icon button using Iconify (SVG-rendered).
///
/// Visual box defaults to [AbTokens.iconButtonBox] (24px) and glyph to
/// [AbTokens.iconButtonGlyph] (14px) — the canonical chrome sizing. Both are
/// multiplied by the ambient text scaler (UI Size on desktop, UI Size composed
/// with the OS font scale on mobile) so icons track the type around them. Use
/// [tone] for color variation. [boxSize]/[glyphSize] override the defaults
/// ONLY for touch affordances that need a larger hit target and glyph (e.g.
/// the mobile terminal quick-actions bar); keep chrome on the defaults. The
/// overrides scale too — they are base sizes, not final pixel values.
///
/// On mobile the hit area is inflated to [AbTokens.tapTargetMin] via
/// [AbTapTarget] while the visual box keeps its own size; desktop is
/// untouched. Inside [AbCompactTapTargets] only the width is inflated — the
/// host row owns the vertical dimension — so there the scaled box is what
/// sets the target's height.
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
    this.selected = false,
  });

  final String icon;
  final VoidCallback? onTap;
  final AbIconButtonTone tone;

  /// Latches the button ON: filled background and accent glyph, held until
  /// something turns it off. For controls whose effect OUTLIVES the tap — a
  /// popup pinned open, a mode left engaged — where the user otherwise has only
  /// the effect itself to infer the state from, and none to infer it from when
  /// the effect is off screen. Hover, which the pointer takes away with it,
  /// deliberately does not look like this.
  final bool selected;

  /// Overrides [tone] when provided. Prefer [tone] for consistency.
  final Color? color;
  final String? tooltip;

  /// Visual box / hit-target size. Defaults to [AbTokens.iconButtonBox].
  final double? boxSize;

  /// Glyph size. Defaults to [AbTokens.iconButtonGlyph].
  final double? glyphSize;

  /// Edge of this button's visual box in [context].
  ///
  /// The authority on the button's own size, so a row anchoring its height on
  /// a button — or a cell aligning against one — reads the value from the
  /// widget that owns it instead of re-deriving a constant that the text
  /// scaler beats above UI Size 1.0.
  static double boxExtent(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(AbTokens.iconButtonBox);

  /// Width this button occupies in [context], tap inflation included.
  ///
  /// [AbTapTarget] raises minWidth to [AbTokens.tapTargetMin] on mobile
  /// unconditionally (`compact` gates only minHeight), and that floor does not
  /// scale — so above ~1.84x the box overtakes it and the mobile width changes
  /// character. Both regimes are in the max.
  static double footprintWidth(BuildContext context) => isMobilePlatform
      ? math.max(AbTokens.tapTargetMin, boxExtent(context))
      : boxExtent(context);

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
    final p = context.antgrid;
    final disabled = widget.onTap == null;
    final on = widget.selected && !disabled;
    final baseGlyph = widget.color ?? (on ? p.accent : _toneColor());
    // Disabled dims by tinting the glyph rather than wrapping the button in
    // `Opacity`, which would composite a layer to reach the same pixels. `on` is
    // false whenever disabled, so the box background is already fully
    // transparent here and the glyph is the only thing the dim has to reach.
    final glyphColor = disabled
        ? baseGlyph.withValues(alpha: baseGlyph.a * 0.4)
        : baseGlyph;
    // Selected outranks hover: the pointer resting on an already-lit button
    // must not read as a second, different state.
    final background = on
        ? p.bgSelected
        : (_hovered && !disabled ? p.bgElevated : const Color(0x00000000));

    // Chrome scales with type. Without this the glyph stays 14px and the box
    // 24px next to text the user asked to double, so the icon shrinks
    // relatively and — inside AbCompactTapTargets, where the box IS the
    // target height — the target stops growing with the row. A bounded host
    // (AbToolbar's fixed row height) clamps the box on its own.
    final scaler = MediaQuery.textScalerOf(context);
    final boxSize = scaler.scale(widget.boxSize ?? AbTokens.iconButtonBox);
    final glyphSize = scaler.scale(
      widget.glyphSize ?? AbTokens.iconButtonGlyph,
    );

    final Widget visual = SizedBox.square(
      dimension: boxSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: AbTokens.borderRadius3,
        ),
        child: Center(
          child: AbIcon(widget.icon, size: glyphSize, color: glyphColor),
        ),
      ),
    );

    Widget button;
    if (disabled) {
      // Same AbTapTarget footprint as the enabled state so rows don't shift
      // when a button toggles disabled on mobile.
      button = AbTapTarget(child: visual);
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
        // Focus detector stays OUTSIDE the tap target so keyboard focus spans
        // the whole inflated area; the ring stays INSIDE, hugging the 24px
        // visual, so its geometry is identical on desktop and mobile.
        child: AbTapTarget(
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
