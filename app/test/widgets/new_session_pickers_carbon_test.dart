import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/new_session/branch_menu.dart';
import 'package:antgrid/widgets/new_session/environment_menu.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/new_session/project_menu.dart';

import '../helpers/carbon_guard.dart';

const _project = PickerProject(
  id: 'p1',
  name: 'Project 1',
  detail: '/path/p1',
  isLocal: true,
);

const _local = PickerSource(
  id: 'local',
  label: 'Local',
  isLocal: true,
  projects: [_project],
);

Widget _host(
  CarbonDensity density, {
  Alignment alignment = Alignment.topLeft,
}) => ProviderScope(
  overrides: [
    pickerSourcesProvider.overrideWithValue(const [_local]),
    selectedTargetProjectProvider.overrideWith(
      () => ValueController<PickerProject?>(_project),
    ),
    newSessionBranchCatalogProvider.overrideWith(
      (ref) async => const GitBranchCatalog(
        isRepository: true,
        current: 'main',
        branches: ['main', 'dev'],
      ),
    ),
  ],
  child: MaterialApp(
    theme: buildAbTheme(),
    home: Scaffold(
      body: Align(
        alignment: alignment,
        child: AbCarbonScope(
          density: density,
          child: Builder(
            builder: (context) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EnvironmentChip(),
                ProjectChip(onOpenFolder: () {}),
                const BranchChip(),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final density in CarbonDensity.values) {
    group('${density.name} density', () {
      testWidgets('every picker is exactly one control tall', (tester) async {
        await tester.pumpWidget(_host(density));
        await tester.pumpAndSettle();

        final t = CarbonTheme.of(tester.element(find.byType(BranchChip)));
        // The combo box paints its rule inside its box; an extra border pixel
        // would make the branch picker taller than its neighbours.
        for (final type in [EnvironmentChip, ProjectChip, BranchChip]) {
          expect(
            tester.getSize(find.byType(type)).height,
            t.controlHeight,
            reason: '$type',
          );
        }
      });

      testWidgets('no Ab widget renders under the scope, open or closed', (
        tester,
      ) async {
        await tester.pumpWidget(_host(density));
        await tester.pumpAndSettle();
        expect(abWidgetsInScope(tester), isEmpty);

        for (final type in [EnvironmentChip, ProjectChip, BranchChip]) {
          await tester.tap(find.byType(type));
          await tester.pumpAndSettle();
          expect(abWidgetsInScope(tester), isEmpty, reason: '$type open');
          await tester.tapAt(const Offset(780, 580));
          await tester.pumpAndSettle();
        }
      });
    });
  }

  testWidgets('the branch list opens above the field', (
    tester,
  ) async {
    // Centred: the list fits above and below, so only the preference decides.
    await tester.pumpWidget(
      _host(CarbonDensity.compact, alignment: Alignment.centerLeft),
    );
    await tester.pumpAndSettle();

    final field = tester.getRect(find.byType(CarbonComboBox<String>));
    await tester.tap(find.byType(BranchChip));
    await tester.pumpAndSettle();

    final row = tester.getRect(find.text('dev'));
    expect(row.bottom, lessThanOrEqualTo(field.top));
  });
}
