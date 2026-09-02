import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_focus_ring.dart';
import 'ab_icon_button.dart';
import 'ab_tap_target.dart';

enum AbRowDensity { sm, md, lg }

enum AbRowSelection { none, surface, accentBar }

/// Typed row-action descriptor consumed by [AbListRow.actions].
///
/// Constraining row actions to a typed value (rather than `List<Widget>`)
/// prevents per-row visual drift, lets the row decide how to render
/// actions per platform later (hover-revealed icons on desktop,
/// swipe-to-reveal on touch), and keeps a11y/disabled-state consistent
/// across every list in the app.
///
/// Today this renders as a [AbIconButton]; that's an implementation
/// detail. Pass `onTap: null` to render in the disabled state.
class AbRowAction {
  const AbRowAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.tone = AbIconButtonTone.normal,
  });

  final String icon;
  final String tooltip;
  final VoidCallback? onTap;
  final AbIconButtonTone tone;
}

/// Minimum content height for a row that reveals an affordance on hover.
///
/// An [AbIconButton] is the tallest thing in an [AbRowDensity.sm] row, so
/// mounting one on pointer-enter grows the row ~10px and shoves the list below
/// it down. Anchoring the content instead is what lets the affordance be
/// mounted and unmounted freely. An enum, not a `double`: the value is
/// scaler-dependent, so any literal a caller could pass is right at exactly one
/// UI Size.
enum AbRowContentFloor { none, iconButton }

/// Canonical list row: optional leading, title, optional subtitle,
/// optional trailing actions or arbitrary trailing widget.
///
/// [actions] and [trailing] are mutually exclusive; if both are passed,
/// [trailing] is rendered and an assertion fires in debug mode.
///
/// Density controls vertical padding (h12 horizontal always):
///   sm = v6, md = v8, lg = v10.
///
/// Selection styles:
///   - none: ignores [selected]
///   - surface: bgSelected fill when [selected]
///   - accentBar: bgSelected fill + 2px left accent bar when [selected]
///
/// Disabled-state contract:
///   - `enabled: true, onTap: null` -> informational row, full opacity, no interaction.
///   - `enabled: true, onTap: cb`   -> interactive row, full opacity, hover/focus/activation.
///   - `enabled: false`             -> disabled, opacity 0.4, no interaction regardless of onTap.
class AbListRow extends StatefulWidget {
  const AbListRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 1,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.actions,
    this.trailing,
    this.selected = false,
    this.selectionStyle = AbRowSelection.none,
    this.density = AbRowDensity.md,
    this.divider = false,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.margin,
    this.horizontalPadding,
    this.verticalPadding,
    this.enabled = true,
    this.hoverable = false,
    this.leadingGapOverride,
    this.contentFloor = AbRowContentFloor.none,
    this.onFocusChange,
  }) : assert(
         actions == null || trailing == null,
         'AbListRow: pass actions or trailing, not both.',
       ),
       assert(
         selectionStyle != AbRowSelection.accentBar ||
             horizontalPadding == null ||
             horizontalPadding > 0,
         'AbListRow: accentBar overlaps the leading widget at '
         'horizontalPadding: 0. Use AbRowSelection.surface instead.',
       );

  /// Default gap between [leading] and the title block. Public because a caller
  /// that indents content UNDER the title (a sub-list hanging off a header row)
  /// has to reproduce this row's own indent, and re-deriving it from a literal
  /// silently misaligns the moment the row is retuned.
  static const leadingGap = AbTokens.space8;

  /// Overrides [leadingGap] for this row. For a leading that is a dot rather
  /// than a glyph, the default gap is measured against a slot the dot doesn't
  /// fill, so the text reads further away than it looks — see
  /// [AbTokens.drawerSessionLeadingGap].
  final double? leadingGapOverride;

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;

  /// Lines the title may fill before it ellipsizes. One suits a label the user
  /// scans past; raise it where the title is prose they must read to act on the
  /// row at all — a model-authored question clipped at 40 characters is a
  /// decision made without its subject.
  final int titleMaxLines;
  final int subtitleMaxLines;

  /// Where [leading] and [trailing] sit against a content block taller than
  /// they are. Centre suits the single-line default; pass
  /// [CrossAxisAlignment.start] alongside a raised [titleMaxLines] so a leading
  /// glyph stays beside the line it qualifies instead of drifting down to the
  /// middle of the wrapped block.
  final CrossAxisAlignment crossAxisAlignment;
  final List<AbRowAction>? actions;
  final Widget? trailing;
  final bool selected;
  final AbRowSelection selectionStyle;
  final AbRowDensity density;
  final bool divider;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final EdgeInsets? margin;

  /// Overrides the default horizontal content padding (`space12`). Pass
  /// `0` when an ancestor already owns the inset.
  final double? horizontalPadding;

  /// Overrides the vertical content padding (else derived from [density]).
  final double? verticalPadding;
  final bool enabled;

  /// When true and the row is interactive, paints `bgHover` while hovered
  /// (unless [selected]). Opt-in so list flavors stay flat by default.
  final bool hoverable;

  /// Floor under the row's content height.
  final AbRowContentFloor contentFloor;

  /// Reports the focus highlight to the caller. A row that collapses its
  /// hover-revealed actions has to know it can be reached by keyboard as well
  /// as by pointer, or those actions become unreachable without a mouse.
  final ValueChanged<bool>? onFocusChange;

  @override
  State<AbListRow> createState() => _AbListRowState();
}

class _AbListRowState extends State<AbListRow> {
  bool _focused = false;
  bool _hovered = false;

  EdgeInsets get _padding {
    final v =
        widget.verticalPadding ??
        switch (widget.density) {
          AbRowDensity.sm => AbTokens.space6,
          AbRowDensity.md => AbTokens.space8,
          AbRowDensity.lg => AbTokens.space10,
        };
    return EdgeInsets.symmetric(
      horizontal: widget.horizontalPadding ?? AbTokens.space12,
      vertical: v,
    );
  }

  bool get _isSelected =>
      widget.selected && widget.selectionStyle != AbRowSelection.none;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (widget.leading != null) ...[
        widget.leading!,
        // Split so the default keeps its `const` arm: every leading row in the
        // app takes that branch and only a session row overrides, so the
        // common case stays canonicalized instead of re-inflating per build.
        if (widget.leadingGapOverride == null)
          const SizedBox(width: AbListRow.leadingGap)
        else
          SizedBox(width: widget.leadingGapOverride),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            DefaultTextStyle.merge(
              style: AbTokens.sansStyle(height: 1.2),
              overflow: TextOverflow.ellipsis,
              maxLines: widget.titleMaxLines,
              child: widget.title,
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: AbTokens.space2),
              DefaultTextStyle.merge(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: context.antgrid.textMuted,
                  height: 1.2,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: widget.subtitleMaxLines,
                child: widget.subtitle!,
              ),
            ],
          ],
        ),
      ),
      if (widget.trailing != null) ...[
        const SizedBox(width: AbTokens.space8),
        widget.trailing!,
      ] else if (widget.actions != null && widget.actions!.isNotEmpty) ...[
        const SizedBox(width: AbTokens.space8),
        for (var i = 0; i < widget.actions!.length; i++) ...[
          if (i > 0) const SizedBox(width: AbTokens.space4),
          AbIconButton(
            icon: widget.actions![i].icon,
            tooltip: widget.actions![i].tooltip,
            tone: widget.actions![i].tone,
            onTap: widget.actions![i].onTap,
          ),
        ],
      ],
    ];

    final rowChild = Row(
      crossAxisAlignment: widget.crossAxisAlignment,
      children: children,
    );

    final showHover = widget.hoverable && _hovered && !_isSelected;
    Widget inner = Container(
      padding: _padding,
      decoration: BoxDecoration(
        color: _isSelected
            ? context.antgrid.bgSelected
            : (showHover ? context.antgrid.bgHover : null),
        borderRadius: (_isSelected || showHover)
            ? AbTokens.borderRadius3
            : null,
        border: widget.divider
            ? Border(bottom: BorderSide(color: context.antgrid.borderSubtle))
            : null,
      ),
      // The row spans the full width and (when interactive) takes taps across
      // its whole height, so it — not its trailing icons — owns the vertical
      // touch dimension. Declared unconditionally so an informational row
      // keeps the same height as its interactive neighbours in the same list.
      child: AbCompactTapTargets(
        child: switch (widget.contentFloor) {
          AbRowContentFloor.none => rowChild,
          AbRowContentFloor.iconButton => ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: AbIconButton.boxExtent(context),
            ),
            child: rowChild,
          ),
        },
      ),
    );

    if (_isSelected && widget.selectionStyle == AbRowSelection.accentBar) {
      inner = Stack(
        children: [
          inner,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(
              // mock spec: 2×14px accent nub anchored to panel left edge
              child: Container(
                width: 2,
                height: 14,
                decoration: BoxDecoration(
                  color: context.antgrid.accent,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget content = widget.margin != null
        ? Container(margin: widget.margin, child: inner)
        : inner;

    if (!widget.enabled) {
      // Disabled: visual only, dimmed, no interaction.
      return Opacity(opacity: 0.4, child: content);
    }

    final interactive =
        widget.onTap != null ||
        widget.onDoubleTap != null ||
        widget.onLongPress != null;
    if (interactive) {
      final focusChild = AbFocusRing(focused: _focused, child: content);
      // With a double-tap handler, drive taps through a
      // [SerialTapGestureRecognizer] so a single tap fires IMMEDIATELY
      // (browser-like: tap, then double-tap on the 2nd click) instead of
      // [GestureDetector] delaying onTap by `kDoubleTapTimeout` to
      // disambiguate. Rows without onDoubleTap keep the plain detector.
      final Widget gestureChild = widget.onDoubleTap != null
          ? RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                SerialTapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      SerialTapGestureRecognizer
                    >(
                      SerialTapGestureRecognizer.new,
                      (r) => r.onSerialTapUp = (d) {
                        if (d.count == 1) {
                          widget.onTap?.call();
                        } else if (d.count == 2) {
                          widget.onDoubleTap?.call();
                        }
                      },
                    ),
                if (widget.onLongPress != null)
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        LongPressGestureRecognizer
                      >(
                        LongPressGestureRecognizer.new,
                        (r) => r.onLongPress = widget.onLongPress,
                      ),
              },
              child: focusChild,
            )
          : GestureDetector(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              behavior: HitTestBehavior.opaque,
              child: focusChild,
            );
      content = FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
          widget.onFocusChange?.call(v);
        },
        // Only tracked when it can be seen: `_hovered` feeds nothing but the
        // `showHover` fill, so on a flat row — which every drawer row is — the
        // setState would rebuild the whole row to identical pixels on each
        // pointer crossing.
        onShowHoverHighlight: widget.hoverable
            ? (v) {
                if (_hovered != v) setState(() => _hovered = v);
              }
            : null,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: gestureChild,
      );
    }

    return content;
  }
}
