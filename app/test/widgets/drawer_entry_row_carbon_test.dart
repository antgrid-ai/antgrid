// The drawer's machine bands and project rows are Carbon side-nav rows. What
// these tests hold: no Ab visual widget survives inside them, the liveness and
// attention marks say their state to a screen reader, the folder-to-chevron
// swap is a pointer-only affordance, and a long-press drag neither activates a
// row nor raises a tooltip.
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusProvider;
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/collapsed_drawer.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';
const _projectId = 'p1';

LocalProjectEntry _project() => LocalProjectEntry(
  AbProject(
    projectId: _projectId,
    folder: '/tmp/$_projectId',
    displayName: _projectId,
    hostDeviceUuid: _projectId,
    hostMachineName: '',
    lastOpenedAt: DateTime(2026, 1, 1),
  ),
);

RemoteAgentEntry _machine() => RemoteAgentEntry(
  RecentAgent(
    agentDeviceId: _machineUuid,
    agentLabel: 'Remote pair',
    agentEd25519Pubkey: 'pub',
    relayUrl: 'wss://relay.example.com',
    pairedAt: DateTime(2026, 1, 1),
    lastConnectedAt: DateTime(2026, 1, 2),
    hostMachineName: _machineName,
  ),
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
  description: 'icon button "$label"',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget row, {
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...stores.overrides, ...overrides],
        child: MaterialApp(
          home: AbCarbonScope(
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 300, child: row),
              ),
            ),
          ),
        ),
      ),
    );
    // Bounded pumps: a pulsing dot keeps frames coming, so nothing here may
    // settle.
    await tester.pump();
    await tester.pump();
  }

  List<Override> machineOverrides(
    SupervisorStatus status, {
    bool conflict = false,
  }) => [
    projectStatusProvider(
      _machineUuid,
    ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
    supervisorStatusProvider(
      _machineUuid,
    ).overrideWith((_) => Stream.value(status)),
    centralControlConflictProvider(
      _machineUuid,
    ).overrideWith((_) => Stream.value(conflict)),
  ];

  group('bands', () {
    testWidgets('the local band is Carbon only and reports the host', (
      tester,
    ) async {
      await pump(
        tester,
        const LocalMachineBand(),
        overrides: [
          hostStatusProvider.overrideWith(
            (_) => Stream.value(const HostStatus(HostPhase.up)),
          ),
        ],
      );
      expect(find.text('This machine'), findsOneWidget);
      expect(abWidgetsInScope(tester), isEmpty);
      final dot = tester.widget<CarbonLivenessDot>(
        find.byType(CarbonLivenessDot),
      );
      expect(dot.liveness, DrawerLiveness.connected);
    });

    final cases =
        <({String name, SupervisorStatus status, DrawerLiveness live})>[
          (
            name: 'online',
            status: const Connected(),
            live: DrawerLiveness.connected,
          ),
          (
            name: 'connecting',
            status: const Climbing(ConnRung.coords),
            live: DrawerLiveness.connecting,
          ),
          (
            name: 'blocked',
            status: const Blocked(BlockReason.handshakeFailing),
            live: DrawerLiveness.failed,
          ),
        ];
    for (final c in cases) {
      testWidgets('a machine band that is ${c.name} is Carbon only', (
        tester,
      ) async {
        await pump(
          tester,
          MachineDrawerHeaderRow(_machine()),
          overrides: machineOverrides(c.status),
        );
        expect(find.text(_machineName), findsOneWidget);
        expect(abWidgetsInScope(tester), isEmpty);
        final dot = tester.widget<CarbonLivenessDot>(
          find.byType(CarbonLivenessDot),
        );
        expect(dot.liveness, c.live);
        expect(
          dot.semanticLabel,
          isNotEmpty,
          reason: 'colour is the only other channel for this state',
        );
      });
    }

    testWidgets('a machine band in conflict offers Retry instead of a dot', (
      tester,
    ) async {
      await pump(
        tester,
        MachineDrawerHeaderRow(_machine()),
        overrides: machineOverrides(const Connected(), conflict: true),
      );
      expect(abWidgetsInScope(tester), isEmpty);
      expect(_button('Control connection conflict — Retry'), findsOneWidget);
      expect(find.byType(CarbonLivenessDot), findsNothing);
    });
  });

  group('project rows', () {
    testWidgets(
      'a collapsed project with attention, an error and a command is Carbon '
      'only and says all three',
      (tester) async {
        // Touch density keeps three 44 targets beside the marks, which leaves a
        // 300px row no room for a name at test-font widths; the marks' own
        // semantics are what this holds, so it runs where the row can host them.
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final handle = tester.ensureSemantics();
        try {
          await pump(
            tester,
            DrawerEntryRow(_project()),
            overrides: [
              projectStatusProvider(_projectId).overrideWith(
                (_) => Stream.value(
                  const ProjectStatus(
                    configError: true,
                    configErrorMessage: 'bad yaml',
                    activeCommandName: 'build',
                  ),
                ),
              ),
            ],
          );
          final container = ProviderScope.containerOf(
            tester.element(find.byType(DrawerEntryRow)),
          );
          container
              .read(remoteProjectStatusProvider.notifier)
              .setLocalStatuses({_projectId: AgentWorkStatus.attention});
          container
              .read(collapsedDrawerIdsProvider.notifier)
              .toggle(_projectId);
          await tester.pump();
          await tester.pump();

          expect(abWidgetsInScope(tester), isEmpty);
          expect(
            find.byKey(const ValueKey('drawer-error-dot-$_projectId')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('drawer-cmd-indicator-$_projectId')),
            findsOneWidget,
          );
          expect(find.byType(DrawerProjectAggregateDot), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp('Config error')), findsWidgets);
          expect(find.bySemanticsLabel(RegExp('running build')), findsWidgets);
          expect(find.bySemanticsLabel(RegExp('Needs you')), findsWidgets);
          // The attention dot pulses on a timer that must not outlive the tree.
          await tester.pumpWidget(const SizedBox());
        } finally {
          handle.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('a revealed row with its menu open is Carbon only', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pump(tester, DrawerEntryRow(_project()));
        await hoverRow(tester, find.text(_projectId));
        await tester.tap(
          find.byWidgetPredicate(
            (w) =>
                w is CarbonOverflowMenu &&
                w.semanticLabel == 'Actions for $_projectId',
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Remove from history'), findsOneWidget);
        expect(abWidgetsInScope(tester), isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the folder swaps for a chevron under a mouse on desktop', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pump(tester, DrawerEntryRow(_project()));
        final swapped = find.descendant(
          of: find.byType(DrawerEntryRow),
          matching: find.byType(AnimatedRotation),
        );
        expect(swapped, findsNothing);
        await hoverRow(tester, find.text(_projectId));
        expect(swapped, findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('swapsIcon never shows on touch ($platform)', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await pump(tester, DrawerEntryRow(_project()));
          await hoverRow(tester, find.text(_projectId));
          expect(
            find.descendant(
              of: find.byType(DrawerEntryRow),
              matching: find.byType(AnimatedRotation),
            ),
            findsNothing,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    // The drawer wraps each row in the same delayed drag listener, so a
    // long-press has its real third claimant in the gesture arena.
    Future<List<(int, int)>> pumpReorderable(WidgetTester tester) async {
      final reorders = <(int, int)>[];
      await pump(
        tester,
        SizedBox(
          height: 400,
          child: ReorderableListView(
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => reorders.add((from, to)),
            children: [
              for (var i = 0; i < 2; i++)
                ReorderableDelayedDragStartListener(
                  key: ValueKey('row-$i'),
                  index: i,
                  child: DrawerEntryRow(
                    LocalProjectEntry(
                      AbProject(
                        projectId: 'p$i',
                        folder: '/tmp/p$i',
                        displayName: 'p$i',
                        hostDeviceUuid: 'p$i',
                        hostMachineName: '',
                        lastOpenedAt: DateTime(2026, 1, 1),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      return reorders;
    }

    testWidgets('a long-press drag on the title reorders without activating '
        'the row', (tester) async {
      final reorders = await pumpReorderable(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DrawerEntryRow).first),
      );

      final touch = await tester.startGesture(
        tester.getCenter(find.text('p0')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 0; i < 8; i++) {
        await touch.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 100));
      await touch.up();
      await tester.pumpAndSettle();

      expect(reorders, isNotEmpty, reason: 'the long-press drag reorders');
      expect(
        container.read(collapsedDrawerIdsProvider),
        isEmpty,
        reason: 'a drag is a reorder, not a tap',
      );
      expect(
        find.text('New session'),
        findsNothing,
        reason: 'a drag on the title raises no action tooltip',
      );
    });

    testWidgets('a long press on an action names it instead of activating '
        'anything', (tester) async {
      // An icon button owns its own long press, which shows its name, so a drag
      // started on one is that button's and never the row's.
      await pumpReorderable(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DrawerEntryRow).first),
      );

      final touch = await tester.startGesture(
        tester.getCenter(_button('New session').first),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.text('New session'),
        findsOneWidget,
        reason: 'an icon button names itself only in its tooltip overlay',
      );
      await touch.up();
      await tester.pump();

      expect(
        container.read(collapsedDrawerIdsProvider),
        isEmpty,
        reason: 'a long press is not a tap on the row',
      );
    });
  });
}
