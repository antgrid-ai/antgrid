import 'package:flutter/widgets.dart';

import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';

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
