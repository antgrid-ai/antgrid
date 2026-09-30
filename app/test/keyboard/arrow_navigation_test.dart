// Arrow-key navigation once the keyboard is on the app's own UI: the tab strip
// is ONE stop whose ←/→ switch tabs and whose Enter/↓ go into the tab; tree
// rows expand on → and collapse on ←.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/keyboard/focus_regions.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(body: home),
      ),
    );

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// Windows chords throughout; the platform override is cleared inside the
/// body because the binding asserts it unset before tearDown runs.
void _windowsTest(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// A tab strip over one focusable control, standing in for a tab's content.
class _StripHost extends StatefulWidget {
  const _StripHost({required this.content});
  final FocusNode content;

  @override
  State<_StripHost> createState() => _StripHostState();
}

class _StripHostState extends State<_StripHost> {
  WorkspaceView selected = WorkspaceView.files;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      WorkspaceTabBar(
        selected: selected,
        onSelected: (v) => setState(() => selected = v),
      ),
      Focus(
        focusNode: widget.content,
        child: const SizedBox(width: 200, height: 40),
      ),
    ],
  );
}

void main() {
  group('tab strip', () {
    late ProviderContainer container;
    late FocusNode content;

    Future<void> pumpStrip(WidgetTester tester) async {
      container = ProviderContainer();
      addTearDown(container.dispose);
      content = FocusNode(debugLabel: 'content');
      addTearDown(content.dispose);
      await tester.pumpWidget(_app(container, _StripHost(content: content)));
      await tester.pumpAndSettle();
      FocusManager.instance.rootScope.descendants
          .firstWhere((n) => n.debugLabel == 'workspace-tabs')
          .requestFocus();
      await tester.pumpAndSettle();
    }

    WorkspaceView selected(WidgetTester tester) =>
        tester.state<_StripHostState>(find.byType(_StripHost)).selected;

    _windowsTest('left and right switch tabs, wrapping at the ends', (
      tester,
    ) async {
      await pumpStrip(tester);

      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(selected(tester), WorkspaceView.git);
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(selected(tester), WorkspaceView.preview);
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(selected(tester), WorkspaceView.handler);
    });

    _windowsTest('enter goes into the tab', (tester) async {
      await pumpStrip(tester);
      await _press(tester, LogicalKeyboardKey.enter);
      expect(content.hasPrimaryFocus, isTrue);
    });

    _windowsTest('down goes into the tab, and up comes back to the strip', (
      tester,
    ) async {
      await pumpStrip(tester);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(content.hasPrimaryFocus, isTrue);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(content.hasFocus, isFalse);
      // Still the tab we left — one stop, not the tab above the content.
      expect(selected(tester), WorkspaceView.files);
    });
  });

  group('tree rows', () {
    _windowsTest('right expands, left collapses, otherwise arrows move on', (
      tester,
    ) async {
      var expanded = false;
      final row = FocusNode(debugLabel: 'row');
      final below = FocusNode(debugLabel: 'below');
      addTearDown(row.dispose);
      addTearDown(below.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _app(
          container,
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TreeArrowKeys(
                  expanded: expanded,
                  onToggle: () => setState(() => expanded = !expanded),
                  child: Focus(
                    focusNode: row,
                    child: const SizedBox(width: 100, height: 20),
                  ),
                ),
                Focus(
                  focusNode: below,
                  child: const SizedBox(width: 100, height: 20),
                ),
              ],
            ),
          ),
        ),
      );
      row.requestFocus();
      await tester.pumpAndSettle();

      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(expanded, isTrue);
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(expanded, isFalse);
      // ← on a closed row has nothing to collapse: it is left to navigation.
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(expanded, isFalse);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(below.hasPrimaryFocus, isTrue);
    });

    // A button inside the row (a project's trash) sits a level deeper than the
    // row's own node: ← from it moves back to the row, it does not collapse.
    _windowsTest('arrows on a button inside the row leave the row alone', (
      tester,
    ) async {
      var expanded = true;
      final row = FocusNode(debugLabel: 'row');
      final button = FocusNode(debugLabel: 'button');
      addTearDown(row.dispose);
      addTearDown(button.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _app(
          container,
          StatefulBuilder(
            builder: (context, setState) => TreeArrowKeys(
              expanded: expanded,
              onToggle: () => setState(() => expanded = !expanded),
              child: Focus(
                focusNode: row,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 100, height: 20),
                    Focus(
                      focusNode: button,
                      child: const SizedBox(width: 20, height: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      button.requestFocus();
      await tester.pumpAndSettle();

      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(expanded, isTrue);
    });
  });
}
