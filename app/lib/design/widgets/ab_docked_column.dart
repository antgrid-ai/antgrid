import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Panel layout for a scrolling [body] with chrome docked below it, sized so a
/// short window can never overflow it.
///
/// [Column] cannot express this. A vertical flex lays every non-flex child out
/// with UNBOUNDED main-axis constraints, so docked chrome always takes its full
/// natural height while the [Expanded] body is starved to zero; once the fixed
/// children alone out-measure the panel, [RenderFlex] asserts and paints the
/// overflow stripe with no child able to give. Flex factors are not a way out —
/// they divide FREE space, which is already negative by then.
///
/// Every slot here is laid out against an explicit, non-negative budget
/// instead, in yield order:
///
///  1. [body] gives first — it is the scrollable one — down to [minBodyExtent].
///  2. [dock] then takes what is left above [pinned]. It MUST tolerate any
///     height it is handed (wrap it in a scroll view): this is the slot that
///     yields before the pinned rows do, so a [Column] here would just move the
///     overflow one level down.
///  3. [pinned] rows are bottom-anchored and yield last, from the top of the
///     stack down — the LAST entry sits against the bottom edge and is the last
///     thing to lose a pixel. Each must honour an incoming `maxHeight` on its
///     own ([SizedBox], [ConstrainedBox], [Container] with a height all do);
///     a [Column] must not be handed a slot here for the reason above.
///
/// Honouring `maxHeight` sizes the SLOT correctly but says nothing about what
/// is inside it: a squeezed row whose own content no longer fits paints past
/// its box, and if that content is a [Row] nothing reports it — [RenderFlex]
/// only ever reports MAIN-axis overflow. Containing that is the host's job
/// (clip the panel), so `takeException()` is not a test for it.
///
/// [header] keeps its natural height and is never squeezed, because bounding it
/// would only relocate the same overflow inside it — chrome above the list is a
/// stack of incompressible rows. On a panel too short for the header alone the
/// header is what runs past the bottom edge, so clip the panel if that matters;
/// the pinned rows are declared last and therefore paint over it.
///
/// [CustomMultiChildLayout] sizes itself to `constraints.biggest`, so the host
/// must bound this widget's height — the same requirement the [Expanded] this
/// replaces already had. It reports no intrinsic dimensions either (they fall
/// through to [RenderBox]'s zeros), so a parent that shrink-wraps instead of
/// bounding — [IntrinsicHeight], a min-size [Column], a [Wrap] — measures the
/// whole panel at zero and collapses every slot without raising anything.
class AbDockedColumn extends StatelessWidget {
  const AbDockedColumn({
    super.key,
    required this.header,
    required this.body,
    required this.dock,
    required this.pinned,
    this.minBodyExtent = 0,
  }) : assert(minBodyExtent >= 0);

  /// Fixed chrome above [body]. Natural height, never budgeted.
  final Widget header;

  /// The scrollable content. Laid out to a tight height and may reach zero.
  final Widget body;

  /// Chrome docked between [body] and [pinned]. Must shrink to any height.
  final Widget dock;

  /// Bottom-anchored chrome, stacked top-to-bottom in list order and never
  /// scrolled. Last entry = bottom edge = last to yield.
  final List<Widget> pinned;

  /// Height held back from [dock] so the top of [body] stays on screen.
  final double minBodyExtent;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: _AbDockedColumnDelegate(
        pinnedCount: pinned.length,
        minBodyExtent: minBodyExtent,
      ),
      children: [
        LayoutId(id: _AbDockedSlot.header, child: header),
        LayoutId(id: _AbDockedSlot.body, child: body),
        LayoutId(id: _AbDockedSlot.dock, child: dock),
        // Declared last so they paint over an oversized header on a panel too
        // short to hold one.
        for (var i = 0; i < pinned.length; i++)
          LayoutId(id: _PinnedSlot(i), child: pinned[i]),
      ],
    );
  }
}

enum _AbDockedSlot { header, body, dock }

@immutable
class _PinnedSlot {
  const _PinnedSlot(this.index);

  final int index;

  @override
  bool operator ==(Object other) =>
      other is _PinnedSlot && other.index == index;

  @override
  int get hashCode => index;
}

class _AbDockedColumnDelegate extends MultiChildLayoutDelegate {
  _AbDockedColumnDelegate({
    required this.pinnedCount,
    required this.minBodyExtent,
  });

  final int pinnedCount;
  final double minBodyExtent;

  @override
  void performLayout(Size size) {
    final width = BoxConstraints.tightFor(width: size.width);

    final header = layoutChild(_AbDockedSlot.header, width);
    positionChild(_AbDockedSlot.header, Offset.zero);

    // Every budget below is clamped at zero: a negative maxHeight is exactly
    // what a Flex hands its children here, and it is why one asserts.
    var remaining = math.max(0.0, size.height - header.height);
    var bottom = size.height;
    for (var i = pinnedCount - 1; i >= 0; i--) {
      final id = _PinnedSlot(i);
      final row = layoutChild(id, width.copyWith(maxHeight: remaining));
      bottom -= row.height;
      positionChild(id, Offset(0, bottom));
      remaining = math.max(0.0, remaining - row.height);
    }

    final dock = layoutChild(
      _AbDockedSlot.dock,
      width.copyWith(maxHeight: remaining - math.min(minBodyExtent, remaining)),
    );
    positionChild(_AbDockedSlot.dock, Offset(0, bottom - dock.height));

    layoutChild(
      _AbDockedSlot.body,
      BoxConstraints.tightFor(
        width: size.width,
        height: math.max(0.0, remaining - dock.height),
      ),
    );
    positionChild(_AbDockedSlot.body, Offset(0, header.height));
  }

  @override
  bool shouldRelayout(_AbDockedColumnDelegate oldDelegate) =>
      oldDelegate.pinnedCount != pinnedCount ||
      oldDelegate.minBodyExtent != minBodyExtent;
}
