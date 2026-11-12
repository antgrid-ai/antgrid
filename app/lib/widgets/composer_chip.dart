import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';

/// Leading glyph size of a [ComposerChip].
const double _chipGlyphSize = 12;

/// Trailing chevron size — smaller than the leading glyph: it is punctuation,
/// not identity.
const double _chipChevronSize = 10;

/// What a composer chip spends before its label: horizontal padding, the 1px
/// border on each side, and the leading glyph. Also the chip's floor — this
/// much is what a chip stripped down to its glyph still occupies, so a row
/// that reserves it can never squeeze a chip into an overflow.
const double kComposerChipGlyphWidth = AbTokens.space8 * 2 + 2 + _chipGlyphSize;

/// What the trailing chevron costs on top of [kComposerChipGlyphWidth]: the
/// gap that separates it from the label, plus its own glyph.
const double kComposerChipChevronWidth = AbTokens.space6 + _chipChevronSize;

/// Room a label needs before it is worth drawing at all — roughly four mono
/// characters, plus the gap after the leading glyph so this adds straight onto
/// a slot width. Anything less renders as a lone ellipsis, which says less
/// than the glyph it sits beside already does.
const double kComposerChipMinLabelWidth = AbTokens.space6 + 30;

/// Slot width at which a [ComposerChip] still renders `[glyph] label
/// [chevron]`. Narrower slots fall back to the glyph alone.
const double kComposerChipFullMinWidth =
    kComposerChipGlyphWidth +
    kComposerChipChevronWidth +
    kComposerChipMinLabelWidth;

/// Compact bordered chip for a composer's context row: `[icon] label
/// [chevron]`. Mono label — the values it names are identifiers, not UI
/// chrome prose.
///
/// Builder-style [onTap] so the chip's own render box (not some ancestor's)
/// anchors the popup: the callback receives the [BuildContext] positioned
/// just above the chip's content, ready for [abMenuAnchorRect].
class ComposerChip extends StatelessWidget {
  const ComposerChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.secondaryLabel,
    this.attention = false,
    this.enabled = true,
  });

  final String icon;
  final String label;
  final void Function(BuildContext anchorContext) onTap;

  /// A qualifier on the label that sheds FIRST — the chip's identity is the
  /// primary label and must survive it. All-or-nothing rather than ellipsized:
  /// half a model id names nothing, while the judge beside it still does.
  final String? secondaryLabel;

  /// Accent styling for "needs a pick" states (e.g. "Select project…").
  final bool attention;

  /// False freezes the chip: [onTap] is ignored and the frame drops to the
  /// disabled palette.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Builder(
        builder: (ctx) {
          final p = ctx.antgrid;
          final fg = !enabled
              ? p.textDisabled
              : attention
              ? p.accent
              : p.textPrimary;
          final labelStyle = AbTokens.monoStyle(
            fontSize: AbTokens.fontSm,
            color: fg,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              // A chip is handed a slot, it doesn't ask for one: the context
              // row caps machine/project and gives the branch whatever is
              // left, so the slot can land below what the chip would rather
              // draw. Shed the label and the chevron together — a chevron
              // beside an ellipsis is chrome pointing at nothing — and let the
              // glyph stand in, rather than overflowing the row.
              final showLabel =
                  constraints.maxWidth >= kComposerChipFullMinWidth;
              // The secondary is priced against the room the PAIR needs, so it
              // is dropped while the primary still fits rather than pushing the
              // primary into an ellipsis.
              final secondary = secondaryLabel;
              var showSecondary = false;
              if (showLabel && secondary != null) {
                final pair = _measureLabel(
                  context,
                  '$label  $secondary',
                  labelStyle,
                ).width;
                showSecondary =
                    constraints.maxWidth >=
                    kComposerChipGlyphWidth + kComposerChipChevronWidth + pair;
              }
              // Genuinely no room: nothing can be tapped in zero pixels.
              if (constraints.maxWidth <= 0) {
                return const SizedBox.shrink();
              }
              final body = Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space8,
                  vertical: AbTokens.space4,
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: !enabled
                        ? p.borderSubtle
                        : attention
                        ? p.accent
                        : p.borderDefault,
                  ),
                  borderRadius: AbTokens.borderRadius3,
                ),
                child: SizedBox(
                  height: showLabel
                      ? null
                      : _measureLabel(context, label, labelStyle).height,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AbIcon(icon, size: _chipGlyphSize, color: fg),
                      if (showLabel) ...[
                        const SizedBox(width: AbTokens.space6),
                        // Ellipsize rather than overflow: labels are
                        // user/machine supplied (a machine name can carry
                        // a device-uuid suffix), so the chip must survive
                        // a narrow row. Requires callers to give the chip
                        // a bounded width — a flex slot, not a bare Row
                        // child.
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle,
                          ),
                        ),
                        if (showSecondary) ...[
                          const SizedBox(width: AbTokens.space6),
                          Text(
                            secondary!,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle.copyWith(color: p.textMuted),
                          ),
                        ],
                        const SizedBox(width: AbTokens.space6),
                        AbIcon(
                          AbIcons.chevronDown,
                          size: _chipChevronSize,
                          color: enabled ? p.textMuted : p.textDisabled,
                        ),
                      ],
                    ],
                  ),
                ),
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Stays live while disabled so the chip keeps swallowing taps
                // rather than letting them reach the row beneath it.
                onTap: () {
                  if (!enabled) return;
                  onTap(ctx);
                },
                child: _chipInSlot(constraints.maxWidth, body),
              );
            },
          );
        },
      ),
    );
  }
}

/// Binds [body] to the [slotWidth] a chip was handed, scaling it only for a
/// slot narrower than [kComposerChipGlyphWidth].
///
/// Scaling is the last resort, for a slot below even the glyph-only footprint —
/// a bare `SizedBox.shrink` there silently dropped a chip whenever the composer
/// row's cap/floor math left one that narrow, and an unguarded chip sizes itself
/// off its Row's intrinsic content regardless, which is a render overflow rather
/// than a truncation. Above that width the chip has already shed its label to
/// fit, and a [FittedBox] is NOT the same fallback: it lays its child out
/// unbounded, so the label never reaches its ellipsis and the whole chip —
/// border, padding and text together — shrinks, leaving each chip on the row a
/// different height.
Widget _chipInSlot(double slotWidth, Widget body) => ConstrainedBox(
  constraints: BoxConstraints(maxWidth: slotWidth),
  child: slotWidth < kComposerChipGlyphWidth
      ? FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: body,
        )
      : body,
);

/// Size [label] would occupy unwrapped, at the ambient text scale. The width
/// decides whether a constant label is worth drawing; the height is what a
/// label-less chip pins itself to, so shedding the word doesn't also shrink the
/// chip out of line with its neighbours.
Size _measureLabel(BuildContext context, String label, TextStyle style) {
  // Merge the ambient default the way [Text] itself does — the chip's styles
  // leave `height` unset, so measuring the bare style would miss the theme's
  // line-height multiplier and under-report by a few pixels.
  final merged = DefaultTextStyle.of(context).style.merge(style);
  final painter = TextPainter(
    text: TextSpan(text: label, style: merged),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final size = painter.size;
  // A laid-out painter holds native paragraph memory that no GC finalizer
  // reclaims, and this runs inside a LayoutBuilder on every chip that carries a
  // secondary label — so leaking one per layout pass is a leak per frame.
  painter.dispose();
  return size;
}
