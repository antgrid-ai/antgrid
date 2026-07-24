import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/widgets/terminal_quick_actions_bar.dart';

Widget _harness(GhosttyTerminalSoftKeyboardController controller) => MaterialApp(
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
          onUpload: (name, bytes) async => '',
          onInsertPath: (_) {},
          onUploadError: (_) {},
          onSendInput: (_) {},
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
}
