import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/widgets/terminal_modifier_keys.dart';
import 'package:antgrid/widgets/terminal_quick_actions_bar.dart';

Widget _harness({
  VoidCallback? onZoomOut,
  VoidCallback? onZoomIn,
  VoidCallback? onZoomReset,
  TerminalModifierLatch? latch,
  void Function(String)? onSendInput,
  bool composeOpen = false,
  VoidCallback? onToggleCompose,
  VoidCallback? onDirectInput,
}) {
  final modifiers = latch ?? TerminalModifierLatch();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAbTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 412, // typical phone logical width
          child: TerminalQuickActionsBar(
            onPick: () async => null,
            onPicked: (_) async {},
            uploadBusy: false,
            onUploadError: (_) {},
            onSendInput: onSendInput ?? (_) {},
            onZoomOut: onZoomOut ?? () {},
            onZoomIn: onZoomIn ?? () {},
            onZoomReset: onZoomReset ?? () {},
            modifiers: modifiers,
            onToggleModifier: modifiers.toggle,
            composeOpen: composeOpen,
            onToggleCompose: onToggleCompose ?? () {},
            onDirectInput: onDirectInput ?? () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders pinned keyboard toggle + scrolling actions', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // Closed, the toggle shows the "raise" affordance (up-chevron). The upload
    // button is the only AbIconButton, and there is no separate compose key.
    expect(find.byTooltip('Show keyboard'), findsOneWidget);
    expect(find.byTooltip('Compose multi-line input'), findsNothing);
    expect(find.byType(AbIconButton), findsNWidgets(1));
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);
    expect(find.text('Alt'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);
  });

  // The sticky Ctrl needs a letter to land on, and the prompt box never sends
  // one on its own: interrupt has to stay a single key of its own.
  testWidgets('Ctrl+C is one tap and does not spend an armed modifier', (
    tester,
  ) async {
    final latch = TerminalModifierLatch();
    final sent = <String>[];
    await tester.pumpWidget(
      _harness(latch: latch, onSendInput: (d) => sent.add(latch.apply(d))),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Ctrl+C'));
    await tester.tap(find.text('Ctrl+C'));
    await tester.pump();
    expect(sent, ['\x03']);
    expect(latch.value.isEmpty, isTrue);
  });

  // A tap and a long press on the one pinned key are two different
  // instruments: the box, or the raw keyboard on the terminal.
  testWidgets('long-pressing the keyboard key asks for direct input, a tap '
      'does not', (tester) async {
    var toggles = 0;
    var direct = 0;
    await tester.pumpWidget(
      _harness(
        onToggleCompose: () => toggles++,
        onDirectInput: () => direct++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byTooltip('Show keyboard'));
    await tester.pumpAndSettle();
    expect(direct, 1);
    expect(toggles, 0);

    await tester.tap(find.byTooltip('Show keyboard'));
    await tester.pumpAndSettle();
    expect(direct, 1);
    expect(toggles, 1);
  });

  testWidgets('the keyboard key toggles the prompt box and follows its state', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(_harness(onToggleCompose: () => toggles++));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Show keyboard'));
    expect(toggles, 1);

    await tester.pumpWidget(
      _harness(composeOpen: true, onToggleCompose: () => toggles++),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide keyboard'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide keyboard'));
    expect(toggles, 2);
  });

  testWidgets('an armed modifier applies to the next bar key, then releases', (
    tester,
  ) async {
    final latch = TerminalModifierLatch();
    final sent = <String>[];
    await tester.pumpWidget(
      _harness(latch: latch, onSendInput: (d) => sent.add(latch.apply(d))),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Shift'));
    await tester.tap(find.text('Shift'));
    await tester.pump();
    expect(latch.value.shift, isTrue);

    await tester.ensureVisible(find.text('Tab'));
    await tester.tap(find.text('Tab'));
    await tester.pump();
    expect(sent, ['\x1b[Z']);
    expect(latch.value.isEmpty, isTrue);
  });

  testWidgets('zoom keys step out/in and long-press resets', (tester) async {
    var out = 0;
    var zin = 0;
    var reset = 0;
    await tester.pumpWidget(
      _harness(
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
