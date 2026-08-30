// `measureTerminalCell` is a hand-mirror of the pinned dart_terminal fork's
// private `_GhosttyTerminalViewState._measureMetrics`. Nothing in the type
// system connects them: a `ref:` bump that changes the view's measurement
// leaves the mirror compiling, and the disagreement shows up only as a terminal
// grid that is one frame wrong on every remount — the exact defect the mirror
// exists to remove. These tests are the whole gate.
//
// They assert AGREEMENT, never absolute metrics, so they hold whatever font the
// test environment actually resolves.
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/widgets/terminal_cell_metrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Mounts a bare view at [fontSize]/[dpr] with exactly the font inputs
  /// `TerminalViewWrapper` passes, and returns the cell it reports.
  Future<({double charWidth, double linePixels})> reportedCell(
    WidgetTester tester,
    double fontSize,
    double dpr,
  ) async {
    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);
    ({double charWidth, double linePixels})? reported;

    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(devicePixelRatio: dpr),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 600,
            height: 400,
            child: GhosttyTerminalView(
              controller: controller,
              fontSize: fontSize,
              fontFamily: AbTokens.fontMono,
              fontFamilyFallback: AbTokens.fontMonoFallbacks,
              fontWeight: AbTokens.bumpedWeight(FontWeight.w400, fontSize),
              onCellMetricsChanged: (charWidth, linePixels) =>
                  reported = (charWidth: charWidth, linePixels: linePixels),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      reported,
      isNotNull,
      reason:
          'the view never reported metrics at fontSize $fontSize / dpr $dpr',
    );
    return reported!;
  }

  const sizes = <double>[10, 13, 14, 18.2, 21];
  const ratios = <double>[1.0, 1.5, 2.0, 2.625];

  for (final size in sizes) {
    for (final dpr in ratios) {
      testWidgets(
        'cell mirror agrees with the view at fontSize $size, dpr $dpr',
        (tester) async {
          final reported = await reportedCell(tester, size, dpr);
          final measured = measureTerminalCell(
            fontFamily: AbTokens.fontMono,
            fontFamilyFallback: AbTokens.fontMonoFallbacks,
            fontSize: size,
            fontWeight: AbTokens.bumpedWeight(FontWeight.w400, size),
            devicePixelRatio: dpr,
          );

          // Exact, not `closeTo`: both sides snap to whole physical pixels, so
          // any difference at all is a real grid-column disagreement.
          expect(reported.charWidth, measured.charWidth);
          expect(reported.linePixels, measured.linePixels);
        },
      );
    }
  }

  testWidgets(
    "the wrapper's _hPad still equals the view's default horizontal padding",
    (tester) async {
      final controller = GhosttyTerminalController();
      addTearDown(controller.dispose);

      // `_hPad` is private, so pin the token it is built from. The non-driver
      // grid is `cols * charWidth + _hPad`; with charWidth now exactly the
      // view's own, a padding drift is the only remaining way for that width to
      // mismatch the driver's `tab.cols`.
      expect(
        GhosttyTerminalView(controller: controller).padding.horizontal,
        AbTokens.space8 * 2,
      );
    },
  );
}
