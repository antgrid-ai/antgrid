// Pins the two things ResizablePane owes its callers: the split it reports,
// and that it reaches that split WITHOUT a LayoutBuilder.
//
// The second is not a style preference. Both panes carry GlobalKeys (see
// `workspace_shell.dart`), so restoring the context panel reparents a live
// subtree in here. A LayoutBuilder inflates its child during layout, and an
// OverlayPortal reactivated there re-attaches its overlay child to the root
// Overlay — a mid-layout mutation of the theater, which throws
// "_RenderLayoutBuilder was mutated in performLayout" and replaces the whole
// pane with an ErrorWidget. On screen that is a blank, unusable workspace, and
// the agent bar's WorkspaceMenuButton is open in exactly the state you restore
// the panel from. See `workspace_panel_reparent_test.dart` for the reparent
// itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/resizable_pane.dart';

const _leftKey = ValueKey('left');
const _rightKey = ValueKey('right');

/// 4px handle + 600px to divide, so a ratio lands on a whole number of pixels.
const _paneWidth = 604.0;
const _available = 600.0;

Future<void> pumpPane(WidgetTester tester, {required double ratio}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _paneWidth,
            height: 400,
            child: ResizablePane(
              initialRatio: ratio,
              left: const SizedBox.expand(key: _leftKey),
              right: const SizedBox.expand(key: _rightKey),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('splits the available width by the ratio', (tester) async {
    await pumpPane(tester, ratio: 0.5);
    expect(tester.getSize(find.byKey(_leftKey)).width, _available * 0.5);
    expect(tester.getSize(find.byKey(_rightKey)).width, _available * 0.5);
  });

  testWidgets('an off-centre ratio splits the same way', (tester) async {
    await pumpPane(tester, ratio: 0.3);
    expect(tester.getSize(find.byKey(_leftKey)).width, _available * 0.3);
    expect(tester.getSize(find.byKey(_rightKey)).width, _available * 0.7);
  });

  testWidgets('dragging the handle moves the split', (tester) async {
    await pumpPane(tester, ratio: 0.5);
    // The handle is the 4px strip the two panes meet at — private, so it is
    // addressed by position. This also covers the drag math, which now reads
    // the pane width off the RenderBox rather than a builder's constraints.
    await tester.dragFrom(
      const Offset(_available * 0.5 + 2, 200),
      const Offset(60, 0),
    );
    // Long enough to retire the handle's double-tap timer.
    await tester.pump(const Duration(milliseconds: 400));
    // The recognizer eats kDragSlopDefault before it reports anything, and the
    // split can involve floating-point rounding, hence closeTo.
    expect(
      tester.getSize(find.byKey(_leftKey)).width,
      closeTo(_available * 0.5 + 60 - kDragSlopDefault, 0.1),
    );
  });

  for (final ratio in [0.2, 0.8]) {
    testWidgets('honors both pixel floors on first layout at ratio $ratio', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ResizablePane(
            initialRatio: ratio,
            minLeftWidth: 420,
            minRightWidth: 320,
            left: const SizedBox.expand(key: _leftKey),
            right: const SizedBox.expand(key: _rightKey),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(_leftKey)).width,
        greaterThanOrEqualTo(420 - 1e-9),
      );
      expect(
        tester.getSize(find.byKey(_rightKey)).width,
        greaterThanOrEqualTo(320 - 1e-9),
      );
    });
  }

  testWidgets('resizing honors floors without rebuilding the pane', (
    tester,
  ) async {
    final width = ValueNotifier(1200.0);
    addTearDown(width.dispose);
    await tester.binding.setSurfaceSize(const Size(1400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (context, width, child) =>
                SizedBox(width: width, height: 400, child: child),
            child: const ResizablePane(
              minLeftWidth: 420,
              minRightWidth: 320,
              left: SizedBox.expand(key: _leftKey),
              right: SizedBox.expand(key: _rightKey),
            ),
          ),
        ),
      ),
    );
    width.value = 800;
    await tester.pump();
    expect(tester.getSize(find.byKey(_leftKey)).width, closeTo(420, 1e-9));
    expect(tester.getSize(find.byKey(_rightKey)).width, closeTo(376, 1e-9));
    width.value = 1200;
    await tester.pump();
    expect(tester.getSize(find.byKey(_leftKey)).width, 598);
  });

  // The invariant in this file's header: no layout-time inflation of the panes.
  testWidgets('builds the panes without a LayoutBuilder', (tester) async {
    await pumpPane(tester, ratio: 0.5);
    expect(
      find.descendant(
        of: find.byType(ResizablePane),
        matching: find.byType(LayoutBuilder),
      ),
      findsNothing,
    );
  });
}
