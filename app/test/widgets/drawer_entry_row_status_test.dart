import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
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

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  group('DrawerEntryRow status', () {
    testWidgets('renders error dot when configError', (tester) async {
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            projectStatusProvider('p1').overrideWith(
              (ref) => Stream.value(const ProjectStatus(configError: true)),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('drawer-error-dot-p1')), findsOneWidget);
    });

    SessionEntry session({required bool running}) => SessionEntry(
      id: 's1',
      name: 'S',
      createdAt: 1,
      lastUsedAt: 2,
      archived: false,
      running: running,
    );

    testWidgets('renders status dot when a session is running', (tester) async {
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            sessionsForEntryProvider(
              'p1',
            ).overrideWith((ref) => [session(running: true)]),
          ],
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('drawer-status-dot-p1')),
        findsOneWidget,
      );
    });

    testWidgets('no status dot when all sessions are idle (done)', (
      tester,
    ) async {
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            sessionsForEntryProvider(
              'p1',
            ).overrideWith((ref) => [session(running: false)]),
          ],
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('drawer-status-dot-p1')), findsNothing);
    });

    for (final status in [AgentWorkStatus.attention, AgentWorkStatus.error]) {
      testWidgets('renders status dot for ${status.name}', (tester) async {
        final entry = _entry('p1');
        await tester.pumpWidget(
          _wrap(
            DrawerEntryRow(entry),
            overrides: [
              ...stores.overrides,
              projectWorkStatusProvider('p1').overrideWithValue(status),
            ],
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('drawer-status-dot-p1')),
          findsOneWidget,
        );
      });
    }

    testWidgets('tapping the error dot surfaces configErrorMessage', (
      tester,
    ) async {
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            projectStatusProvider('p1').overrideWith(
              (ref) => Stream.value(
                const ProjectStatus(
                  configError: true,
                  configErrorMessage: 'YAML parse error at line 12',
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('drawer-error-dot-p1')));
      await tester.pump(); // let the snackbar build

      expect(find.text('YAML parse error at line 12'), findsOneWidget);
    });

    testWidgets('does NOT rebuild when a different project\'s status changes', (
      tester,
    ) async {
      final p1Ctrl = StreamController<ProjectStatus>.broadcast();
      final p2Ctrl = StreamController<ProjectStatus>.broadcast();
      addTearDown(() async {
        await p1Ctrl.close();
        await p2Ctrl.close();
      });

      var outerBuilds = 0;
      final entry = _entry('p1');

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              outerBuilds++;
              return DrawerEntryRow(entry);
            },
          ),
          overrides: [
            ...stores.overrides,
            projectStatusProvider('p1').overrideWith((ref) => p1Ctrl.stream),
            projectStatusProvider('p2').overrideWith((ref) => p2Ctrl.stream),
          ],
        ),
      );

      p1Ctrl.add(const ProjectStatus(configError: true));
      await tester.pump();

      // Also force p2 provider to be alive by reading its status once.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DrawerEntryRow)),
      );
      // ignore: unused_local_variable
      final _ = container.read(projectStatusProvider('p2'));

      final initial = outerBuilds;

      // Emit a status change on a DIFFERENT project. p1's outer Builder must
      // not rebuild — this is the regression test the plan calls out.
      p2Ctrl.add(const ProjectStatus(configError: true));
      await tester.pump();
      await tester.pump();

      expect(outerBuilds, initial);
    });
  });
}
