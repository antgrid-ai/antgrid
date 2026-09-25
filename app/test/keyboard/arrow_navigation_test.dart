// Arrow-key navigation once the keyboard is on the app's own UI: the tab strip
// is ONE stop whose ←/→ switch tabs and whose Enter/↓ go into the tab; tree
// rows expand on → and collapse on ←; F6 moves between the sidebar, the agent
// and the panel even while a key-eating widget (the terminal) has focus; and
// Ctrl+1..5 hand the keyboard to the tab they show.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/keyboard/app_shortcut_scope.dart';
import 'package:antgrid/keyboard/focus_regions.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
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
      // Published by the strip for Ctrl+1..5 and F6.
      container.read(workspaceTabsFocusProvider).focus!.call();
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

  group('areas', () {
    late ProviderContainer container;
    late FocusNode sidebarRow;
    late FocusNode agent;
    late FocusNode panelTab;
    final agentKeys = <LogicalKeyboardKey>[];

    /// Sidebar | agent (eats every key, like the terminal) | panel.
    Future<void> pumpAreas(WidgetTester tester) async {
      container = ProviderContainer();
      addTearDown(container.dispose);
      sidebarRow = FocusNode(debugLabel: 'sidebar-row');
      agentKeys.clear();
      agent = FocusNode(
        debugLabel: 'agent',
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent) agentKeys.add(event.logicalKey);
          return KeyEventResult.handled;
        },
      );
      panelTab = FocusNode(debugLabel: 'panel-tab');
      addTearDown(sidebarRow.dispose);
      addTearDown(agent.dispose);
      addTearDown(panelTab.dispose);

      await tester.pumpWidget(
        _app(
          container,
          AppShortcutScope(
            child: Row(
              children: [
                FocusRegionScope(
                  region: FocusRegion.sidebar,
                  child: Focus(
                    focusNode: sidebarRow,
                    child: const SizedBox(width: 100, height: 100),
                  ),
                ),
                Focus(
                  focusNode: agent,
                  child: const SizedBox(width: 100, height: 100),
                ),
                FocusRegionScope(
                  region: FocusRegion.panel,
                  child: Focus(
                    focusNode: panelTab,
                    child: const SizedBox(width: 100, height: 100),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      container.read(focusAgentInputProvider.notifier).set(agent.requestFocus);
      container.read(workspaceTabsFocusProvider).publish(panelTab.requestFocus);
      agent.requestFocus();
      await tester.pumpAndSettle();
    }

    Future<void> shiftF6(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    // F6 is a terminal program's key too (mc's rename, htop's sort), so inside
    // the terminal it stays there; Ctrl+0..5 are the way out.
    _windowsTest('F6 inside the terminal is the terminal program\'s', (
      tester,
    ) async {
      await pumpAreas(tester);

      await _press(tester, LogicalKeyboardKey.f6);
      expect(agent.hasPrimaryFocus, isTrue);
      expect(agentKeys, contains(LogicalKeyboardKey.f6));
    });

    _windowsTest('F6 cycles sidebar → agent → panel from the app\'s own UI', (
      tester,
    ) async {
      await pumpAreas(tester);
      sidebarRow.requestFocus();
      await tester.pumpAndSettle();

      await _press(tester, LogicalKeyboardKey.f6);
      expect(agent.hasPrimaryFocus, isTrue);

      panelTab.requestFocus();
      await tester.pumpAndSettle();
      await _press(tester, LogicalKeyboardKey.f6);
      expect(sidebarRow.hasPrimaryFocus, isTrue);

      panelTab.requestFocus();
      await tester.pumpAndSettle();
      await shiftF6(tester);
      expect(agent.hasPrimaryFocus, isTrue);
    });

    _windowsTest('F6 skips an area that is not on screen', (tester) async {
      await pumpAreas(tester);
      // The context panel hidden: no strip publishes its focus callback.
      container.read(workspaceTabsFocusProvider).retract(panelTab.requestFocus);
      sidebarRow.requestFocus();
      await tester.pumpAndSettle();

      // Backwards from the sidebar is the panel — absent — so the agent.
      await shiftF6(tester);
      expect(agent.hasPrimaryFocus, isTrue);
    });

    _windowsTest('Ctrl+2 shows Files and hands its strip the keyboard', (
      tester,
    ) async {
      await pumpAreas(tester);
      WorkspaceView? revealed;
      container.read(workspaceMenuControlProvider.notifier).set((
        active: null,
        reveal: (v) => revealed = v,
      ));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(revealed, WorkspaceView.files);
      expect(panelTab.hasPrimaryFocus, isTrue);
    });
  });
}
