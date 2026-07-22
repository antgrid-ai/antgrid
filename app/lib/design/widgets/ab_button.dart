import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_focus_ring.dart';

/// Visual emphasis for [AbButton].
enum AbButtonVariant {
  /// Default flat chrome: surface fill, 1px border, secondary text.
  normal,

  /// Filled accent button for the primary action in a view. Accent fill,
  /// accent border, [AbColors.accentForeground] text. Ignores
  /// [AbButton.color].
  primary,
}

/// Flat terminal-style button.
///
/// Pass `onTap: null` to render the button in a disabled state
/// (opacity 0.4, no hover, no focus, basic cursor). See the
/// design system disabled-state contract.
class AbButton extends StatefulWidget {
  const AbButton({
    super.key,
    required this.label,
    this.onTap,
    this.color,
    this.leading,
    this.compact = false,
    this.variant = AbButtonVariant.normal,
    this.fontSize,
    this.fontWeight,
  });

  final String label;
  final VoidCallback? onTap;

  /// Text color override. Ignored when [variant] is
  /// [AbButtonVariant.primary].
  final Color? color;
  final Widget? leading;
  final bool compact;
  final AbButtonVariant variant;

  /// Overrides the label font size. Defaults to 10 (compact) / 11 (normal).
  final double? fontSize;

  /// Overrides the label font weight. Defaults to [FontWeight.normal]
  /// (subject to the DPR-gated weight bump in [AbTokens.sansStyle]).
  final FontWeight? fontWeight;

  @override
  State<AbButton> createState() => _AbButtonState();
}

class _AbButtonState extends State<AbButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final isPrimary = widget.variant == AbButtonVariant.primary;
    final textColor = isPrimary
        ? p.accentForeground
        : (widget.color ?? p.textSecondary);
    final fillColor = isPrimary
        ? (_hovered ? p.accentHighlight : p.accent)
        : (_hovered ? p.bgElevated : p.bgSurface);
    final borderColor = isPrimary ? p.accent : p.borderDefault;
    final fontSize = widget.fontSize ?? (widget.compact ? 10.0 : 11.0);
    final hPad = widget.compact ? AbTokens.space8 : AbTokens.space12;
    final vPad = widget.compact ? AbTokens.space2 : AbTokens.space4;
    final interactive = widget.onTap != null;

    Widget visual = Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      decoration: BoxDecoration(
        color: fillColor,
        border: Border.all(color: borderColor),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: AbTokens.space4),
          ],
          Text(
            widget.label,
            style: AbTokens.sansStyle(
              fontSize: fontSize,
              color: textColor,
              fontWeight: widget.fontWeight ?? FontWeight.normal,
            ),
          ),
        ],
      ),
    );

    if (!interactive) {
      return Opacity(opacity: 0.4, child: visual);
    }

    return FocusableActionDetector(
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
          borderRadius: AbTokens.borderRadius5,
          child: visual,
        ),
      ),
    );
  }
}
