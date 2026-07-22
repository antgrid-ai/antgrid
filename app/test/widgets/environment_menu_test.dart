import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/widgets/new_session/environment_menu.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

// Fabricated sources follow the pattern used in test/new_session_picker_test.dart
// and test/widgets/project_menu_test.dart: pickerSourcesProvider is a pure
// Provider<List<PickerSource>>, so it can be overridden with a literal list.
final _sources = <PickerSource>[
  const PickerSource(id: 'local', label: 'Local', isLocal: true, projects: []),
  const PickerSource(
    id: 'machine:M',
    label: 'Buildbox',
    isLocal: false,
    projects: [],
    machineUuid: 'M',
  ),
];

Widget _host({List<PickerSource>? sources}) {
  return ProviderScope(
    overrides: [pickerSourcesProvider.overrideWithValue(sources ?? _sources)],
    child: MaterialApp(
      theme: buildAbTheme(),
      home: const Scaffold(body: Center(child: EnvironmentChip())),
    ),
  );
}

void main() {
  testWidgets('chip shows the visible source and panel lists grouped sources', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('Local'), findsOneWidget);

    await tester.tap(find.byType(EnvironmentChip));
    await tester.pumpAndSettle();

    expect(find.text('LOCAL'), findsOneWidget);
    expect(find.text('MACHINES'), findsOneWidget);
    expect(find.text('Buildbox'), findsOneWidget);
  });

  testWidgets(
    'selecting a machine writes selectedSourceIdProvider and closes',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(EnvironmentChip));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(EnvironmentChip)),
      );

      await tester.tap(find.text('Buildbox'));
      await tester.pumpAndSettle();

      expect(container.read(selectedSourceIdProvider), 'machine:M');
      expect(find.text('MACHINES'), findsNothing);
    },
  );

  testWidgets(
    'panel rows are keyboard-operable (Tab to focus, Enter to select)',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(EnvironmentChip));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(EnvironmentChip)),
      );

      // Tab focuses the first focusable panel row (the "Local" source), then
      // Enter activates it — the regression this guards is PanelRow being a
      // bare GestureDetector with no focus/keyboard path (mouse-only).
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(container.read(selectedSourceIdProvider), 'local');
      // Activating a row closes the panel, same as a tap.
      expect(find.text('MACHINES'), findsNothing);
    },
  );

  testWidgets('no machines shows a hint instead of rows', (tester) async {
    await tester.pumpWidget(
      _host(
        sources: const [
          PickerSource(
            id: 'local',
            label: 'Local',
            isLocal: true,
            projects: [],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(EnvironmentChip));
    await tester.pumpAndSettle();

    expect(find.text('MACHINES'), findsOneWidget);
    expect(find.text('No machines on this account'), findsOneWidget);
  });
}
