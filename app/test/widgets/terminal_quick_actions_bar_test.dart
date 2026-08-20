import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/widgets/terminal_quick_actions_bar.dart';

Widget _harness(
  GhosttyTerminalSoftKeyboardController controller, {
  VoidCallback? onZoomOut,
  VoidCallback? onZoomIn,
  VoidCallback? onZoomReset,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildAbTheme(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: 412, // typical phone logical width
        child: TerminalQuickActionsBar(
          softKeyboardController: controller,
          onPick: () async => null,
          onPicked: (_) async {},
          uploadBusy: false,
          onUploadError: (_) {},
          onSendInput: (_) {},
          onZoomOut: onZoomOut ?? () {},
          onZoomIn: onZoomIn ?? () {},
          onZoomReset: onZoomReset ?? () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('renders pinned keyboard toggle + scrolling actions', (
    tester,
  ) async {
    final controller = GhosttyTerminalSoftKeyboardController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    // Pinned Keyboard toggle sits before the divider and the upload button.
    // The keyboard control is a chevron+glyph stack (GestureDetector), so the
    // upload button is the only AbIconButton left. No IME is up in the test, so
    // the toggle shows the "raise keyboard" affordance (up-chevron).
    expect(find.byTooltip('Show keyboard'), findsOneWidget);
    expect(find.byType(AbIconButton), findsNWidgets(1));
    // The control-key strip is present (and scrollable past the fixed edge).
    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
  });

  testWidgets('zoom keys step out/in and long-press resets', (tester) async {
    final controller = GhosttyTerminalSoftKeyboardController();
    var out = 0;
    var zin = 0;
    var reset = 0;
    await tester.pumpWidget(
      _harness(
        controller,
        onZoomOut: () => out++,
        onZoomIn: () => zin++,
        onZoomReset: () => reset++,
      ),
    );
    await tester.pumpAndSettle();

    final zoomOut = find.bySemanticsLabel('Decrease terminal text size');
    final zoomIn = find.bySemanticsLabel('Increase terminal text size');
    expect(zoomOut, findsOneWidget);
    expect(zoomIn, findsOneWidget);

    await tester.tap(zoomOut);
    await tester.tap(zoomIn);
    await tester.pump();
    expect(out, 1);
    expect(zin, 1);

    await tester.longPress(zoomIn);
    await tester.pump();
    expect(reset, 1);
    // Long-press must not also fire the step it is layered on.
    expect(zin, 1);
  });
}
