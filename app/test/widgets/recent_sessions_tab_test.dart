import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_tab.dart';

import '../helpers/prefs_test_mock.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('shows empty state when there are no recent sessions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [recentSessionsProvider.overrideWithValue(const [])],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();
    expect(find.textContaining('No recent sessions'), findsOneWidget);
    // The empty branch must present a Scrollable so an ancestor
    // RefreshIndicator (new_session_content.dart) has a gesture target —
    // AbEmptyState alone is a bare Center with no scroll view.
    expect(
      find.descendant(
        of: find.byType(RecentSessionsTab),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('pull-to-refresh fires onRefresh even when recents are empty', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var refreshed = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [recentSessionsProvider.overrideWithValue(const [])],
        child: _wrap(
          RefreshIndicator(
            onRefresh: () async => refreshed = true,
            // Mirror the wiring in new_session_content.dart: the empty
            // RecentSessionsTab must supply the scroll notification the
            // RefreshIndicator listens for.
            child: const RecentSessionsTab(),
          ),
        ),
      ),
    );
    await tester.pump();

    // Controlled overscroll drag from the top: with an
    // AlwaysScrollableScrollPhysics scroll view present, dragging down past
    // the RefreshIndicator's arm threshold and releasing fires onRefresh.
    // Without the fix the empty state has no Scrollable and this gesture is
    // inert. A held gesture (not a fling) is used so the indicator arms
    // deterministically rather than scrolling ballistically.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RecentSessionsTab)),
    );
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(refreshed, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('lists rows when sessions exist', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's1',
        name: 'Fix auth bug',
        createdAt: 0,
        lastUsedAt: 1,
        archived: false,
        running: false,
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'p',
        projectId: 'p',
        machineUuid: null,
        projectName: 'antgrid',
        deviceName: 'This device',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([row]),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Sessions'), findsOneWidget);
    expect(find.text('Fix auth bug'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('summarizes a needs-attention project from the live advert', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's1',
        name: 'Task',
        createdAt: 0,
        lastUsedAt: 1,
        archived: false,
        running: true,
      ),
      origin: const RecentOrigin(
        isLocal: false,
        registrationId: 'uuidA.projA',
        projectId: 'projA',
        machineUuid: 'uuidA',
        projectName: 'proj',
        deviceName: 'Mac',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([row]),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    // Feed the live advert the way the app_shell reaper does.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecentSessionsTab)),
    );
    container.read(remoteProjectStatusProvider.notifier).setMachineStatuses(
      'uuidA',
      {'uuidA.projA': AgentWorkStatus.attention},
    );
    await tester.pump();

    // The header summarizes it as attention despite the session's running flag.
    expect(find.textContaining('1 needs you'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('counts only the session that is actually blocked', (
    tester,
  ) async {
    // Two sessions on ONE project, one blocked: the summary must read "1 needs
    // you · 1 working", not paint both with the project rollup.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const origin = RecentOrigin(
      isLocal: false,
      registrationId: 'uuidA.projA',
      projectId: 'projA',
      machineUuid: 'uuidA',
      projectName: 'proj',
      deviceName: 'Mac',
    );
    RecentSessionRow row(String id, String name) => RecentSessionRow(
      session: SessionEntry(
        id: id,
        name: name,
        createdAt: 0,
        lastUsedAt: 1,
        archived: false,
        running: true,
      ),
      origin: origin,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([
            row('s1', 'Blocked'),
            row('s2', 'Busy'),
          ]),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecentSessionsTab)),
    );
    container.read(remoteProjectStatusProvider.notifier).setMachineStatuses(
      'uuidA',
      {'uuidA.projA': AgentWorkStatus.attention}, // the rollup
    );
    container
        .read(remoteSessionStatusProvider.notifier)
        .setMachineSessionStatuses('uuidA', {
          'uuidA.projA': {
            's1': AgentWorkStatus.attention,
            's2': AgentWorkStatus.working,
          },
        });
    await tester.pump();

    expect(find.textContaining('1 needs you'), findsOneWidget);
    expect(find.textContaining('1 working'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a cached row still shows the live status it is blocked on', (
    tester,
  ) async {
    // The shipped regression: rows restored from the on-disk cache always carry
    // running:false (the store strips it on load), which masked every dot — the
    // whole list read "done" after a restart while an agent sat blocked.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final row = RecentSessionRow(
      session: const SessionEntry(
        id: 's1',
        name: 'Task',
        createdAt: 0,
        lastUsedAt: 1,
        archived: false,
        running: false,
      ),
      origin: const RecentOrigin(
        isLocal: true,
        registrationId: 'projLocal',
        projectId: 'projLocal',
        machineUuid: null,
        projectName: 'antgrid',
        deviceName: 'This device',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([row]),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecentSessionsTab)),
    );
    // Feed it the way the desktop host poll does, from `project:list`.
    container.read(remoteProjectStatusProvider.notifier).setLocalStatuses({
      'projLocal': AgentWorkStatus.attention,
    });
    container
        .read(remoteSessionStatusProvider.notifier)
        .setLocalSessionStatuses({
          'projLocal': {'s1': AgentWorkStatus.attention},
        });
    await tester.pump();

    expect(find.textContaining('1 needs you'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile with the checklist not yet done shows it in place of '
      'the empty state', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    useInMemoryPrefs();
    final firstRunStore = await FirstRunStore.open();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue(const []),
          // No machine sources at all, without touching the
          // projects/recents/inventory providers.
          pickerSourcesProvider.overrideWithValue(const <PickerSource>[]),
          firstRunStoreProvider.overrideWithValue(firstRunStore),
          // Short-circuit the network-backed inventory: no machines yet.
          accountAgentsProvider.overrideWith((_) async => const []),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();
    expect(find.text('Connect a machine'), findsOneWidget);
    expect(
      find.textContaining('Turn on Remote'),
      findsOneWidget,
    );
    expect(find.textContaining('No recent sessions'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop empty state names the pick-a-project step when no '
      'target is selected', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [recentSessionsProvider.overrideWithValue(const [])],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();
    expect(
      find.text('Pick a project, then describe a task below.'),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
