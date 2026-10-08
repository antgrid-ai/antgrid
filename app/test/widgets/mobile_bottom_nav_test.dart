import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/widgets/mobile_bottom_nav.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter_test/flutter_test.dart';

import '../design/test_harness.dart';

/// Every tab on offer: these pin how the strip renders the tabs it is given,
/// not which tabs a session offers (see visible_workspace_views_test.dart).
Future<void> _pump(WidgetTester tester, Widget child) => pumpAntgrid(
  tester,
  ProviderScope(
    overrides: [
      visibleWorkspaceViewsProvider.overrideWithValue(WorkspaceView.values),
    ],
    child: child,
  ),
);

void main() {
  // Mobile is the surface Handler exists for, and its `NEEDS YOU` pill lives in
  // the agent header — the OTHER swipe page. The shell computed this count for
  // the desktop tab bar and had nowhere to put it here, so an unanswered
  // escalation had nothing standing for it on the page the user was looking at.
  testWidgets('a pending count renders on its tab', (tester) async {
    await _pump(
      tester,
      MobileBottomNav(
        selected: WorkspaceView.terminals,
        onSelected: (_) {},
        badges: const {WorkspaceView.handler: 2},
      ),
    );
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('no badge is drawn for a view with no count', (tester) async {
    await _pump(
      tester,
      MobileBottomNav(selected: WorkspaceView.terminals, onSelected: (_) {}),
    );
    for (final view in WorkspaceView.values) {
      expect(find.text(view.label), findsOneWidget);
    }
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a count past three digits clamps rather than widening', (
    tester,
  ) async {
    await _pump(
      tester,
      MobileBottomNav(
        selected: WorkspaceView.handler,
        onSelected: (_) {},
        badges: const {WorkspaceView.git: 250},
      ),
    );
    expect(find.text('99+'), findsOneWidget);
  });

  // Bare GestureDetectors announce as nothing, so a screen reader had no way to
  // tell a tab from the page behind it, let alone say which one was open.
  testWidgets('each tab announces as a button and says which is open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      MobileBottomNav(selected: WorkspaceView.handler, onSelected: (_) {}),
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
      tester.getSemantics(find.bySemanticsLabel('Files')),
      matchesSemantics(
        label: 'Files',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  // The count is drawn as a bare number floating over the glyph — read on its
  // own it is a stray digit, not this tab's backlog.
  testWidgets('a badge is folded into the tab it belongs to', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      MobileBottomNav(
        selected: WorkspaceView.terminals,
        onSelected: (_) {},
        badges: const {WorkspaceView.handler: 2},
      ),
    );

    expect(find.bySemanticsLabel('Handler, 2'), findsOneWidget);
    expect(find.bySemanticsLabel('2'), findsNothing);
    handle.dispose();
  });
}
