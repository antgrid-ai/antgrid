import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// `GhosttyTerminalView`'s default `lineHeight`. The wrapper does not override
/// it, so the view measures at this value and so must we.
const double kGhosttyLineHeight = 1.35;

/// The cell `GhosttyTerminalView` will measure for these inputs: the glyph
/// advance and the line box, both snapped to whole physical pixels the way the
/// view snaps them.
///
/// Exists so a view's authoritative grid width can be sized on the frame it
/// mounts. The view reports its own metrics through `onCellMetricsChanged`,
/// which it dispatches from a post-frame callback — so a listener learns them
/// one frame LATE, and on every remount (a session switch re-keys the wrapper)
/// that first frame has no metrics at all. Laying the grid out at a
/// locally-derived width for that one frame and then correcting it is a real
/// grid resize under the guest, and `ghostty_vte_flutter` does not reflow: an
/// Ink-style TUI leaks stale fragments across it.
///
/// HAND-MIRRORED against the pinned fork (`ghostty_vte_flutter`, ref
/// `c262d5f2002d26b2116b2c5c943a46a63f994133`):
/// `_GhosttyTerminalViewState._measureMetrics` and
/// `_snapLogicalExtentToPhysical` in `lib/src/terminal_view.dart`. The package
/// defaults the wrapper does not override are folded in — `cellWidthScale = 1`,
/// `letterSpacing = 0`, `fontPackage = null` — as is the 'W' probe glyph. There
/// is deliberately NO `textScaler`: the package passes none, because the
/// callsite pre-scales `fontSize` itself.
///
/// A `ref:` bump in `app/pubspec.yaml` MUST be followed by
/// `cd app && flutter test`, which runs
/// `test/widgets/terminal_cell_metrics_contract_test.dart` — the only thing
/// that catches a drift. `onCellMetricsChanged` still corrects a disagreement
/// one frame later, so a drift degrades to the old two-transition behaviour
/// rather than to a permanently wrong grid, which is exactly why it is silent.
({double charWidth, double linePixels}) measureTerminalCell({
  required String fontFamily,
  required List<String> fontFamilyFallback,
  required double fontSize,
  required FontWeight fontWeight,
  required double devicePixelRatio,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'W',
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
        height: kGhosttyLineHeight,
        letterSpacing: 0,
        fontWeight: fontWeight,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  // `layout()` allocates an engine-side ui.Paragraph that only a dispose
  // releases promptly — GC reclaims it eventually, but the Skia allocation is
  // invisible to Dart heap accounting, so nothing pressures a collection. In a
  // `finally` because this runs inside `build()`: a throw here (a font the
  // engine cannot resolve) would otherwise leak one paragraph per frame for as
  // long as the widget keeps rebuilding.
  final double width;
  try {
    painter.layout();
    width = painter.width;
  } finally {
    painter.dispose();
  }
  return (
    charWidth: _snapToPhysical(math.max(1.0, width), devicePixelRatio),
    linePixels: _snapToPhysical(
      math.max(1.0, fontSize * kGhosttyLineHeight),
      devicePixelRatio,
    ),
  );
}

/// The extent a grid of [cells] must be laid out at for `GhosttyTerminalView`
/// to recover exactly [cells] from it, given the padding it will subtract.
///
/// The view derives its grid with `floor((extent - padding) / metric)`, and
/// `cells * metric` does not survive that round trip: the quotient lands a hair
/// under `cells` for roughly 3% of the dpr/font-size pairs this app can produce
/// (dpr 1.5 at 10.7pt, dpr 2.625 at 10.1pt, ...), which costs a row or a column
/// and leaves a viewer's engine a cell short of the driver it is mirroring —
/// exactly the mismatch pinning the authoritative geometry exists to remove.
/// The nudge is orders of magnitude below the one-logical-pixel floor
/// [measureTerminalCell] clamps both metrics to, so it can never buy an extra
/// cell.
double gridExtentFor({
  required int cells,
  required double metric,
  required double padding,
}) => cells * metric + padding + 0.01;

double _snapToPhysical(double value, double devicePixelRatio) {
  if (devicePixelRatio <= 0) return value;
  return math.max(
    1 / devicePixelRatio,
    (value * devicePixelRatio).roundToDouble() / devicePixelRatio,
  );
}
