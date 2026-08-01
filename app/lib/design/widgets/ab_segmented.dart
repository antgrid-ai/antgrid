import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';
import 'ab_focus_ring.dart';
import 'ab_icon.dart';
import 'ab_snack_bar.dart';
import 'ab_tooltip.dart';

/// One cell of an [AbSegmented] control.
class AbSegment<T> {
  const AbSegment({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.disabledReason,
    this.key,
  });

  final T value;

  /// Always required, even under [AbSegmented.iconOnly] — there it becomes the
  /// tooltip and the accessible name rather than painted text, so a cell is
  /// never nameless.
  final String label;

  /// Optional leading Iconify SVG (see `AbIcons`). Garnish beside the label;
  /// required, and the only thing drawn, under [AbSegmented.iconOnly].
  final String? icon;

  final bool enabled;

  /// Why this cell is disabled. Surfaces as a tooltip on hover and as a
  /// snack bar when the cell is tapped (see [AbSegmented.onDisabledTap]).
  final String? disabledReason;

  final Key? key;
}

/// Terminal-native segmented control: every option visible side by side in
/// one bordered box, the selected cell accented.
///
/// For small closed sets (2–3) where seeing the alternatives matters — a mode
/// switch is a decision, not a status, so the not-chosen option must be
/// visible without interaction (contrast [AbChip.toggle], which shows only
/// its current state).
///
/// Disabled cells diverge from the AbChip disabled contract on purpose: they
/// keep hit-testing (no 0.4-opacity dead zone) so [AbSegment.disabledReason]
/// stays reachable — tooltip on hover, snack bar on tap (see [onDisabledTap]).
class AbSegmented<T> extends StatelessWidget {
  const AbSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelect,
    this.onDisabledTap,
    this.iconOnly = false,
  });

  final List<AbSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelect;

  /// Drops the labels and paints only [AbSegment.icon], for chrome too tight
  /// to spell both options out (a title bar, a phone toolbar).
  ///
  /// The label is not lost, only unpainted: it becomes the tooltip and the
  /// accessible name. Reach for this only where the glyphs are already common
  /// vocabulary — the box, the divider and the accent fill still say "two
  /// options, one chosen", which is the part a lone icon button cannot say.
  final bool iconOnly;

  /// Tap on a disabled cell. Defaults to surfacing [AbSegment.disabledReason]
  /// as a snack bar — hover can't be relied on for the reason (touch
  /// platforms, clicks before the tooltip dwell). Provide this to override.
  final ValueChanged<AbSegment<T>>? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Not a constructor assert: a const constructor's initializer list can't
    // reach a parameter's fields.
    assert(
      !iconOnly || segments.every((s) => s.icon != null),
      'an icon-only segment has nothing to paint without an icon',
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.borderDefault),
        borderRadius: AbTokens.borderRadius3,
      ),
      // Clip so the selected cell's fill doesn't bleed past the rounded
      // corner; IntrinsicHeight lets the 1px dividers stretch to cell height.
      child: ClipRRect(
        borderRadius: AbTokens.borderRadius3,
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < segments.length; i++) ...[
                if (i > 0) Container(width: 1, color: p.borderDefault),
                _SegmentCell<T>(
                  key: segments[i].key,
                  segment: segments[i],
                  selected: segments[i].value == selected,
                  onSelect: onSelect,
                  onDisabledTap: onDisabledTap,
                  iconOnly: iconOnly,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentCell<T> extends StatefulWidget {
  const _SegmentCell({
    super.key,
    required this.segment,
    required this.selected,
    required this.onSelect,
    required this.onDisabledTap,
    required this.iconOnly,
  });

  final AbSegment<T> segment;
  final bool selected;
  final ValueChanged<T> onSelect;
  final ValueChanged<AbSegment<T>>? onDisabledTap;
  final bool iconOnly;

  @override
  State<_SegmentCell<T>> createState() => _SegmentCellState<T>();
}

class _SegmentCellState<T> extends State<_SegmentCell<T>> {
  bool _hovered = false;
  bool _focused = false;

  void _activate() {
    final s = widget.segment;
    if (!s.enabled) {
      final onDisabledTap = widget.onDisabledTap;
      if (onDisabledTap != null) {
        onDisabledTap(s);
      } else if (s.disabledReason != null) {
        showAbSnackBar(context, s.disabledReason!);
      }
      return;
    }
    if (!widget.selected) widget.onSelect(s.value);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final s = widget.segment;

    final fg = !s.enabled
        ? p.textDisabled
        : widget.selected
        ? p.accent
        : _hovered
        ? p.textSecondary
        : p.textMuted;

    Widget cell = AnimatedContainer(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      padding: EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        // Icon-only cells lose the label's width, so they buy the tap area back
        // in height rather than shipping a 29x18 target to phones.
        vertical: widget.iconOnly ? AbTokens.space6 : AbTokens.space4,
      ),
      color: widget.selected ? p.accent.withAlpha(40) : null,
      alignment: Alignment.center,
      child: widget.iconOnly
          ? AbIcon(s.icon!, size: 13, color: fg)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (s.icon != null) ...[
                  AbIcon(s.icon!, size: 11, color: fg),
                  const SizedBox(width: AbTokens.space6),
                ],
                Text(
                  s.label.toUpperCase(),
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ).copyWith(letterSpacing: 0.8),
                ),
              ],
            ),
    );

    // Why disabled beats what it is: a greyed cell raises the more urgent
    // question. Icon-only cells always carry one, since nothing else names them.
    final tooltip =
        (s.enabled ? null : s.disabledReason) ??
        (widget.iconOnly ? s.label : null);
    if (tooltip != null) cell = AbTooltip(message: tooltip, child: cell);

    return Semantics(
      button: true,
      enabled: s.enabled,
      selected: widget.selected,
      // Only when unpainted — with the label on screen this would double it up.
      label: widget.iconOnly ? s.label : null,
      child: FocusableActionDetector(
        // enabled:false drops the tab stop and keyboard actions but keeps the
        // detector mounted: its didUpdateWidget fires the highlight callbacks
        // false when a cell flips disabled mid-hover/focus, so no stale hover
        // tint or phantom focus ring survives a later re-enable.
        enabled: s.enabled,
        mouseCursor: s.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: GestureDetector(
          // Stays live for disabled cells: _activate then surfaces the
          // disabled reason instead of selecting.
          onTap: _activate,
          behavior: HitTestBehavior.opaque,
          child: AbFocusRing(
            focused: _focused,
            // The cell sits under the control's ClipRRect; the default
            // outset ring would be clipped away entirely.
            inset: true,
            borderRadius: AbTokens.borderRadius3,
            child: cell,
          ),
        ),
      ),
    );
  }
}
