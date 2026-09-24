// The dispatch contract behind every app shortcut: a global chord reaches its
// handler even while a widget that eats every key (the agent's terminal) has
// focus, but only when something offers the command — an unavailable command's
// chord must still reach that widget — and never from under a dialog.
import 'dart:async';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/keyboard/app_command_registry.dart';
import 'package:antgrid/keyboard/app_shortcut_scope.dart';
import 'package:antgrid/keyboard/app_shortcuts.dart';
import 'package:antgrid/keyboard/shortcuts_sheet.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the terminal: holds focus and consumes every key it is given,
/// recording which ones reached it.
class _KeyEater extends StatelessWidget {
  const _KeyEater({required this.received, this.consumes = true});

  final List<LogicalKeyboardKey> received;
  final bool consumes;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent) received.add(event.logicalKey);
      return consumes ? KeyEventResult.handled : KeyEventResult.ignored;
    },
    child: const SizedBox.expand(),
  );
}

void main() {
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget child) async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
          ),
          home: AppShortcutScope(child: child),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> chord(
    WidgetTester tester,
    List<LogicalKeyboardKey> modifiers,
    LogicalKeyboardKey key,
  ) async {
    for (final m in modifiers) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    for (final m in modifiers.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    await tester.pump();
  }

  const ctrlShift = [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.shiftLeft,
  ];

  void offerSidebar(void Function() toggle) => container
      .read(sidebarControlProvider.notifier)
      .set((hidden: false, toggle: toggle));

  /// Every body runs as Windows: the chord table differs per family, and the
  /// tests' own key presses are written against the Windows one.
  void windowsTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  windowsTest('a global chord runs past a focused widget that eats keys', (
    tester,
  ) async {
    final received = <LogicalKeyboardKey>[];
    await pump(tester, _KeyEater(received: received));
    var toggles = 0;
    offerSidebar(() => toggles++);
    await tester.pump();

    await chord(tester, ctrlShift, LogicalKeyboardKey.keyB);

    expect(toggles, 1);
    expect(received, isNot(contains(LogicalKeyboardKey.keyB)));
  });

  windowsTest('an unavailable command leaves its chord to the focused widget', (
    tester,
  ) async {
    final received = <LogicalKeyboardKey>[];
    await pump(tester, _KeyEater(received: received));
    // No sidebar control published: nothing offers toggleSidebar.

    await chord(tester, ctrlShift, LogicalKeyboardKey.keyB);

    expect(received, contains(LogicalKeyboardKey.keyB));
  });

  windowsTest('a held chord fires once and its repeats never leak', (
    tester,
  ) async {
    final received = <LogicalKeyboardKey>[];
    await pump(tester, _KeyEater(received: received));
    var toggles = 0;
    offerSidebar(() => toggles++);
    await tester.pump();

    for (final m in ctrlShift) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    for (final m in ctrlShift.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    await tester.pump();

    expect(toggles, 1);
    expect(received, isNot(contains(LogicalKeyboardKey.keyB)));
  });

  windowsTest('global chords wait while a dialog is open', (tester) async {
    await pump(tester, const SizedBox.expand());
    var toggles = 0;
    offerSidebar(() => toggles++);
    await tester.pump();

    final context = tester.element(find.byType(SizedBox).first);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const Dialog(child: SizedBox(width: 10, height: 10)),
      ),
    );
    await tester.pumpAndSettle();

    await chord(tester, ctrlShift, LogicalKeyboardKey.keyB);

    expect(toggles, 0);
  });

  group('focused chords', () {
    Future<(List<LogicalKeyboardKey>, int Function())> pumpWithBack(
      WidgetTester tester, {
      required bool consumes,
    }) async {
      final received = <LogicalKeyboardKey>[];
      var backs = 0;
      await pump(
        tester,
        // Registered after the scope's own goBack, so it wins — and keeps the
        // test off the real navigation stack.
        AppCommandHandlers(
          handlers: {AppCommand.goBack: () => backs++},
          child: _KeyEater(received: received, consumes: consumes),
        ),
      );
      return (received, () => backs);
    }

    windowsTest('stay with a focused widget that wants them', (tester) async {
      final (received, backs) = await pumpWithBack(tester, consumes: true);

      await chord(tester, [
        LogicalKeyboardKey.altLeft,
      ], LogicalKeyboardKey.arrowLeft);

      expect(received, contains(LogicalKeyboardKey.arrowLeft));
      expect(backs(), 0);
    });

    windowsTest('reach the app when the focused widget passes', (tester) async {
      final (_, backs) = await pumpWithBack(tester, consumes: false);

      await chord(tester, [
        LogicalKeyboardKey.altLeft,
      ], LogicalKeyboardKey.arrowLeft);

      expect(backs(), 1);
    });
  });

  windowsTest('the latest registration wins, and withdrawing restores', (
    tester,
  ) async {
    await pump(tester, const SizedBox.expand());
    final registry = container.read(appCommandRegistryProvider);
    void outer() {}
    void inner() {}
    final a = registry.register({AppCommand.newTerminal: outer});
    final b = registry.register({AppCommand.newTerminal: inner});
    expect(registry.handlerFor(AppCommand.newTerminal), inner);

    registry.update(b, {AppCommand.newTerminal: null});
    expect(registry.handlerFor(AppCommand.newTerminal), outer);

    registry.unregister(a);
    registry.unregister(b);
    expect(registry.handlerFor(AppCommand.newTerminal), isNull);
  });

  windowsTest('the shortcut sheet lists every command with its keys', (
    tester,
  ) async {
    await pump(tester, const SizedBox.expand());
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await chord(tester, ctrlShift, LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();

    expect(find.byType(ShortcutsSheet), findsOneWidget);
    // Scoped to the list: the sheet's title shares a label with its own row.
    final list = find.descendant(
      of: find.byType(ShortcutsSheet),
      matching: find.byType(SingleChildScrollView),
    );
    for (final command in AppCommand.values) {
      // A panel-scoped row carries a " when focused" suffix.
      final label = RegExp(
        '^${RegExp.escape(command.label)}(  when focused)?\$',
      );
      expect(
        find.descendant(
          of: list,
          matching: find.textContaining(label, findRichText: true),
        ),
        findsOneWidget,
        reason: '$command',
      );
    }
  });
}
