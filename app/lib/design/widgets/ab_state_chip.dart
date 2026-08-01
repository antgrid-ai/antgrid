import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_focus_ring.dart';
import 'ab_icon.dart';
import 'ab_tooltip.dart';

/// Bordered glyph + label chip that REPORTS a state and opens the surface where
/// that state is changed.
///
/// The label must name what IS, never what tapping does. A header chip whose
/// text is a verb has to be read twice — an on-coloured fill saying one thing
/// and "Disable …" saying the opposite — and a one-tap verb leaves no room to
/// explain what it changes. Say the state here; let the panel own the wording
/// of the change.
///
/// Not a fourth [AbChip] constructor: those are inline text runs sized by their
/// content, while this is chrome. It carries a glyph and a fixed
/// [AbTokens.iconButtonBox] height so it lines up with the `AbIconButton`s
/// beside it in a toolbar.
class AbStateChip extends StatefulWidget {
  const AbStateChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone,
    this.active = false,
    this.tooltip,
  });

  /// Iconify SVG (see `AbIcons`).
  final String icon;

  /// The state, in one or two words ("Remote on").
  final String label;

  /// Receives the chip's own context so callers can anchor a menu or panel to
  /// it via `abMenuAnchorRect`.
  final ValueChanged<BuildContext> onTap;

  /// Accent for the [active] state. Defaults to `textMuted`, which reads as
  /// "off/neutral" — pass a status colour only when the state deserves one.
  final Color? tone;

  /// Tints the fill and border in [tone] and promotes the label to it.
  final bool active;

  final String? tooltip;

  @override
  State<AbStateChip> createState() => _AbStateChipState();
}

class _AbStateChipState extends State<AbStateChip> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final tone = widget.tone ?? p.textMuted;
    final fg = widget.active
        ? tone
        : _hovered
        ? p.textSecondary
        : p.textMuted;

    Widget chip = AnimatedContainer(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      height: AbTokens.iconButtonBox,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
      decoration: BoxDecoration(
        color: widget.active ? tone.withAlpha(26) : null,
        borderRadius: AbTokens.borderRadius3,
        border: Border.all(
          color: widget.active ? tone.withAlpha(90) : p.borderDefault,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbIcon(widget.icon, size: 12, color: fg),
          const SizedBox(width: AbTokens.space6),
          Text(
            widget.label,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              fontWeight: FontWeight.w500,
              color: fg,
              height: 1.0,
            ),
          ),
        ],
      ),
    );

    if (widget.tooltip != null) {
      chip = AbTooltip(message: widget.tooltip!, child: chip);
    }

    return Semantics(
      button: true,
      label: widget.label,
      child: Builder(
        // The chip's own element, so `onTap` can hand callers a context whose
        // render box is this box — what anchoring a panel under it needs.
        builder: (chipContext) => FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) {
            if (_hovered != v) setState(() => _hovered = v);
          },
          onShowFocusHighlight: (v) {
            if (_focused != v) setState(() => _focused = v);
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap(chipContext);
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: () => widget.onTap(chipContext),
            behavior: HitTestBehavior.opaque,
            child: AbFocusRing(
              focused: _focused,
              borderRadius: AbTokens.borderRadius3,
              child: chip,
            ),
          ),
        ),
      ),
    );
  }
}
