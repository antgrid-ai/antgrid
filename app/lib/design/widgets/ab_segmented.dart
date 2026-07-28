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
  final String label;

  /// Optional leading Iconify SVG (see `AbIcons`). Garnish for faster
  /// recognition — the label is always rendered, never icon-only.
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
  });

  final List<AbSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelect;

  /// Tap on a disabled cell. Defaults to surfacing [AbSegment.disabledReason]
  /// as a snack bar — hover can't be relied on for the reason (touch
  /// platforms, clicks before the tooltip dwell). Provide this to override.
  final ValueChanged<AbSegment<T>>? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
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
  });

  final AbSegment<T> segment;
  final bool selected;
  final ValueChanged<T> onSelect;
  final ValueChanged<AbSegment<T>>? onDisabledTap;

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
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      color: widget.selected ? p.accent.withAlpha(40) : null,
      alignment: Alignment.center,
      child: Row(
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

    if (!s.enabled && s.disabledReason != null) {
      cell = AbTooltip(message: s.disabledReason!, child: cell);
    }

    return Semantics(
      button: true,
      enabled: s.enabled,
      selected: widget.selected,
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
