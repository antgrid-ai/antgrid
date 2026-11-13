import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A single line of badges, each at its natural width, that shrinks the widest
/// first when together they exceed [maxWidth].
///
/// A [Row] of [Flexible] badges cannot do this: it divides the space by flex
/// before measuring anything, so a badge that renders nothing still holds an
/// equal share and a lone tag is left too narrow to show its label. Each badge
/// handles its own truncation once it is given less than its natural width.
class CarbonBadgeStrip extends MultiChildRenderObjectWidget {
  const CarbonBadgeStrip({
    super.key,
    required this.maxWidth,
    required super.children,
  });

  final double maxWidth;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBadgeStrip(
    maxWidth: maxWidth,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderObject renderObject,
  ) {
    (renderObject as _RenderBadgeStrip)
      ..maxWidth = maxWidth
      ..textDirection = Directionality.of(context);
  }
}

class _BadgeStripParentData extends ContainerBoxParentData<RenderBox> {}

/// The width every badge is held to so that the badges fit in [limit]: the
/// narrow ones keep their natural width and the rest share what is left.
/// Infinite when they already fit.
double badgeStripCap(List<double> natural, double limit) {
  final sorted = [...natural]..sort();
  var remaining = limit;
  for (var i = 0; i < sorted.length; i++) {
    final share = remaining / (sorted.length - i);
    if (sorted[i] > share) return share;
    remaining -= sorted[i];
  }
  return double.infinity;
}

class _RenderBadgeStrip extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BadgeStripParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BadgeStripParentData> {
  _RenderBadgeStrip({
    required double maxWidth,
    required TextDirection textDirection,
  }) : _maxWidth = maxWidth,
       _textDirection = textDirection;

  double get maxWidth => _maxWidth;
  double _maxWidth;
  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BadgeStripParentData) {
      child.parentData = _BadgeStripParentData();
    }
  }

  /// Lays every child out with [layoutChild] and returns their sizes.
  ///
  /// Measures by layout, not by intrinsics: a badge may hold a [LayoutBuilder]
  /// (CarbonTag does), which cannot report an intrinsic width. Each child is
  /// first given the whole limit, which a min-size badge answers with its
  /// natural width, and only those wider than the cap are laid out again.
  List<Size> _layOut(
    BoxConstraints constraints,
    Size Function(RenderBox child, BoxConstraints constraints) layoutChild,
  ) {
    final limit = math.min(_maxWidth, constraints.maxWidth);
    final children = getChildrenAsList();
    final sizes = [
      for (final c in children)
        layoutChild(
          c,
          BoxConstraints(maxWidth: limit, maxHeight: constraints.maxHeight),
        ),
    ];
    final cap = badgeStripCap([for (final s in sizes) s.width], limit);
    for (var i = 0; i < children.length; i++) {
      if (sizes[i].width > cap) {
        sizes[i] = layoutChild(
          children[i],
          BoxConstraints(maxWidth: cap, maxHeight: constraints.maxHeight),
        );
      }
    }
    return sizes;
  }

  Size _sizeFor(BoxConstraints constraints, List<Size> sizes) =>
      constraints.constrain(
        Size(
          sizes.fold(0.0, (w, s) => w + s.width),
          sizes.fold(0.0, (h, s) => math.max(h, s.height)),
        ),
      );

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => _sizeFor(
    constraints,
    _layOut(constraints, (child, c) => child.getDryLayout(c)),
  );

  @override
  void performLayout() {
    final sizes = _layOut(constraints, (child, c) {
      child.layout(c, parentUsesSize: true);
      return child.size;
    });
    size = _sizeFor(constraints, sizes);
    final ltr = textDirection == TextDirection.ltr;
    var x = ltr ? 0.0 : size.width;
    for (final child in getChildrenAsList()) {
      if (!ltr) x -= child.size.width;
      (child.parentData! as _BadgeStripParentData).offset = Offset(
        x,
        (size.height - child.size.height) / 2,
      );
      if (ltr) x += child.size.width;
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) {
    var sum = 0.0;
    for (final c in getChildrenAsList()) {
      sum += c.getMaxIntrinsicWidth(height);
    }
    return math.min(sum, _maxWidth);
  }

  @override
  double computeMinIntrinsicHeight(double width) => getChildrenAsList().fold(
    0.0,
    (h, c) => math.max(h, c.getMinIntrinsicHeight(double.infinity)),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => getChildrenAsList().fold(
    0.0,
    (h, c) => math.max(h, c.getMaxIntrinsicHeight(double.infinity)),
  );

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
