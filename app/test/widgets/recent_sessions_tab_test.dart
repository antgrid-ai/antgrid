import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/new_session_start.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_summary.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_tab.dart';
import 'package:antgrid/widgets/recent_sessions/starting_session_row.dart';
import 'package:antgrid/widgets/session_search_field.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: AbCarbonScope(child: child)),
    ),
  );
}

RecentSessionRow _row(String id, String name) => RecentSessionRow(
  session: SessionEntry(
    id: id,
    name: name,
    createdAt: 0,
    lastUsedAt: 1,
    archived: false,
    running: false,
  ),
  origin: const RecentOrigin(
    isLocal: false,
    registrationId: 'uuidA.projA',
    projectId: 'projA',
    machineUuid: 'uuidA',
    projectName: 'antgrid',
    deviceName: 'Mac',
  ),
);

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
    // The empty state alone is a bare Center with no scroll view, and a second
    // Scrollable would split the drag from the refresh viewport.
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
    // Wide enough that the list header shows the switcher rather than the
    // narrow menu button.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('1 session'), findsOneWidget);
    expect(find.text('Fix auth bug'), findsOneWidget);
    // Carbon end to end, apart from the agent mark.
    expect(abWidgetsInScope(tester), isEmpty);
    // A headless card under a plain heading: the label and a bare count, no tag.
    final group = tester.widget<CarbonContainedListSliver>(
      find.byType(CarbonContainedListSliver),
    );
    expect(group.label, isNull);
    expect(find.text('antgrid'), findsOneWidget);
    expect(find.byType(CarbonTag), findsNothing);
    expect(find.text('Machine'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.byType(CarbonMenuButton), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the mobile list spends no row on a search field', (
    tester,
  ) async {
    // Mobile's search is an icon in the canvas top bar opening a full-screen
    // modal - an inline field here cost a row of a phone screen. The canvas
    // top bar carries the status badges on a phone, which is what
    // `showSummary: false` says here. Mirrors what `NewSessionContent` passes
    // at this width.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
        child: _wrap(const RecentSessionsTab(showSummary: false)),
      ),
    );
    await tester.pump();

    expect(find.byType(SessionSearchField), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a narrow list swaps the switcher for a Group by menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        recentSessionsProvider.overrideWithValue([_row('s1', 'Fix auth bug')]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RecentSessionsTab(showSummary: false)),
      ),
    );
    await tester.pump();

    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('1 session'), findsOneWidget);
    expect(find.byType(CarbonContentSwitcher<RecentGroupBy>), findsNothing);
    expect(find.text('By project'), findsOneWidget);

    await tester.tap(find.text('By project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Machine'));
    await tester.pumpAndSettle();

    expect(container.read(recentGroupByProvider), RecentGroupBy.machine);
    expect(find.text('By machine'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the summary badges sit in the header only with showSummary', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Future<void> pump({required bool showSummary}) async {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(showSummary),
          overrides: [
            recentSessionsProvider.overrideWithValue([_row('s1', 'Task')]),
            recentSessionStatusCountsProvider.overrideWithValue(const {
              AgentWorkStatus.done: 1,
            }),
          ],
          child: _wrap(RecentSessionsTab(showSummary: showSummary)),
        ),
      );
      await tester.pump();
    }

    await pump(showSummary: true);
    expect(find.text('1 done'), findsOneWidget);
    // Between the count and the group-by control.
    expect(
      tester.getTopLeft(find.text('1 done')).dx,
      greaterThan(tester.getTopRight(find.text('1 session')).dx),
    );
    expect(
      tester.getTopRight(find.text('1 done')).dx,
      lessThan(tester.getTopLeft(find.text('Machine')).dx),
    );

    await pump(showSummary: false);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('1 done'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('status grouping heads each group with the status indicator', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        recentSessionsProvider.overrideWithValue([_row('s1', 'Task')]),
      ],
    );
    addTearDown(container.dispose);
    container.read(recentGroupByProvider.notifier).set(RecentGroupBy.status);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(CarbonIconIndicator, 'Done'), findsOneWidget);
    expect(find.byType(CarbonTag), findsNothing);
    expect(find.text('Task'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a wide row is two lines: time on the name line, origin below', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([_row('s1', 'Fix auth bug')]),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();

    final name = find.text('Fix auth bug');
    final time = find.textContaining(' years ago');
    // Grouped by project, so the origin is the machine alone, which a local
    // row never names; use a remote origin's device to have a second line.
    expect(time, findsOneWidget);
    expect(
      tester.getCenter(time).dy,
      moreOrLessEquals(tester.getCenter(name).dy, epsilon: 2),
    );
    expect(find.text('Mac'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Mac')).dy,
      greaterThan(tester.getBottomLeft(name).dy - 1),
    );
    // The time is at the row's end, not in a rail beside the origin.
    expect(
      tester.getTopLeft(time).dx,
      greaterThan(tester.getTopRight(find.text('Mac')).dx),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('summarizes a needs-attention project from the live advert', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    // Wide enough that `_SessionsHeader` renders the badges this test reads —
    // see the comment on the same lines above.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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

  testWidgets('groups lead with the most recently worked one, except that '
      'needs-you leads the status grouping', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    RecentSessionRow row(String uuid, String machine, String name, int used) =>
        RecentSessionRow(
          session: SessionEntry(
            id: name,
            name: name,
            createdAt: 0,
            lastUsedAt: used,
            archived: false,
            running: true,
          ),
          origin: RecentOrigin(
            isLocal: false,
            registrationId: '$uuid.proj',
            projectId: 'proj',
            machineUuid: uuid,
            projectName: 'proj-$machine',
            deviceName: machine,
          ),
        );
    // Alphabetical order, and the fixed status order (error before working),
    // would both put Older above Newer.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([
            row('uuidZ', 'Zed box', 'Newer', 3),
            row('uuidA', 'Alpha box', 'Older', 2),
            row('uuidM', 'Mid box', 'Blocked', 1),
          ]),
        ],
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecentSessionsTab)),
    );
    final statuses = container.read(remoteSessionStatusProvider.notifier);
    statuses.setMachineSessionStatuses('uuidA', {
      'uuidA.proj': {'Older': AgentWorkStatus.error},
    });
    statuses.setMachineSessionStatuses('uuidZ', {
      'uuidZ.proj': {'Newer': AgentWorkStatus.working},
    });
    statuses.setMachineSessionStatuses('uuidM', {
      'uuidM.proj': {'Blocked': AgentWorkStatus.attention},
    });
    double top(String name) => tester.getTopLeft(find.text(name)).dy;

    for (final groupBy in RecentGroupBy.values) {
      container.read(recentGroupByProvider.notifier).set(groupBy);
      await tester.pump();
      expect(top('Newer'), lessThan(top('Older')), reason: '$groupBy');
    }
    // Status is still grouped by STATUS: the oldest session leads because it
    // needs the user, and recency orders everything after it.
    expect(top('Blocked'), lessThan(top('Newer')));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a cached row still shows the live status it is blocked on', (
    tester,
  ) async {
    // The shipped regression: rows restored from the on-disk cache always carry
    // running:false (the store strips it on load), which masked every dot — the
    // whole list read "done" after a restart while an agent sat blocked.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    expect(find.textContaining('Turn on Remote'), findsOneWidget);
    expect(find.textContaining('No recent sessions'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the first heading keeps its gap below a starting row', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        recentSessionsProvider.overrideWithValue([_row('s1', 'Task')]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();

    final heading = find.bySemanticsLabel('antgrid, 1 session');
    final idleTop = tester.getTopLeft(heading).dy;

    container
        .read(newSessionStartProgressProvider.notifier)
        .begin(
          phase: NewSessionStartPhase.activating,
          targetId: 'p',
          targetName: 'antgrid',
          deviceName: '',
          agentLabel: 'Claude Code',
          isolated: false,
          title: 'fix the bug',
        );
    // Not pumpAndSettle: the starting row's spinner repeats forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final gap =
        tester.getTopLeft(heading).dy -
        tester.getBottomLeft(find.byKey(startingSessionRowKey)).dy;
    expect(gap, greaterThanOrEqualTo(CarbonSpacing.spacing05));
    expect(tester.getTopLeft(heading).dy, greaterThan(idleTop));

    handle.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a start scrolls the list back to the row it adds', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    // Torn down as well as reset below, so a failing `expect` surfaces as
    // itself rather than as "a foundation debug variable was changed".
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rows = [
      for (var i = 0; i < 40; i++)
        RecentSessionRow(
          session: SessionEntry(
            id: 's$i',
            name: 'Session $i',
            createdAt: 0,
            lastUsedAt: 40 - i,
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
        ),
    ];
    final container = ProviderContainer(
      overrides: [recentSessionsProvider.overrideWithValue(rows)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const RecentSessionsTab()),
      ),
    );
    await tester.pump();

    final scrollable = find.descendant(
      of: find.byType(RecentSessionsTab),
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(scrollable).position.jumpTo(600);
    await tester.pump();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 600);

    container
        .read(newSessionStartProgressProvider.notifier)
        .begin(
          phase: NewSessionStartPhase.activating,
          targetId: 'p',
          targetName: 'antgrid',
          deviceName: '',
          agentLabel: 'Claude Code',
          isolated: false,
          title: 'fix the bug',
        );
    // Not pumpAndSettle: the placeholder row's spinner repeats forever, so
    // the tree never settles while a start is armed.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Otherwise the placeholder grows above the viewport: every visible row
    // shoved down by its height, and the row the shove was for never seen.
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
    expect(find.byKey(startingSessionRowKey), findsOneWidget);

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
