import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Which child of a [YieldingPair] gives way first.
enum YieldingSide { leading, trailing }

/// Two children on one line, where the [yielding] one keeps up to [keep] (or
/// [keepFraction] of the line, whichever is less) of its natural width, the
/// other takes what it needs of the rest, and the yielding one then gets
/// whatever is left.
///
/// A [Row] cannot express this: flex divides the free space before anything is
/// measured, so a loose child's unused share is never handed to its sibling,
/// and a fixed cap truncates beside empty space. Measured by layout, not by
/// intrinsics: a `CarbonTag`, like anything that collapses by width, sits
/// behind a [LayoutBuilder], which cannot report an intrinsic width.
class YieldingPair extends MultiChildRenderObjectWidget {
  YieldingPair({
    super.key,
    required Widget leading,
    required Widget trailing,
    required this.yielding,
    required this.keep,
    required this.keepFraction,
  }) : super(children: [leading, trailing]);

  final YieldingSide yielding;
  final double keep;
  final double keepFraction;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderYieldingPair(
    yielding: yielding,
    keep: keep,
    keepFraction: keepFraction,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderYieldingPair)
      ..yielding = yielding
      ..keep = keep
      ..keepFraction = keepFraction
      ..textDirection = Directionality.of(context);
  }
}

class _PairParentData extends ContainerBoxParentData<RenderBox> {}

typedef _PairSlot = ({BoxConstraints constraints, Size size});
typedef _PairLayout = ({_PairSlot leading, _PairSlot trailing, Size size});

class _RenderYieldingPair extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PairParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PairParentData> {
  _RenderYieldingPair({
    required YieldingSide yielding,
    required double keep,
    required double keepFraction,
    required TextDirection textDirection,
  }) : _yielding = yielding,
       _keep = keep,
       _keepFraction = keepFraction,
       _textDirection = textDirection;

  YieldingSide _yielding;
  set yielding(YieldingSide value) {
    if (value == _yielding) return;
    _yielding = value;
    markNeedsLayout();
  }

  double _keep;
  set keep(double value) {
    if (value == _keep) return;
    _keep = value;
    markNeedsLayout();
  }

  double _keepFraction;
  set keepFraction(double value) {
    if (value == _keepFraction) return;
    _keepFraction = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PairParentData) {
      child.parentData = _PairParentData();
    }
  }

  /// The one sizing algorithm, shared by real and dry layout so the two can
  /// never disagree.
  _PairLayout _layoutChildren(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final leading = firstChild!;
    final trailing = childAfter(leading)!;
    final yieldsLeading = _yielding == YieldingSide.leading;
    final (yielder, holder) = yieldsLeading
        ? (leading, trailing)
        : (trailing, leading);
    final width = constraints.maxWidth;
    BoxConstraints upTo(double w) => BoxConstraints(
      maxWidth: math.max(0, w),
      maxHeight: constraints.maxHeight,
    );

    var yielderConstraints = upTo(width);
    var yielderSize = layoutChild(yielder, yielderConstraints);
    final kept = math.min(
      yielderSize.width,
      math.min(_keep, width * _keepFraction),
    );
    var holderConstraints = upTo(width - kept);
    var holderSize = layoutChild(holder, holderConstraints);
    yielderConstraints = upTo(width - holderSize.width);
    yielderSize = layoutChild(yielder, yielderConstraints);
    // An ellipsized yielder can paint narrower than the room it kept, and a
    // holder truncated to make that room is owed the difference.
    if (holderSize.width + yielderSize.width < width) {
      holderConstraints = upTo(width - yielderSize.width);
      holderSize = layoutChild(holder, holderConstraints);
    }

    final yielderSlot = (constraints: yielderConstraints, size: yielderSize);
    final holderSlot = (constraints: holderConstraints, size: holderSize);
    final (leadingSlot, trailingSlot) = yieldsLeading
        ? (yielderSlot, holderSlot)
        : (holderSlot, yielderSlot);
    return (
      leading: leadingSlot,
      trailing: trailingSlot,
      size: constraints.constrain(
        Size(
          leadingSlot.size.width + trailingSlot.size.width,
          math.max(leadingSlot.size.height, trailingSlot.size.height),
        ),
      ),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layoutChildren(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final layout = _layoutChildren(
      constraints,
      ChildLayoutHelper.dryLayoutChild,
    );
    double? highest;
    for (final (child, slot) in [
      (firstChild!, layout.leading),
      (lastChild!, layout.trailing),
    ]) {
      final childBaseline = child.getDryBaseline(slot.constraints, baseline);
      if (childBaseline == null) continue;
      final y =
          childBaseline + (layout.size.height - slot.size.height) / 2;
      highest = highest == null ? y : math.min(highest, y);
    }
    return highest;
  }

  // Both children sit on one line, so widths add and heights take the taller.
  @override
  double computeMinIntrinsicWidth(double height) =>
      firstChild!.getMinIntrinsicWidth(height) +
      lastChild!.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild!.getMaxIntrinsicWidth(height) +
      lastChild!.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => math.max(
    firstChild!.getMinIntrinsicHeight(width),
    lastChild!.getMinIntrinsicHeight(width),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(
    firstChild!.getMaxIntrinsicHeight(width),
    lastChild!.getMaxIntrinsicHeight(width),
  );

  @override
  void performLayout() {
    final leading = firstChild!;
    final trailing = lastChild!;
    size = _layoutChildren(constraints, ChildLayoutHelper.layoutChild).size;
    final ltr = _textDirection == TextDirection.ltr;
    var x = ltr ? 0.0 : size.width;
    for (final child in [leading, trailing]) {
      if (!ltr) x -= child.size.width;
      (child.parentData! as _PairParentData).offset = Offset(
        x,
        (size.height - child.size.height) / 2,
      );
      if (ltr) x += child.size.width;
    }
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
