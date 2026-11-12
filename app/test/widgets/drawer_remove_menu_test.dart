// The drawer's Remove/Forget action is a Carbon overflow menu opening a Carbon
// danger modal. What these tests hold: the revealed trigger survives the whole
// menu-to-modal hand-off, a confirmed removal runs exactly once, and the
// Carbon trigger's painted box never leaves the row's rail cell.
import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _projectId = 'beta-local';
const _projectName = 'Beta local';
const _machineId = 'machine-1';

AbProject _project() => AbProject(
  projectId: _projectId,
  folder: '/tmp/$_projectId',
  displayName: _projectName,
  hostDeviceUuid: _projectId,
  hostMachineName: '',
  lastOpenedAt: DateTime(2026, 1, 1),
);

RecentAgent _machine() => RecentAgent(
  agentDeviceId: _machineId,
  agentLabel: 'Remote pair',
  agentEd25519Pubkey: 'pub',
  relayUrl: 'wss://relay.example.com',
  pairedAt: DateTime(2026, 1, 1),
  lastConnectedAt: DateTime(2026, 1, 2),
  hostMachineName: 'RadhaAI',
);

/// Records calls and holds the teardown open until [gate] completes, so the
/// busy window can be observed.
class _SpyProjects extends ProjectsNotifier {
  static final removed = <String>[];
  static Completer<void>? gate;

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    await gate?.future;
  }
}

class _SpyMachines extends MachineConnectionNotifier {
  static final forgotten = <String>[];

  @override
  Future<void> forgetMachine(String agentDeviceIdOrUuid) async {
    forgotten.add(agentDeviceIdOrUuid);
  }
}

class _HasSession extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final _hasSession = NotifierProvider<_HasSession, bool>(_HasSession.new);

Finder _actionsFor(String name) => find.byWidgetPredicate(
  (w) => w is CarbonOverflowMenu && w.semanticLabel == 'Actions for $name',
  description: 'overflow menu "Actions for $name"',
);

/// Whether the focused widget sits inside [trigger].
bool _focusIsWithin(Finder trigger) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final target = trigger.evaluate().single;
  var inside = false;
  focused.visitAncestorElements((e) {
    if (e == target) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
    _SpyProjects.removed.clear();
    _SpyProjects.gate = null;
    _SpyMachines.forgotten.clear();
  });

  tearDown(() async {
    await stores.close();
  });

  Future<void> pumpRow(
    WidgetTester tester,
    DrawerEntry entry, {
    double textScale = 1.0,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          projectsProvider.overrideWith(_SpyProjects.new),
          machineConnectionProvider.overrideWith(_SpyMachines.new),
          projectStatusProvider(
            _projectId,
          ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
          sessionsForEntryProvider(_projectId).overrideWith(
            (ref) => ref.watch(_hasSession)
                ? [
                    SessionEntry(
                      id: 's1',
                      name: 'S',
                      createdAt: 1,
                      lastUsedAt: 2,
                      archived: false,
                      running: true,
                    ),
                  ]
                : const [],
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 300, child: DrawerEntryRow(entry)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<TestGesture> hover(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(DrawerEntryRow)));
    await tester.pump();
    return gesture;
  }

  Future<void> openMenuAndChoose(
    WidgetTester tester,
    Finder trigger,
    String item,
  ) async {
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  Future<void> tabTo(WidgetTester tester, Finder trigger) async {
    for (var i = 0; i < 8 && !(trigger.evaluate().isNotEmpty && _focusIsWithin(trigger)); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(_focusIsWithin(trigger), isTrue, reason: 'Tab never reached it');
  }

  group('local project', () {
    testWidgets('Cancel removes nothing and returns focus to the trigger', (
      tester,
    ) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      await hover(tester);
      final trigger = _actionsFor(_projectName);

      await openMenuAndChoose(tester, trigger, 'Remove from history');
      expect(find.text('Remove $_projectName?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(_SpyProjects.removed, isEmpty);
      expect(find.text('Remove $_projectName?'), findsNothing);
      expect(trigger, findsOneWidget);
      expect(
        _focusIsWithin(trigger),
        isTrue,
        reason: 'the row is still mounted, so focus belongs on its trigger',
      );
    });

    testWidgets('Confirm removes the project exactly once', (tester) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      await hover(tester);

      await openMenuAndChoose(
        tester,
        _actionsFor(_projectName),
        'Remove from history',
      );
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(_SpyProjects.removed, [_projectId]);
    });

    testWidgets('the trigger is disabled while teardown is in flight', (
      tester,
    ) async {
      _SpyProjects.gate = Completer<void>();
      await pumpRow(tester, LocalProjectEntry(_project()));
      await hover(tester);
      final trigger = _actionsFor(_projectName);

      await openMenuAndChoose(tester, trigger, 'Remove from history');
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<CarbonOverflowMenu>(trigger).enabled,
        isFalse,
        reason: 'a second activation would re-enter the confirmed removal',
      );
      await tester.tap(trigger, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        find.text('Remove from history'),
        findsNothing,
        reason: 'a disabled trigger must not open its menu',
      );

      _SpyProjects.gate!.complete();
      await tester.pumpAndSettle();
      expect(_SpyProjects.removed, [_projectId]);
    });

    testWidgets('the pointer crossing from the row into the menu keeps both', (
      tester,
    ) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      final gesture = await hover(tester);
      final trigger = _actionsFor(_projectName);

      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final item = find.text('Remove from history');
      expect(item, findsOneWidget);

      // The menu's overlay is outside the row's hover region, so arriving on it
      // is what would un-reveal the row.
      await gesture.moveTo(tester.getCenter(item));
      await tester.pumpAndSettle();

      expect(item, findsOneWidget, reason: 'the menu closed under the pointer');
      expect(trigger, findsOneWidget, reason: 'the row un-revealed its action');
    });

    testWidgets('the row stays revealed in every frame of menu to modal', (
      tester,
    ) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      final gesture = await hover(tester);
      final trigger = _actionsFor(_projectName);

      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final item = find.text('Remove from history');
      await gesture.moveTo(tester.getCenter(item));
      await tester.pump();

      // Pressed by hand so every frame between the item press and the settled
      // modal can be inspected: the menu's close and the modal's open land
      // together, and a gap between them would unmount the trigger.
      final touch = await tester.startGesture(tester.getCenter(item));
      await touch.up();
      await gesture.moveTo(Offset.zero);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          trigger,
          findsOneWidget,
          reason: 'trigger unmounted in frame $i of the hand-off',
        );
      }
      expect(find.text('Remove $_projectName?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        trigger,
        findsOneWidget,
        reason:
            'focus returned to the trigger, which keeps the row revealed once '
            'the latch is released',
      );
    });

    testWidgets('keyboard opens the menu, chooses the item, Escape cancels', (
      tester,
    ) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      await hover(tester);
      final trigger = _actionsFor(_projectName);
      await tabTo(tester, trigger);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Remove from history'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Remove $_projectName?'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Remove $_projectName?'), findsNothing);
      expect(_SpyProjects.removed, isEmpty);
      expect(_focusIsWithin(trigger), isTrue);
    });

    testWidgets('a trigger unmounted under its open menu releases the row', (
      tester,
    ) async {
      // Touch rows are revealed for good, so only a pointer platform can show
      // the latch outliving the trigger.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpRow(tester, LocalProjectEntry(_project()));
        final gesture = await hover(tester);
        final trigger = _actionsFor(_projectName);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        expect(find.text('Remove from history'), findsOneWidget);

        // A session appearing makes the project ineligible for removal, which
        // takes the trigger out of the row while its menu is open.
        ProviderScope.containerOf(
          tester.element(find.byType(DrawerEntryRow)),
        ).read(_hasSession.notifier).set(true);
        await tester.pumpAndSettle();
        expect(trigger, findsNothing);

        await gesture.moveTo(const Offset(150, 400));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('New session'),
          findsNothing,
          reason: 'the latch outlived the trigger that took it',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      testWidgets('Cancel returns focus to the trigger on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await pumpRow(tester, LocalProjectEntry(_project()));
          await hover(tester);
          final trigger = _actionsFor(_projectName);
          await openMenuAndChoose(tester, trigger, 'Remove from history');
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(_focusIsWithin(trigger), isTrue);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('Escape on a mouse-opened menu returns focus to the trigger', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpRow(tester, LocalProjectEntry(_project()));
        final gesture = await hover(tester);
        final trigger = _actionsFor(_projectName);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        await gesture.moveTo(const Offset(150, 400));
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.text('Remove from history'), findsNothing);
        expect(
          _focusIsWithin(trigger),
          isTrue,
          reason: 'focus on the scope leaves the row revealed with no owner',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the danger modal opens on Cancel, the safe choice', (
      tester,
    ) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      await hover(tester);
      await openMenuAndChoose(
        tester,
        _actionsFor(_projectName),
        'Remove from history',
      );
      final cancel = find
          .ancestor(
            of: find.text('Cancel'),
            matching: find.byType(CarbonButton),
          )
          .first;
      expect(_focusIsWithin(cancel), isTrue);
    });

    testWidgets('Space opens the menu too', (tester) async {
      await pumpRow(tester, LocalProjectEntry(_project()));
      await hover(tester);
      await tabTo(tester, _actionsFor(_projectName));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('Remove from history'), findsOneWidget);
    });
  });

  group('remote machine', () {
    testWidgets('Forget calls forgetMachine exactly once', (tester) async {
      final recent = _machine();
      final entry = RemoteAgentEntry(recent);
      await pumpRow(tester, entry);
      await hover(tester);

      await openMenuAndChoose(
        tester,
        _actionsFor(entry.displayName),
        'Forget agent',
      );
      expect(find.text('Forget ${entry.displayName}?'), findsOneWidget);
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();

      expect(_SpyMachines.forgotten, [_machineId]);
    });

    testWidgets('Cancel forgets nothing', (tester) async {
      final recent = _machine();
      final entry = RemoteAgentEntry(recent);
      await pumpRow(tester, entry);
      await hover(tester);

      await openMenuAndChoose(
        tester,
        _actionsFor(entry.displayName),
        'Forget agent',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(_SpyMachines.forgotten, isEmpty);
    });
  });

  group('footprint', () {
    testWidgets('touch @2.0: the trigger stays a 48 square in a taller cell', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpRow(tester, LocalProjectEntry(_project()), textScale: 2.0);
        await hover(tester);
        final cell = tester.getRect(
          find.byKey(const ValueKey('drawer-remove-cell')),
        );
        final trigger = tester.getRect(_actionsFor(_projectName));
        expect(cell.height, greaterThan(48));
        expect(trigger.size, const Size(48, 48));
        expect(trigger.center, cell.center);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final mobile in [false, true]) {
      testWidgets(
        '${mobile ? 'touch' : 'compact'}: the cell is the row-sized trigger box',
        (tester) async {
          debugDefaultTargetPlatformOverride = mobile
              ? TargetPlatform.android
              : TargetPlatform.windows;
          try {
            await pumpRow(tester, LocalProjectEntry(_project()));
            await hover(tester);
            final trigger = _actionsFor(_projectName);
            expect(trigger, findsOneWidget);

            final cell = find.byKey(const ValueKey('drawer-remove-cell'));
            final context = tester.element(find.byType(DrawerEntryRow));
            final cellRect = tester.getRect(cell);
            expect(cellRect.width, AbIconButton.footprintWidth(context));
            // Touch is Apple's 44pt target: the cell fills the row's whole
            // content height. Desktop keeps the 24px trigger box.
            expect(
              cellRect.height,
              mobile ? 44.0 : AbIconButton.boxExtent(context),
            );
            if (mobile) {
              expect(cellRect.size, const Size(44, 44));
              // The tappable box, not the AbListRow's, which also carries the
              // 2+2 margin around it.
              final rowRect = tester
                  .getRect(
                    find
                        .ancestor(of: cell, matching: find.byType(AbListRow))
                        .first,
                  )
                  .deflate(AbTokens.space2);
              expect(
                rowRect.top <= cellRect.top + 0.01 &&
                    rowRect.bottom >= cellRect.bottom - 0.01,
                isTrue,
                reason: 'the target lies within its own row: $cellRect vs $rowRect',
              );
              expect(cellRect.top - rowRect.top, closeTo(0, 0.01));
              expect(rowRect.bottom - cellRect.bottom, closeTo(0, 0.01));
            }
            expect(
              tester.getCenter(trigger),
              cellRect.center,
              reason: 'the trigger is centred on its cell',
            );
            if (mobile) {
              // Touch Carbon floors the trigger at 48, taller than the cell,
              // so it is clipped to the cell: nothing paints over a
              // neighbouring row.
              expect(tester.getSize(trigger), const Size(48, 48));
              final clip = find.ancestor(
                of: trigger,
                matching: find.byType(ClipRect),
              );
              expect(tester.getRect(clip.first), cellRect);
            } else {
              // Compact uses Carbon's extra-small trigger, which is the cell:
              // what paints is exactly what takes the click.
              expect(tester.getSize(trigger), const Size(24, 24));
              expect(
                find.ancestor(of: trigger, matching: find.byType(ClipRect)),
                findsNothing,
              );
            }
            expect(
              AbCarbonScope.platformDensity,
              mobile ? CarbonDensity.touch : CarbonDensity.compact,
            );
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  });
}
