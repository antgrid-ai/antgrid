import 'package:flutter/widgets.dart';

import '../ab_colors.dart';

/// Visual weight of a [AbSeparator].
enum AbSeparatorWeight {
  /// Low-emphasis divider for in-content separation — list rows, grouped
  /// items. Reads `borderSubtle`.
  subtle,

  /// Structural divider for chrome and zone boundaries — panel edges,
  /// toolbars, the drawer/agent/context splits. Reads `borderDefault`.
  strong,
}

/// A 1px hairline separator that reads the active Antgrid palette.
///
/// Prefer this over Material's [Divider]/[VerticalDivider] — which paint with
/// the Material `dividerColor` and bypass the Antgrid theme — and over hand-rolled
/// `Container(width: 1, color: ...)` lines, so every standalone separator stays
/// on the same two-tier token scale.
///
/// For a separator that is part of a surface's own decoration (a panel edge,
/// a toolbar's bottom rule), keep using
/// `Border(... BorderSide(color: context.antgrid.border*))` — this widget is only
/// for standalone lines drawn between sibling widgets.
class AbSeparator extends StatelessWidget {
  /// A horizontal rule, 1px tall. Fills the available width of its parent
  /// (a [Column] cross-axis, a [ListView] separator slot, etc.).
  const AbSeparator.horizontal({
    super.key,
    this.weight = AbSeparatorWeight.subtle,
  }) : _axis = Axis.horizontal;

  /// A vertical rule, 1px wide. The parent must impose a bounded height
  /// (e.g. a [Row] inside a sized toolbar), exactly as Material's
  /// [VerticalDivider] requires.
  const AbSeparator.vertical({
    super.key,
    this.weight = AbSeparatorWeight.subtle,
  }) : _axis = Axis.vertical;

  final AbSeparatorWeight weight;
  final Axis _axis;

  @override
  Widget build(BuildContext context) {
    final color = weight == AbSeparatorWeight.subtle
        ? context.antgrid.borderSubtle
        : context.antgrid.borderDefault;
    return _axis == Axis.horizontal
        ? Container(height: 1, color: color)
        : Container(width: 1, color: color);
  }
}
