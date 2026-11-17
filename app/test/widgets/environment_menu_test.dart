import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_carbon.dart';
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
      home: const Scaffold(
        body: Center(child: AbCarbonScope(child: EnvironmentChip())),
      ),
    ),
  );
}

void main() {
  testWidgets('chip shows the visible source and menu lists grouped sources', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    // Only the trigger names the source before the menu opens.
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Machines'), findsNothing);

    await tester.tap(find.byType(EnvironmentChip));
    await tester.pumpAndSettle();

    expect(find.text('Machines'), findsOneWidget);
    expect(find.text('Buildbox'), findsOneWidget);
    // Trigger + group heading + radio row.
    expect(find.text('Local'), findsNWidgets(3));
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
      expect(find.text('Machines'), findsNothing);
    },
  );

  testWidgets('menu rows are keyboard-operable (arrow to focus, Enter)', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(EnvironmentChip));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EnvironmentChip)),
    );

    // The menu focuses its first row (Local) on open; one arrow reaches the
    // machine. Choosing Buildbox rather than the default proves Enter acts on
    // the focused row and not merely on the first one.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(container.read(selectedSourceIdProvider), 'machine:M');
    expect(find.text('Machines'), findsNothing);
  });

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

    expect(find.text('Machines'), findsOneWidget);
    expect(find.text('No machines on this account'), findsOneWidget);
  });
}
