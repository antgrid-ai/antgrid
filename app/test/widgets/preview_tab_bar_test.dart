import 'dart:ui' show Tristate;

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/preview_tab_bar.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _tabA = PreviewTab(
  port: 3000,
  scheme: 'http',
  owner: 'p',
  localPort: 3000,
  currentUrl: 'http://localhost:3000',
);
const _tabB = PreviewTab(
  port: 4000,
  scheme: 'http',
  owner: 'p',
  localPort: 4000,
  currentUrl: 'http://localhost:4000/docs',
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
  description: 'CarbonButton "$label"',
);

Future<void> _pumpButton(
  WidgetTester tester, {
  required List<PreviewTab> tabs,
  int? activeTabId,
  ValueChanged<int>? onSelected,
  ValueChanged<int>? onClosed,
  VoidCallback? onOpenPort,
}) async {
  final state = PreviewState(tabs: tabs, activeTabId: activeTabId);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        previewStateProvider.overrideWith((ref) => Stream.value(state)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AbCarbonScope(
            child: Align(
              alignment: Alignment.topRight,
              child: PreviewPortsButton(
                onSelected: onSelected ?? (_) {},
                onClosed: onClosed ?? (_) {},
                onOpenPort: onOpenPort ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(_button('Open ports'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows no badge with no port open', (tester) async {
    await _pumpButton(tester, tabs: const []);
    expect(tester.widget<CarbonButton>(_button('Open ports')).badgeCount, null);
  });

  testWidgets('badge counts the open ports, one included', (tester) async {
    await _pumpButton(tester, tabs: const [_tabA], activeTabId: 3000);
    expect(tester.widget<CarbonButton>(_button('Open ports')).badgeCount, 1);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('badge shows two for two ports', (tester) async {
    await _pumpButton(tester, tabs: const [_tabA, _tabB], activeTabId: 3000);
    expect(tester.widget<CarbonButton>(_button('Open ports')).badgeCount, 2);
  });

  testWidgets('the accessible name carries the count', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpButton(tester, tabs: const [_tabA, _tabB], activeTabId: 3000);
    expect(find.bySemanticsLabel('Open ports, 2'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('opens a list of every open port, active one selected', (
    tester,
  ) async {
    await _pumpButton(tester, tabs: const [_tabA, _tabB], activeTabId: 3000);
    await _open(tester);

    expect(find.text('3000'), findsOneWidget);
    expect(find.text('4000'), findsOneWidget);
    expect(find.text('/docs'), findsOneWidget);
    expect(find.text('Open a port…'), findsOneWidget);
    final rows = tester
        .widgetList<CarbonContainedListRow>(find.byType(CarbonContainedListRow))
        .where((r) => r.selected == true)
        .toList();
    expect(rows, hasLength(1));
    expect(rows.single.title, 'Port 3000');
  });

  testWidgets('the open button reports expanded state to assistive tech', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpButton(tester, tabs: const [_tabA], activeTabId: 3000);
    await _open(tester);
    final data = tester.getSemantics(find.bySemanticsLabel('Open ports, 1'));
    expect(data.flagsCollection.isExpanded, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('tapping a row selects that port and closes the list', (
    tester,
  ) async {
    int? picked;
    await _pumpButton(
      tester,
      tabs: const [_tabA, _tabB],
      activeTabId: 3000,
      onSelected: (port) => picked = port,
    );
    await _open(tester);
    await tester.tap(find.text('4000'));
    await tester.pumpAndSettle();

    expect(picked, 4000);
    expect(find.text('4000'), findsNothing);
  });

  testWidgets('closing a port from the list does not select it', (
    tester,
  ) async {
    int? closed;
    int? selected;
    await _pumpButton(
      tester,
      tabs: const [_tabA, _tabB],
      activeTabId: 3000,
      onSelected: (port) => selected = port,
      onClosed: (port) => closed = port,
    );
    await _open(tester);
    await tester.tap(_button('Close port 4000'));
    await tester.pump();

    expect(closed, 4000);
    expect(selected, isNull);
  });

  testWidgets('the footer runs the open-a-port flow and closes the list', (
    tester,
  ) async {
    var opened = 0;
    await _pumpButton(
      tester,
      tabs: const [_tabA],
      activeTabId: 3000,
      onOpenPort: () => opened++,
    );
    await _open(tester);
    await tester.tap(find.text('Open a port…'));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.text('Open a port…'), findsNothing);
  });

  testWidgets('Escape closes the list and returns focus to the button', (
    tester,
  ) async {
    await _pumpButton(tester, tabs: const [_tabA, _tabB], activeTabId: 3000);
    await _open(tester);
    expect(find.text('3000'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('3000'), findsNothing);
    final button = tester.widget<CarbonButton>(_button('Open ports'));
    expect(button.focusNode?.hasFocus, isTrue);
  });

  testWidgets('arrow keys move through the rows and the footer', (
    tester,
  ) async {
    await _pumpButton(tester, tabs: const [_tabA, _tabB], activeTabId: 3000);
    await _open(tester);

    final rows = tester
        .widgetList<CarbonContainedListRow>(find.byType(CarbonContainedListRow))
        .toList();
    expect(rows.first.focusNode?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(rows[1].focusNode?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(rows.last.focusNode?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(rows[1].focusNode?.hasPrimaryFocus, isTrue);
  });
}
