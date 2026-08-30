import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/preview_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _tabA = PreviewTab(
  port: 3000,
  scheme: 'http',
  localProxyPort: 3000,
  currentUrl: 'http://localhost:3000',
);
const _tabB = PreviewTab(
  port: 4000,
  scheme: 'http',
  localProxyPort: 4000,
  currentUrl: 'http://localhost:4000',
);
// ProviderScope must wrap the whole [MaterialApp], not just this widget: the
// popup is pushed as a sibling ROUTE on the same Navigator, not nested inside
// the button's element subtree, so a ProviderScope scoped only around the
// button (as `pumpAntgrid` would place it) is invisible to that route.
Future<void> _pumpButton(
  WidgetTester tester, {
  required List<PreviewTab> tabs,
  int? activeTabId,
  ValueChanged<int>? onSelected,
  ValueChanged<int>? onClosed,
}) async {
  final state = PreviewState(tabs: tabs, activeTabId: activeTabId);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        previewStateProvider.overrideWith((ref) => Stream.value(state)),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(
          body: Center(
            child: PreviewTabsButton(
              onSelected: onSelected ?? (_) {},
              onClosed: onClosed ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows no count badge with only one tab open', (tester) async {
    await _pumpButton(tester, tabs: const [_tabA], activeTabId: 3000);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('shows a count badge once more than one tab is open', (
    tester,
  ) async {
    await _pumpButton(
      tester,
      tabs: const [_tabA, _tabB],
      activeTabId: 3000,
    );
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('opens a popup listing every open tab, active one selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpButton(tester, tabs: const [_tabA, _tabB], activeTabId: 3000);

    await tester.tap(find.byTooltip('Open tabs'));
    await tester.pumpAndSettle();

    expect(find.text('Port 3000'), findsOneWidget);
    expect(find.text('Port 4000'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('tapping a row selects that tab and closes the popup', (
    tester,
  ) async {
    int? picked;
    await _pumpButton(
      tester,
      tabs: const [_tabA, _tabB],
      activeTabId: 3000,
      onSelected: (port) => picked = port,
    );

    await tester.tap(find.byTooltip('Open tabs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Port 4000'));
    await tester.pumpAndSettle();

    expect(picked, 4000);
    // The popup route is gone — its rows no longer find a match.
    expect(find.text('Port 4000'), findsNothing);
  });

  testWidgets('closing a tab from the popup does not select it', (
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

    await tester.tap(find.byTooltip('Open tabs'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close port 4000'));
    await tester.pump();

    expect(closed, 4000);
    expect(selected, isNull);
  });
}
