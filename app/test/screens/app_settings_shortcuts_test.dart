// App settings' Keyboard shortcuts page: one row in the settings list opens it,
// Back returns to the list, and a `nav/settings?section=shortcuts` link lands on
// it directly. The page lists the same bindings the keyboard dispatches — it
// renders from `appShortcutChords`, so a row can never name a key that does
// nothing — and its filter narrows the list without leaving empty group
// headers behind.
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/keyboard/app_shortcuts.dart';
import 'package:antgrid/models/pending_nav.dart';
import 'package:antgrid/models/settings_section.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/app_settings_screen.dart';
import 'package:antgrid/screens/keyboard_shortcuts_page.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  Future<void> withSettings(
    WidgetTester tester,
    Future<void> Function() body, {
    double width = 1000,
    double height = 4000,
    bool linkToShortcuts = false,
  }) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();
      final service = AppSettingsService(prefs, AppSettings.fromPrefs(prefs));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsServiceProvider.overrideWith(() => service),
            if (linkToShortcuts)
              pendingSettingsSectionProvider.overrideWith(
                () => ValueController<PendingNav<SettingsSection>?>((
                  target: null,
                  value: SettingsSection.shortcuts,
                )),
              ),
          ],
          child: MaterialApp(
            theme: buildAbTheme(),
            home: const AppSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> openPage(WidgetTester tester) async {
    await tester.tap(find.text('View all shortcuts'));
    await tester.pumpAndSettle();
  }

  Finder onPage(Finder matching) => find.descendant(
    of: find.byType(KeyboardShortcutsPage),
    matching: matching,
  );

  /// A row's text is its label, plus " when focused" for a panel-scoped one.
  Finder row(AppCommand command) => onPage(
    find.textContaining(
      RegExp('^${RegExp.escape(command.label)}(  when focused)?\$'),
      findRichText: true,
    ),
  );

  testWidgets('the settings list offers one row, not the whole list', (
    tester,
  ) async {
    await withSettings(tester, () async {
      expect(find.text('KEYBOARD SHORTCUTS'), findsOneWidget);
      expect(find.text('View all shortcuts'), findsOneWidget);
      expect(find.byType(KeyboardShortcutsPage), findsNothing);
      expect(find.text(AppCommand.toggleMaximizePanel.label), findsNothing);
    });
  });

  testWidgets('the row opens a page listing every command', (tester) async {
    await withSettings(tester, () async {
      await openPage(tester);

      expect(find.byType(KeyboardShortcutsPage), findsOneWidget);
      expect(find.text('APP SETTINGS'), findsNothing);
      for (final command in AppCommand.values) {
        expect(row(command), findsOneWidget, reason: '$command');
      }
      expect(onPage(find.text('Ctrl')), findsWidgets);
    });
  });

  testWidgets('back returns to the settings list', (tester) async {
    await withSettings(tester, () async {
      await openPage(tester);
      await tester.tap(
        find.byTooltip(withShortcut('Back to settings', AppCommand.goBack)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(KeyboardShortcutsPage), findsNothing);
      expect(find.text('APP SETTINGS'), findsOneWidget);
    });
  });

  testWidgets('back lands where the row was, not at the top', (tester) async {
    await withSettings(tester, () async {
      await tester.scrollUntilVisible(
        find.text('View all shortcuts'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      final before = offset();
      expect(before, greaterThan(0));

      await openPage(tester);
      await tester.tap(
        find.byTooltip(withShortcut('Back to settings', AppCommand.goBack)),
      );
      await tester.pumpAndSettle();

      expect(offset(), before);
    }, height: 600);
  });

  testWidgets('a link naming the section lands on the page', (tester) async {
    await withSettings(tester, () async {
      expect(find.byType(KeyboardShortcutsPage), findsOneWidget);
    }, linkToShortcuts: true);
  });

  // A key group cannot shrink, so at phone width it has to drop under its
  // label instead of sharing the row — a layout overflow fails this test.
  testWidgets('fits a phone-width column', (tester) async {
    await withSettings(tester, () async {
      await openPage(tester);
      expect(row(AppCommand.toggleMaximizePanel), findsOneWidget);
    }, width: 360);
  });

  testWidgets('the filter narrows rows and drops emptied groups', (
    tester,
  ) async {
    await withSettings(tester, () async {
      await openPage(tester);
      await tester.enterText(onPage(find.byType(EditableText)), 'terminal');
      await tester.pumpAndSettle();

      expect(row(AppCommand.newTerminal), findsOneWidget);
      expect(row(AppCommand.showTerminals), findsOneWidget);
      expect(row(AppCommand.newSession), findsNothing);
      // Dialogs has no command mentioning a terminal.
      expect(onPage(find.text('DIALOGS')), findsNothing);

      await tester.enterText(onPage(find.byType(EditableText)), 'zzz');
      await tester.pumpAndSettle();
      expect(onPage(find.text('No shortcut matches "zzz".')), findsOneWidget);
    });
  });
}
