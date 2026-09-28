import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_focus_ring.dart';

/// A tag chip whose colour is a leading dot, never the fill.
///
/// Label colours come from GitHub, where they are chosen against a near-white
/// surface; both Antgrid themes are dark, so using one as a background is how a
/// `#ffffff` label becomes a white block and a `#000000` label disappears. The
/// chip surface stays neutral, the text takes the normal foreground token, and
/// the hue survives as a dot.
///
/// The dot carries a hairline ring for the same reason: an unringed near-black
/// dot vanishes into the panel, and those are common in the wild.
///
/// [AbChip.label] cannot do this — it applies its `color` to the text, which is
/// the rule this widget exists to break with.
class AbLabelChip extends StatefulWidget {
  const AbLabelChip({
    super.key,
    required this.label,
    this.colorHex,
    this.onTap,
    this.selected = false,
    this.trailing,
  });

  final String label;

  /// Six hex digits, with or without a leading `#`. Anything else falls back to
  /// a muted dot rather than dropping the chip.
  final String? colorHex;

  final VoidCallback? onTap;

  /// Renders as an active filter term. Distinct from hover — a selected chip is
  /// a query the user is inside.
  final bool selected;

  /// Sits after the label, inside the chip. For a remove affordance in an
  /// editor; leave null in a read-only row.
  final Widget? trailing;

  @override
  State<AbLabelChip> createState() => _AbLabelChipState();
}

class _AbLabelChipState extends State<AbLabelChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final dot = abLabelColor(widget.colorHex) ?? palette.textMuted;
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space6,
        vertical: AbTokens.space2,
      ),
      decoration: BoxDecoration(
        color: widget.selected ? palette.bgSelected : palette.bgElevated,
        border: Border.all(
          color: widget.selected ? palette.accent : palette.borderDefault,
        ),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: AbTokens.dotSizeSm,
            height: AbTokens.dotSizeSm,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dot,
              border: Border.all(color: palette.borderStrong),
            ),
          ),
          const SizedBox(width: AbTokens.space4),
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                fontWeight: FontWeight.w500,
                color: palette.textSecondary,
                height: 1.0,
              ),
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: AbTokens.space4),
            widget.trailing!,
          ],
        ],
      ),
    );

    if (widget.onTap == null) return chip;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
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
          behavior: HitTestBehavior.opaque,
          child: AbFocusRing(
            focused: _focused,
            borderRadius: AbTokens.borderRadius3,
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// Parses a provider label colour (`d73a4a`, `#d73a4a`, or an 8-digit form
/// with alpha). Null when the string is not a colour, so callers fall back to a
/// theme token rather than painting a guess.
Color? abLabelColor(String? hex) {
  if (hex == null) return null;
  final digits = hex.startsWith('#') ? hex.substring(1) : hex;
  if (digits.length != 6 && digits.length != 8) return null;
  final value = int.tryParse(digits, radix: 16);
  if (value == null) return null;
  return Color(digits.length == 6 ? 0xFF000000 | value : value);
}
