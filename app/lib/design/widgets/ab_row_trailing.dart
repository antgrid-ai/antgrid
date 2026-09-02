import 'package:flutter/widgets.dart';

import '../../utils/platform_utils.dart';
import '../ab_tokens.dart';
import 'ab_cross_fade.dart';
import 'ab_icon_button.dart';

/// One cell of a row's trailing kit, sized to an [AbIconButton]'s own
/// footprint in this context.
///
/// Right-anchoring a box-edge against the gutter is not optical alignment: a
/// 24px button pads a 14px glyph, a status dot is a bare 6px circle, so the two
/// centres land 9px apart. Centring both in a cell of the button's own width
/// puts every outermost glyph in the panel — dot, trash, kebab, refresh — in
/// one column, and keeps it there at any UI Size and on either platform,
/// because the width is [AbIconButton.footprintWidth] rather than a constant.
///
/// The width is a floor, not a cap: a tight box would paint a larger tenant as
/// a squashed circle in an off-centre cell instead of overflowing where it can
/// be seen. Height is left unconstrained — row height is `AbRowContentFloor`'s
/// job.
class AbRowTrailingCell extends StatelessWidget {
  const AbRowTrailingCell({super.key, this.child});

  /// Null lays out a reserved, EMPTY cell: footprint wide, zero high.
  final Widget? child;

  /// Assembles a trailing kit. Nulls are dropped BEFORE layout, so an absent
  /// child costs no gap — a child that decides its own emptiness inside `build`
  /// and returns a zero-width widget is still charged one, so pass `null` and
  /// let the kit drop it. Returns null when nothing survives, so the caller can
  /// pass `trailing: null` and reclaim `AbListRow`'s pre-trailing gap too.
  ///
  /// [ownsColumn] is false for a kit assembled as one ELEMENT of another kit:
  /// the panel-edge column belongs to the outer one, so an inner kit must
  /// neither claim a cell nor be held to the rule that it ends in one.
  static Widget? kit(List<Widget?> cells, {bool ownsColumn = true}) {
    final survivors = <Widget>[for (final cell in cells) ?cell];
    if (survivors.isEmpty) return null;
    assert(
      !ownsColumn ||
          survivors.last is AbRowTrailingCell ||
          survivors.last is AbRowTrailingSwap,
      'AbRowTrailingCell.kit: the outermost element of a trailing kit must be '
      'an AbRowTrailingCell or AbRowTrailingSwap, so every row in the panel '
      'shares one trailing column.',
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < survivors.length; i++) ...[
          if (i > 0) const SizedBox(width: AbTokens.space4),
          survivors[i],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minWidth: AbIconButton.footprintWidth(context)),
    child: Center(widthFactor: 1, heightFactor: 1, child: child),
  );
}

/// A terminal cell with two tenants: a permanent status glyph at rest, an
/// action in its place once [revealed].
///
/// For the one row shape where the status glyph lives at the panel edge
/// permanently — a machine band. Reserving a second cell for the action would
/// push the trash one slot inboard of every other row's, and collapsing the
/// action would slide the dot 28px on pointer-enter. Sharing the cell does
/// neither, and the action is never unmounted, so its in-flight state survives
/// its own modal.
///
/// Touch has no pointer to reveal anything with, so [revealed] is permanently
/// true there and a swap would hide the status glyph forever. Mobile therefore
/// renders both: the resting glyph in a [AbTokens.dotSizeSm] slot inboard, the
/// action in the cell.
class AbRowTrailingSwap extends StatelessWidget {
  const AbRowTrailingSwap({
    super.key,
    required this.revealed,
    required this.action,
    this.resting,
  });

  final bool revealed;
  final Widget action;

  /// Renders `SizedBox.shrink()` for "nothing to report" — the cell reserves
  /// its own width, so an absent glyph moves nothing.
  final Widget? resting;

  /// [AbCrossFade] keeps its child laid out, which is the whole point of the
  /// shared cell — so the faded-out tenant needs the pointer taken off it by
  /// hand, or a 0-opacity trash still takes hits.
  ///
  /// [announce] is what separates the two tenants. An invisible ACTION must
  /// leave the semantics tree, or it is offered to a reader who cannot see it.
  /// A resting STATUS glyph must not: [revealed] is driven by focus as well as
  /// hover, so excluding it would delete the label at the exact moment a
  /// screen-reader user arrives — the only report the row has for anyone who
  /// cannot read the dot's hue. It reports a state, not a control, so it costs
  /// nothing to leave announced under the action that covers it.
  Widget _fade(bool visible, Widget child, {required bool announce}) =>
      AbCrossFade(
        visible: visible,
        duration: AbTokens.motionSnap,
        child: IgnorePointer(
          ignoring: !visible,
          child: ExcludeSemantics(excluding: !announce, child: child),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final resting = this.resting;
    if (isMobilePlatform) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (resting != null) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: AbTokens.dotSizeSm),
              child: resting,
            ),
            const SizedBox(width: AbTokens.space4),
          ],
          AbRowTrailingCell(child: action),
        ],
      );
    }
    return AbRowTrailingCell(
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (resting != null) _fade(!revealed, resting, announce: true),
          _fade(revealed, action, announce: revealed),
        ],
      ),
    );
  }
}
