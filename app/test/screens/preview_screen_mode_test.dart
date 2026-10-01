import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/screens/preview_screen.dart';
import 'package:antgrid/widgets/screen_preview_panel.dart';

void main() {
  /// The two structurally different layouts a desktop panel-mode toggle swaps
  /// between (see `_PanelMode` in workspace_shell.dart). Without a stable
  /// identity Flutter reconciles by position, fails to match, and unmounts the
  /// panel — which for the native preview would mean tearing down a live peer
  /// connection on a layout change.
  /// The split mode nests the panel inside `ResizablePane`'s `LayoutBuilder`.
  Widget splitLayout(Widget child) => Row(
    children: [Expanded(child: LayoutBuilder(builder: (_, _) => child))],
  );

  /// The hidden-sibling mode makes it a direct child instead.
  Widget soleLayout(Widget child) => Row(children: [Expanded(child: child)]);

  Widget app(Widget body) => ProviderScope(
    overrides: [
      previewStateProvider.overrideWith(
        (ref) => Stream.value(const PreviewState()),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: body)),
  );

  testWidgets('web is the default mode and the tunnel preview is untouched', (
    tester,
  ) async {
    await tester.pumpWidget(app(const PreviewScreen()));
    await tester.pump();

    expect(find.text('Open a Preview'), findsOneWidget);
    expect(find.byType(ScreenPreviewPanel), findsNothing);
  });

  testWidgets('the app mode is a peer of the tunnel preview, not a takeover', (
    tester,
  ) async {
    await tester.pumpWidget(app(const PreviewScreen()));
    await tester.pump();

    await tester.tap(find.text('APP'));
    await tester.pump();
    expect(find.byType(ScreenPreviewPanel), findsOneWidget);
    expect(find.text('Open a Preview'), findsNothing);

    await tester.tap(find.text('WEB'));
    await tester.pump();
    expect(find.byType(ScreenPreviewPanel), findsNothing);
    expect(find.text('Open a Preview'), findsOneWidget);
  });

  testWidgets('a keyed reparent between panel layouts keeps the app mode', (
    tester,
  ) async {
    final key = GlobalKey();

    await tester.pumpWidget(app(splitLayout(PreviewScreen(key: key))));
    await tester.pump();
    await tester.tap(find.text('APP'));
    await tester.pump();
    expect(find.byType(ScreenPreviewPanel), findsOneWidget);

    await tester.pumpWidget(app(soleLayout(PreviewScreen(key: key))));
    await tester.pump();

    // The State survived the move, so anything it owns — and anything the
    // session owns beneath it — survived with it.
    expect(find.byType(ScreenPreviewPanel), findsOneWidget);
  });

  testWidgets('without that identity the same move resets the mode', (
    tester,
  ) async {
    await tester.pumpWidget(app(splitLayout(const PreviewScreen())));
    await tester.pump();
    await tester.tap(find.text('APP'));
    await tester.pump();
    expect(find.byType(ScreenPreviewPanel), findsOneWidget);

    await tester.pumpWidget(app(soleLayout(const PreviewScreen())));
    await tester.pump();

    // Proves the assertion above has teeth: position-based reconciliation drops
    // the panel, which is exactly what the GlobalKey in workspace_shell.dart is
    // there to prevent.
    expect(find.byType(ScreenPreviewPanel), findsNothing);
  });
}
