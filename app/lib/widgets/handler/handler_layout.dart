import 'package:flutter/widgets.dart';

import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';

/// The Handler surface's single gutter, shared by every row and every
/// hand-rolled block on it.
///
/// Deliberately [AbTokens.space12] — `AbListRow`'s own default — so a canonical
/// row and a container written by hand land on the same left edge. Splitting
/// this between `space12` rows and `space16` containers is what left six
/// different left edges on one scrolling list.
const handlerGutter = AbTokens.space12;

/// Width every row reserves for its leading glyph, whether or not it has one.
const handlerRailWidth = 14.0;

/// Height of the collapsed escalation strip over the terminal, and exactly what
/// the terminal reserves beneath itself while a BLOCKING escalation stands.
///
/// Sized from the chevron it has to hold, so the one control that escapes the
/// card is never the thing that overflows the strip. Takes a [BuildContext] for
/// that reason and not as ceremony: [AbIconButton] scales its box by the
/// window's text scaler, so a compile-time constant stops matching the strip
/// somewhere around UI Size 1.1 and the strip starts covering the terminal row
/// the reserve exists to keep visible. One call site sizes the strip and one
/// sizes the reserve, and they can only move together.
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
    AbIconButton.boxExtent(context) + AbTokens.space8 * 2;

/// Gutter-to-title distance: the rail plus the leading gap `AbListRow` puts
/// after it. Blocks that must hang off a row title indent by this.
const handlerRailInset = handlerRailWidth + AbTokens.space8;

/// Fixed-width leading slot.
///
/// A null [icon] renders the slot EMPTY rather than rendering nothing, which is
/// the entire point: leading glyphs on this screen are conditional on the data
/// (a safety-floor shield, a decision kind), and letting one row's glyph push
/// its own title is what made two escalations stacked together indent
/// differently.
class HandlerRail extends StatelessWidget {
  const HandlerRail({super.key, this.icon, this.color});

  final String? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return SizedBox(
      width: handlerRailWidth,
      height: handlerRailWidth,
      child: icon == null
          ? null
          : AbIcon(icon, size: handlerRailWidth, color: color),
    );
  }
}
