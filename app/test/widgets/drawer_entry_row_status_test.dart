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
import 'package:antgrid/providers/collapsed_drawer.dart';
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

/// Collapse [id] so the row shows its rollup dot regardless of its session list.
/// A local project row defaults to EXPANDED, and an expanded row hands the dot
/// to its session rows whenever there are any to carry it.
Future<void> _collapse(WidgetTester tester, String id) async {
  ProviderScope.containerOf(tester.element(find.byType(DrawerEntryRow)))
      .read(collapsedDrawerIdsProvider.notifier)
      .toggle(id);
  await tester.pump();
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

    testWidgets('renders the rollup dot when collapsed and advert is working', (
      tester,
    ) async {
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            projectWorkStatusProvider(
              'p1',
            ).overrideWithValue(AgentWorkStatus.working),
          ],
        ),
      );
      await tester.pump();
      await _collapse(tester, 'p1');

      expect(
        find.byKey(const ValueKey('drawer-status-dot-p1')),
        findsOneWidget,
      );
    });

    testWidgets('hides the rollup dot while expanded with sessions on screen', (
      tester,
    ) async {
      // The dot belongs to the session, not the project: with the session rows
      // on screen, a project dot beside them only restates the loudest one.
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            projectWorkStatusProvider(
              'p1',
            ).overrideWithValue(AgentWorkStatus.attention),
            sessionsForEntryProvider(
              'p1',
            ).overrideWith((ref) => [session(running: true)]),
          ],
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('drawer-status-dot-p1')), findsNothing);
    });

    testWidgets('keeps the rollup dot while expanded with no session rows yet', (
      tester,
    ) async {
      // A local row is expanded by DEFAULT and renders nothing while its session
      // list is still loading. Yielding the dot to rows that don't exist left
      // the row with no work indication at all.
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            projectWorkStatusProvider(
              'p1',
            ).overrideWithValue(AgentWorkStatus.attention),
            sessionsForEntryProvider('p1').overrideWith((ref) => const []),
          ],
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('drawer-status-dot-p1')),
        findsOneWidget,
      );
    });

    testWidgets('an archived-only session list does not count as rows', (
      tester,
    ) async {
      // The drawer filters archived sessions out, so they carry no dot — the
      // rollup must stay.
      final entry = _entry('p1');
      await tester.pumpWidget(
        _wrap(
          DrawerEntryRow(entry),
          overrides: [
            ...stores.overrides,
            projectWorkStatusProvider(
              'p1',
            ).overrideWithValue(AgentWorkStatus.error),
            sessionsForEntryProvider('p1').overrideWith(
              (ref) => [
                SessionEntry(
                  id: 'a1',
                  name: 'A',
                  createdAt: 1,
                  lastUsedAt: 2,
                  archived: true,
                  running: false,
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('drawer-status-dot-p1')),
        findsOneWidget,
      );
    });

    testWidgets('a merely-running session is NOT working (no dot)', (
      tester,
    ) async {
      // Sessions alive but no advert: an open chat with nothing running in it
      // must stay clean — only a prompt in flight lights the dot.
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
        await _collapse(tester, 'p1');

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
