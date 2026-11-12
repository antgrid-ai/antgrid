import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/new_session/branch_menu.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

Widget _wrap(Widget child, ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(body: Center(child: AbCarbonScope(child: child))),
    ),
  );
}

/// The editable text showing [text]. The combo box also builds its hint, which
/// repeats the current branch, so a plain text finder sees both.
Finder _fieldShowing(String text) => find.byWidgetPredicate(
  (w) => w is EditableText && w.controller.text == text,
);

void main() {
  testWidgets('BranchChip is absent when no target project is selected', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(const BranchChip(), container));
    expect(find.byType(BranchChip), findsOneWidget);
    expect(find.text('Loading branches...'), findsNothing);
  });

  testWidgets('BranchChip shows loaded current branch', (tester) async {
    final container = ProviderContainer(
      overrides: [
        selectedTargetProjectProvider.overrideWith(
          () => ValueController(
            const PickerProject(
              id: 'p1',
              name: 'Project 1',
              detail: '/path/p1',
              isLocal: true,
            ),
          ),
        ),
        newSessionBranchCatalogProvider.overrideWith(
          (ref) async => const GitBranchCatalog(
            isRepository: true,
            current: 'main',
            branches: ['main', 'dev', 'feature'],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(const BranchChip(), container));
    await tester.pumpAndSettle();

    expect(_fieldShowing('main'), findsOneWidget);
  });

  testWidgets('BranchChip shows No Git repository for non-repo folder', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        selectedTargetProjectProvider.overrideWith(
          () => ValueController(
            const PickerProject(
              id: 'p1',
              name: 'Project 1',
              detail: '/path/p1',
              isLocal: true,
            ),
          ),
        ),
        newSessionBranchCatalogProvider.overrideWith(
          (ref) async => const GitBranchCatalog(
            isRepository: false,
            current: null,
            branches: [],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(const BranchChip(), container));
    await tester.pumpAndSettle();

    expect(find.text('No Git repository'), findsOneWidget);
  });

  testWidgets(
    'the combo filters branches case-insensitively and writes the selection',
    (tester) async {
      final container = _repoContainer(
        branches: ['main', 'dev-feature', 'Alpha-Fix'],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(const BranchChip(), container));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BranchChip));
      await tester.pumpAndSettle();

      // The field and its hint already read "main", so the list row makes
      // three.
      expect(_fieldShowing('main'), findsOneWidget);
      expect(find.text('main'), findsNWidgets(3));
      expect(find.text('dev-feature'), findsOneWidget);
      expect(find.text('Alpha-Fix'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();

      expect(find.text('Alpha-Fix'), findsOneWidget);
      expect(find.text('dev-feature'), findsNothing);

      await tester.tap(find.text('Alpha-Fix'));
      await tester.pumpAndSettle();

      final selection = container.read(newSessionBranchSelectionProvider);
      expect(selection?.targetId, 'p1');
      expect(selection?.branch, 'Alpha-Fix');
    },
  );

  testWidgets('an isolated session labels the field with its base branch', (
    tester,
  ) async {
    final container = _repoContainer(
      branches: ['main', 'dev'],
      isolated: true,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(const BranchChip(), container));
    await tester.pumpAndSettle();

    expect(_fieldShowing('Base: main'), findsOneWidget);
  });

  testWidgets('a frozen context row does not open the list', (tester) async {
    final container = _repoContainer(branches: ['main', 'dev']);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(const BranchChip(enabled: false), container),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BranchChip));
    await tester.pumpAndSettle();

    expect(find.text('dev'), findsNothing);
  });
}

ProviderContainer _repoContainer({
  required List<String> branches,
  bool isolated = false,
}) {
  return ProviderContainer(
    overrides: [
      selectedTargetProjectProvider.overrideWith(
        () => ValueController(
          const PickerProject(
            id: 'p1',
            name: 'Project 1',
            detail: '/path/p1',
            isLocal: true,
          ),
        ),
      ),
      newSessionBranchCatalogProvider.overrideWith(
        (ref) async => GitBranchCatalog(
          isRepository: true,
          current: 'main',
          branches: branches,
        ),
      ),
      if (isolated)
        newSessionIsolatedProvider.overrideWith(() => ValueController(true)),
    ],
  );
}
