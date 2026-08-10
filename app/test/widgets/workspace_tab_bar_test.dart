import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter_test/flutter_test.dart';

import '../design/test_harness.dart';

void main() {
  // Bare GestureDetectors announce as nothing, so a screen reader had no way to
  // tell a tab from the panel behind it, let alone say which one was open.
  testWidgets('each tab announces as a button and says which is open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAntgrid(
      tester,
      WorkspaceTabBar(selected: WorkspaceView.handler, onSelected: (_) {}),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Handler')),
      matchesSemantics(
        label: 'Handler',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Git')),
      matchesSemantics(
        label: 'Git',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  // The count is drawn as a bare number after the tab name — read on its own it
  // is a stray digit, not this tab's backlog.
  testWidgets('a badge is folded into the tab it belongs to', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAntgrid(
      tester,
      WorkspaceTabBar(
        selected: WorkspaceView.terminals,
        onSelected: (_) {},
        badges: const {WorkspaceView.handler: 2},
      ),
    );

    expect(find.bySemanticsLabel('Handler, 2'), findsOneWidget);
    expect(find.bySemanticsLabel('2'), findsNothing);
    handle.dispose();
  });

  // The excluded subtree still has to carry the tap through, or the button is
  // one assistive tech can see and cannot press.
  testWidgets('activating a tab from the semantics tree selects it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    WorkspaceView? picked;
    await pumpAntgrid(
      tester,
      WorkspaceTabBar(
        selected: WorkspaceView.terminals,
        onSelected: (v) => picked = v,
      ),
    );

    await tester.tap(find.bySemanticsLabel('Files'));
    expect(picked, WorkspaceView.files);
    handle.dispose();
  });
}
