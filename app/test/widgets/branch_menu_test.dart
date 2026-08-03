import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      home: Scaffold(
        body: Center(child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('BranchChip is absent when no target project is selected',
      (tester) async {
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
          () => ValueController(const PickerProject(
            id: 'p1',
            name: 'Project 1',
            detail: '/path/p1',
            isLocal: true,
          )),
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

    expect(find.text('main'), findsOneWidget);
  });

  testWidgets('BranchChip shows No Git repository for non-repo folder',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        selectedTargetProjectProvider.overrideWith(
          () => ValueController(const PickerProject(
            id: 'p1',
            name: 'Project 1',
            detail: '/path/p1',
            isLocal: true,
          )),
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
      'BranchPanel filters branches case-insensitively and updates selection state',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        selectedTargetProjectProvider.overrideWith(
          () => ValueController(const PickerProject(
            id: 'p1',
            name: 'Project 1',
            detail: '/path/p1',
            isLocal: true,
          )),
        ),
        newSessionBranchCatalogProvider.overrideWith(
          (ref) async => const GitBranchCatalog(
            isRepository: true,
            current: 'main',
            branches: ['main', 'dev-feature', 'Alpha-Fix'],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(const BranchPanel(), container));
    await tester.pumpAndSettle();

    expect(find.text('main'), findsOneWidget);
    expect(find.text('dev-feature'), findsOneWidget);
    expect(find.text('Alpha-Fix'), findsOneWidget);

    // Search query
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();

    expect(find.text('Alpha-Fix'), findsOneWidget);
    expect(find.text('dev-feature'), findsNothing);

    // Tap on row
    await tester.tap(find.text('Alpha-Fix'));
    await tester.pumpAndSettle();

    final selection = container.read(newSessionBranchSelectionProvider);
    expect(selection?.targetId, 'p1');
    expect(selection?.branch, 'Alpha-Fix');
  });
}
