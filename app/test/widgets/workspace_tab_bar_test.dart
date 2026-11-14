import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../design/test_harness.dart';

/// Every tab on offer: these pin how the strip renders the tabs it is given,
/// not which tabs a session offers (see visible_workspace_views_test.dart).
Future<void> _pump(WidgetTester tester, Widget child) => pumpAntgrid(
  tester,
  ProviderScope(
    overrides: [
      visibleWorkspaceViewsProvider.overrideWithBuild(
        (_, _) => WorkspaceView.values,
      ),
    ],
    child: child,
  ),
);

void main() {
  // A screen reader must hear each view's name and which one is open.
  testWidgets('each tab announces its name and says which is open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      WorkspaceTabBar(selected: WorkspaceView.handler, onSelected: (_) {}),
    );

    expect(
      tester.getSemantics(find.text('Handler')),
      isSemantics(label: 'Handler', isSelected: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.text('Git')),
      isSemantics(label: 'Git', isSelected: false, hasTapAction: true),
    );
    handle.dispose();
  });

  // The count is drawn as a bare number after the tab name — read on its own it
  // is a stray digit, not this tab's backlog.
  testWidgets('a count is folded into the tab it belongs to', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      WorkspaceTabBar(
        selected: WorkspaceView.terminals,
        onSelected: (_) {},
        badges: const {WorkspaceView.handler: 2},
      ),
    );

    expect(find.bySemanticsLabel('Handler, 2'), findsOneWidget);
    expect(find.bySemanticsLabel('2'), findsNothing);
    expect(find.bySemanticsLabel('Git'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a count past 99 is capped', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      WorkspaceTabBar(
        selected: WorkspaceView.terminals,
        onSelected: (_) {},
        badges: const {WorkspaceView.git: 250},
      ),
    );

    expect(find.bySemanticsLabel('Git, 99+'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('activating a tab selects it', (tester) async {
    WorkspaceView? picked;
    await _pump(
      tester,
      WorkspaceTabBar(
        selected: WorkspaceView.terminals,
        onSelected: (v) => picked = v,
      ),
    );

    await tester.tap(find.text('Files'));
    await tester.pump();
    expect(picked, WorkspaceView.files);
  });

  // The pane may have been scrolled or closed since the tab was chosen, so a
  // second press on the open tab still has to reach the shell.
  testWidgets('pressing the open tab again re-publishes it', (tester) async {
    final picked = <WorkspaceView>[];
    await _pump(
      tester,
      WorkspaceTabBar(selected: WorkspaceView.git, onSelected: picked.add),
    );

    await tester.tap(find.text('Git'));
    await tester.pump();
    expect(picked, [WorkspaceView.git]);
  });

  testWidgets('arrow keys move focus only; Enter selects', (tester) async {
    final picked = <WorkspaceView>[];
    await _pump(
      tester,
      WorkspaceTabBar(selected: WorkspaceView.preview, onSelected: picked.add),
    );

    await tester.tap(find.text('Preview'));
    await tester.pump();
    picked.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(picked, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picked, [WorkspaceView.files]);
  });

  group('window controls', () {
    testWidgets('Expand and Hide appear only when offered', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        WorkspaceTabBar(selected: WorkspaceView.git, onSelected: (_) {}),
      );
      expect(find.bySemanticsLabel('Expand'), findsNothing);
      expect(find.bySemanticsLabel('Hide panel'), findsNothing);

      await _pump(
        tester,
        WorkspaceTabBar(
          selected: WorkspaceView.git,
          onSelected: (_) {},
          onToggleExpand: () {},
          onClose: () {},
        ),
      );
      expect(find.bySemanticsLabel('Expand'), findsOneWidget);
      expect(find.bySemanticsLabel('Hide panel'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('an expanded pane offers Restore instead of Expand', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var toggled = 0;
      await _pump(
        tester,
        WorkspaceTabBar(
          selected: WorkspaceView.git,
          onSelected: (_) {},
          isExpanded: true,
          onToggleExpand: () => toggled++,
        ),
      );

      expect(find.bySemanticsLabel('Expand'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Restore'));
      await tester.pump();
      expect(toggled, 1);
      handle.dispose();
    });

    testWidgets('Hide closes the panel', (tester) async {
      var closed = 0;
      await _pump(
        tester,
        WorkspaceTabBar(
          selected: WorkspaceView.git,
          onSelected: (_) {},
          onClose: () => closed++,
        ),
      );

      await tester.tap(find.bySemanticsLabel('Hide panel'));
      await tester.pump();
      expect(closed, 1);
    });
  });

  // The strip holds five tabs in a pane that fits three (the touch tablet's
  // context pane is a quarter of the window), so a selection made from
  // WorkspaceMenuButton's popup can land off the right edge — the body
  // switched while every visible tab stayed unselected.
  group('WorkspaceTabBar overflow', () {
    Future<void> pumpNarrow(WidgetTester tester, WorkspaceView selected) =>
        _pump(
          tester,
          SizedBox(
            width: 256,
            child: WorkspaceTabBar(selected: selected, onSelected: (_) {}),
          ),
        );

    bool tabIsOnScreen(WidgetTester tester, String label) {
      final strip = tester.getRect(find.byType(WorkspaceTabBar));
      final tab = tester.getRect(find.text(label));
      return tab.left >= strip.left && tab.right <= strip.right;
    }

    testWidgets('the selected tab is scrolled into view on the first frame', (
      tester,
    ) async {
      await pumpNarrow(tester, WorkspaceView.handler);
      await tester.pumpAndSettle();

      expect(tabIsOnScreen(tester, 'Handler'), isTrue);
      expect(tabIsOnScreen(tester, 'Preview'), isFalse);
    });

    testWidgets('changing the selection scrolls the new tab into view', (
      tester,
    ) async {
      await pumpNarrow(tester, WorkspaceView.preview);
      await tester.pumpAndSettle();
      expect(tabIsOnScreen(tester, 'Terminals'), isFalse);

      await pumpNarrow(tester, WorkspaceView.terminals);
      await tester.pumpAndSettle();

      expect(tabIsOnScreen(tester, 'Terminals'), isTrue);
    });

    testWidgets('an overflowing strip offers scroll buttons', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpNarrow(tester, WorkspaceView.preview);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Scroll forward'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    // A drag recognizer in the pane would race the tablet's raw-pointer fling
    // dispatcher; the strip moves by its buttons and the wheel instead.
    testWidgets('dragging the strip does not scroll it', (tester) async {
      await pumpNarrow(tester, WorkspaceView.preview);
      await tester.pumpAndSettle();
      final before = tester.getRect(find.text('Preview'));

      await tester.drag(find.text('Preview'), const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(tester.getRect(find.text('Preview')), before);
    });
  });
}
