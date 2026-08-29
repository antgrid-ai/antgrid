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
  )..layout();
  // `layout()` allocates an engine-side ui.Paragraph that only a dispose
  // releases promptly — GC reclaims it eventually, but the Skia allocation is
  // invisible to Dart heap accounting, so nothing pressures a collection.
  final width = painter.width;
  painter.dispose();
  return (
    charWidth: _snapToPhysical(math.max(1.0, width), devicePixelRatio),
    linePixels: _snapToPhysical(
      math.max(1.0, fontSize * kGhosttyLineHeight),
      devicePixelRatio,
    ),
  );
}

double _snapToPhysical(double value, double devicePixelRatio) {
  if (devicePixelRatio <= 0) return value;
  return math.max(
    1 / devicePixelRatio,
    (value * devicePixelRatio).roundToDouble() / devicePixelRatio,
  );
}
