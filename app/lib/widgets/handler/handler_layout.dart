import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../design/ab_carbon.dart';
import '../../design/ab_tokens.dart';

/// The Handler surface's single gutter, shared by every row and every
/// hand-rolled block on it.
///
/// Deliberately [CarbonSpacing.spacing05] — `CarbonContainedListRow`'s own
/// start padding — so a canonical row and a block written by hand land on the
/// same left edge.
const handlerGutter = CarbonSpacing.spacing05;

/// Width every row reserves for its leading glyph, whether or not it has one.
const handlerRailWidth = CarbonSpacing.spacing05;

/// Gutter-to-title distance: the rail plus the gap the row puts after it.
/// Blocks that must hang off a row title indent by this.
const handlerRailInset = handlerRailWidth + CarbonSpacing.spacing04;

/// Vertical padding the collapsed strip puts around its one control.
const handlerEscalationStripPadding = CarbonSpacing.spacing02;

/// Height of the collapsed escalation strip over the terminal, and exactly what
/// the terminal reserves beneath itself while a BLOCKING escalation stands.
///
/// Sized from the target its chevron has to hold, so the one control that
/// escapes the card is never the thing that overflows the strip. Resolved from
/// the platform density rather than from [CarbonTheme] because the caller,
/// `AgentPanel`, sits outside the Carbon scope that the strip itself is
/// painted under; the two read the same `minTarget` formula, so they can only
/// move together.
///
/// The reserve is this and never the EXPANDED card's height: the expanded card
/// floats, because every height change on the terminal child sends a
/// `terminal:resize` up the wire (`_maybeSendResize`, terminal_view_wrapper.dart
/// derives its row count off the incoming constraints), and a PTY reflow per
/// chevron tap is exactly what a floating card exists to avoid. Reserving the
/// strip alone costs one reflow when a card arrives and one when it retires —
/// at the moment the agent is stopped and drawing nothing — and buys back the
/// one line the user collapsed the card in order to read.
///
/// That "stopped" is the reason `AgentPanel` keys the reserve on a blocking row
/// rather than on any escalation: an ask is raised on a pass that has already
/// replied to the agent, so reserving for one would reflow a TUI mid-output.
double handlerEscalationCollapsedHeight(BuildContext context) =>
    CarbonThemeData.forBrightness(
      Brightness.light,
      density: AbCarbonScope.platformDensity,
      touchTarget: AbTokens.tapTargetMin,
    ).minTarget +
    handlerEscalationStripPadding * 2;

/// Fixed-width leading slot.
///
/// A null [icon] renders the slot EMPTY rather than rendering nothing, which is
/// the entire point: leading glyphs on this screen are conditional on the data
/// (a safety-floor shield, a decision kind), and letting one row's glyph push
/// its own title is what made two escalations stacked together indent
/// differently.
class HandlerRail extends StatelessWidget {
  const HandlerRail({super.key, this.icon, this.color});

  final CarbonIcons? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return SizedBox(
      width: handlerRailWidth,
      height: handlerRailWidth,
      child: icon == null
          ? null
          : CarbonIcon(icon, size: handlerRailWidth, color: color),
    );
  }
}

/// The full-bleed band an actionable escalation card sits in: one layer up
/// from the page, ruled top and bottom, and carrying the row gutter so a card
/// and the plain row beneath it share a left edge.
///
/// Its children sit one layer higher still, which is what keeps a control inside
/// the band from vanishing into the band's own fill.
class HandlerBand extends StatelessWidget {
  const HandlerBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    final rule = BorderSide(
      color: theme.borderSubtle(level),
      width: CarbonBorders.hairline,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.layer(level),
        border: Border(top: rule, bottom: rule),
      ),
      child: CarbonLayer(
        level: level < 3 ? level + 1 : level,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: handlerGutter,
            vertical: CarbonSpacing.spacing04,
          ),
          child: child,
        ),
      ),
    );
  }
}
