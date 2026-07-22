// Plan B Task 17: multi-project status isolation in the drawer.
//
// Regression spec: when a command runs in project B while the user is focused
// on A, A's drawer row must stay clean and B's drawer row must show the
// command indicator. This codifies the "bit the user twice" bug class —
// status updates for one project must never leak into another project's row.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

LocalProjectEntry _entry(String id) => LocalProjectEntry(
  AbProject(
    projectId: id,
    folder: '/tmp/$id',
    displayName: id,
    hostDeviceUuid: id,
    hostMachineName: '',
    lastOpenedAt: DateTime.now(),
  ),
);

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  testWidgets(
    'command running in unfocused project shows only in its drawer row',
    (tester) async {
      final aStatus = StreamController<ProjectStatus>.broadcast();
      final bStatus = StreamController<ProjectStatus>.broadcast();
      addTearDown(() async {
        await aStatus.close();
        await bStatus.close();
      });

      final entryA = _entry('a');
      final entryB = _entry('b');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            // Focused project = A.
            selectedRegistrationIdProvider.overrideWith((_) => 'a'),
            projectStatusProvider('a').overrideWith((_) => aStatus.stream),
            projectStatusProvider('b').overrideWith((_) => bStatus.stream),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisSize: MainAxisSize.min,
                children: [DrawerEntryRow(entryA), DrawerEntryRow(entryB)],
              ),
            ),
          ),
        ),
      );

      // Prime both rows with an empty status. The provider subscribes on
      // first read (via the pumpWidget above), so emit AFTER pump and then
      // settle to let the AsyncValue tick.
      aStatus.add(const ProjectStatus.empty());
      bStatus.add(const ProjectStatus.empty());
      await tester.pumpAndSettle();

      // Neither row should show a command indicator yet.
      expect(
        find.byKey(const ValueKey('drawer-cmd-indicator-a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('drawer-cmd-indicator-b')),
        findsNothing,
      );

      // Drive a command-start status update on B only.
      bStatus.add(
        const ProjectStatus.empty().copyWith(activeCommandName: 'build'),
      );
      await tester.pumpAndSettle();

      // B's drawer row shows the command indicator; A's stays clean.
      expect(
        find.byKey(const ValueKey('drawer-cmd-indicator-b')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('drawer-cmd-indicator-a')),
        findsNothing,
      );

      // The indicator renders the command name so the user can tell what's
      // running on the other project at a glance.
      expect(find.text('build'), findsOneWidget);
    },
  );
}
