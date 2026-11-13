import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter_gallery/gallery_app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const List<String> _compositionIds = <String>[
  'settings-form',
  'action-toolbar',
  'row-actions-list',
  'searchable-picker',
  'confirmation-flow',
  'navigation-sidebar',
];

Future<void> _tapFinder(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tapFinder(tester, find.byKey(ValueKey(key)));

Future<void> _ensureSettingsOpen(WidgetTester tester) async {
  if (find.byKey(const ValueKey('setting-density-touch')).evaluate().isEmpty) {
    await _tapKey(tester, 'settings-toggle');
  }
}

void _useWidth(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);
}

Future<void> _openPage(WidgetTester tester, String id, double width) async {
  _useWidth(tester, width);
  await tester.pumpWidget(const GalleryApp());
  await tester.pump();
  await _tapKey(tester, 'page-$id');
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _configure(
  WidgetTester tester, {
  String scale = '1.0',
  String density = 'compact',
}) async {
  await _ensureSettingsOpen(tester);
  await _tapKey(tester, 'setting-textScale-$scale');
  await _tapKey(tester, 'setting-density-$density');
}

Finder _editable(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

void main() {
  for (final id in _compositionIds) {
    testWidgets('$id lays out at every width, scale and density', (
      tester,
    ) async {
      for (final width in <double>[320, 390, 768, 1280]) {
        await _openPage(tester, id, width);
        for (final scale in <String>['1.0', '2.0']) {
          for (final density in <String>['compact', 'touch']) {
            await _configure(tester, scale: scale, density: density);
            await tester.pump(const Duration(milliseconds: 100));
            expect(
              tester.takeException(),
              isNull,
              reason: '$id at $width, scale $scale, $density',
            );
          }
        }
      }
    });
  }

  testWidgets('settings form: submit shows errors and focuses the first', (
    tester,
  ) async {
    await _openPage(tester, 'settings-form', 390);
    await _tapKey(tester, 'settings-submit');
    await tester.pump();
    await tester.pump();
    expect(find.text('Enter your display name.'), findsOneWidget);
    expect(find.text('Choose where sessions should run.'), findsOneWidget);
    final name = tester.widget<EditableText>(_editable('settings-name'));
    expect(name.focusNode.hasFocus, isTrue);

    await tester.enterText(_editable('settings-name'), 'Casey');
    await tester.enterText(_editable('settings-email'), 'casey@example.com');
    await tester.pump();
    expect(find.text('Enter your display name.'), findsNothing);
    await _tapKey(tester, 'settings-region');
    await tester.pump(const Duration(milliseconds: 300));
    await _tapFinder(tester, find.text('US East (N. Virginia)'));
    await tester.pump(const Duration(milliseconds: 300));
    await _tapKey(tester, 'settings-submit');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('settings-saved')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byKey(const ValueKey('settings-saved')), findsOneWidget);
  });

  testWidgets('toolbar folds secondary actions into the overflow menu', (
    tester,
  ) async {
    await _openPage(tester, 'action-toolbar', 1280);
    expect(find.text('Export selected sessions as CSV'), findsOneWidget);
    await _tapKey(tester, 'toolbar-overflow');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Archive finished sessions'), findsOneWidget);
    await _tapFinder(tester, find.text('Archive finished sessions'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Archived finished sessions.'), findsOneWidget);

    await _openPage(tester, 'action-toolbar', 390);
    // Compact: the button is gone from the row and lives in the menu.
    expect(find.text('Export selected sessions as CSV'), findsNothing);
    await _tapKey(tester, 'toolbar-overflow');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Export selected sessions as CSV'), findsOneWidget);
    await _tapFinder(tester, find.text('Export selected sessions as CSV'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Exported sessions.'), findsOneWidget);
  });

  testWidgets('list: row menu deletes; empty, loading and error states', (
    tester,
  ) async {
    await _openPage(tester, 'row-actions-list', 390);
    expect(find.byKey(const ValueKey('row-1')), findsOneWidget);
    await _tapKey(tester, 'row-menu-1');
    await tester.pump(const Duration(milliseconds: 300));
    await _tapFinder(tester, find.text('Delete'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('row-1')), findsNothing);

    Future<void> pickState(String label) async {
      await _tapKey(tester, 'row-state');
      await tester.pump(const Duration(milliseconds: 300));
      // The popup is the last route-less overlay entry, so its option is
      // the last text match (the closed select shows the old value first).
      final option = find.text(label).last;
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await pickState('Error');
    expect(find.text('Sessions could not be loaded.'), findsOneWidget);
    await pickState('Loading');
    expect(find.byKey(const ValueKey('row-2')), findsNothing);
    await pickState('Empty');
    expect(find.text('No sessions match the current filters.'), findsOneWidget);
    await pickState('Content');
    expect(find.byKey(const ValueKey('row-1')), findsOneWidget);
  });

  testWidgets('picker filters a long list and shows the empty state', (
    tester,
  ) async {
    await _openPage(tester, 'searchable-picker', 390);
    await _tapKey(tester, 'picker-combo');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(_editable('picker-combo'), 'zzzz');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No service matches your search.'), findsOneWidget);

    await tester.enterText(_editable('picker-combo'), 'service-0042');
    await tester.pump(const Duration(milliseconds: 300));
    await _tapFinder(tester, find.textContaining('antgrid-service-0042'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Selected: antgrid-service-0042'), findsOneWidget);
  });

  testWidgets('confirmation flow: modal sees settings, outcome is reported', (
    tester,
  ) async {
    await _openPage(tester, 'confirmation-flow', 390);
    await _configure(tester, scale: '2.0');
    await _tapKey(tester, 'confirm-open');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Delete antgrid-public-staging?'), findsOneWidget);
    // The modal route sits on the gallery Navigator, so it must receive the
    // previewed text scale.
    final modal = tester.element(find.byType(CarbonModal));
    expect(MediaQuery.textScalerOf(modal), const TextScaler.linear(2.0));

    await _tapFinder(tester, find.text('Delete workspace'));
    await tester.pump(const Duration(milliseconds: 100));
    // Busy: dismissing is blocked and the dialog stays.
    expect(find.text('Delete antgrid-public-staging?'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Delete antgrid-public-staging?'), findsNothing);
    expect(find.byKey(const ValueKey('confirm-outcome')), findsOneWidget);
    expect(find.text('Its sessions and worktrees were removed.'), findsOneWidget);
    // Let the toast's auto-dismiss timer finish.
    await tester.pump(const Duration(seconds: 7));
    expect(tester.takeException(), isNull);
  });
}
