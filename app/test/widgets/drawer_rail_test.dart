// The drawer's trailing rail: every outermost glyph in the panel — dot,
// overflow menu, `+`, refresh — is centred in one column, and no row changes
// height when its actions are revealed.
//
// Horizontal assertions because the rail is a POSITION, not a widget: nothing
// in the type system connects a status dot centred in one row to a button
// centred in the next, so only a measurement can hold them together.
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/new_session_action.dart'
    show drawerProjectSessionsProvider;
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/widgets/drawer/drawer_metrics.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
import 'package:antgrid/widgets/projects_drawer.dart';

import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';

/// Holds a cached session, so its trash is withheld and the `+` is its
/// outermost action.
const _warmProjectId = 'alpha-local';
const _warmName = 'Alpha local';

/// Holds none, so it offers BOTH actions and the overflow menu is the
/// outermost one: the case that proves the rail belongs to whatever ends up
/// last.
const _bareProjectId = 'beta-local';
const _bareName = 'Beta local';

const _advertisedProjectId = 'gamma';
const _advertisedName = 'Gamma';
const _sessionName = 'Trace the reflow';

/// Carbon names an icon-only control through semantics, which `find.byTooltip`
/// cannot see, so a row's overflow trigger is found by its own label — one per
/// row, since many overflow menus share the drawer.
Finder _actionsFor(String name) => find.byWidgetPredicate(
  (w) => w is CarbonOverflowMenu && w.semanticLabel == 'Actions for $name',
  description: 'overflow menu "Actions for $name"',
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
  description: 'button "$label"',
);

/// Slack for the comparison itself, not for misalignment: a glyph that falls
/// out of its cell is several pixels out, never a hundredth.
const double _railEpsilon = 0.01;

typedef _Variant = ({String name, TargetPlatform platform, double scale});

const _variants = <_Variant>[
  (name: 'desktop @1.0', platform: TargetPlatform.windows, scale: 1.0),
  (name: 'desktop @1.3', platform: TargetPlatform.windows, scale: 1.3),
  // Touch is where a cell that forgot the full target shows: every button
  // widens to 44 while a bare dot does not.
  (name: 'mobile @1.0', platform: TargetPlatform.android, scale: 1.0),
];

AbProject _project(String id, String name) => AbProject(
  projectId: id,
  folder: '/tmp/$id',
  displayName: name,
  hostDeviceUuid: id,
  hostMachineName: '',
  lastOpenedAt: DateTime(2026, 1, 1),
);

SessionEntry _session() => SessionEntry(
  id: 'sess-1',
  name: _sessionName,
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
);

RecentAgent _machine() => RecentAgent(
  agentDeviceId: _machineUuid,
  agentLabel: 'Remote pair',
  agentEd25519Pubkey: 'pub',
  relayUrl: 'wss://relay.example.com',
  pairedAt: DateTime(2026, 1, 1),
  lastConnectedAt: DateTime(2026, 1, 2),
  hostMachineName: _machineName,
);

/// Runs [body] with [platform] in force, lifting it inside the body rather
/// than in a `tearDown`: flutter_test runs `debugAssertAllFoundationVarsUnset`
/// at the end of the test BODY, before any teardown gets a turn.
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// A viewport tall enough that the whole drawer — header, list, docked setup
/// section and pinned footer — is laid out at once. The list is a
/// [ReorderableListView]: a row scrolled out of it is never built, and a
/// finder that misses because of that would read as a missing widget.
void _useTallView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 2000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _seed(TestStoreOverrides stores) async {
  await stores.projectStore.upsert(_project(_warmProjectId, _warmName));
  await stores.projectStore.upsert(_project(_bareProjectId, _bareName));
  await stores.cachedSessionsStore.put(_warmProjectId, [_session()]);
  // Cancels the store's 200ms write debounce so no timer outlives the tree.
  await stores.cachedSessionsStore.flushNow();
  await stores.recentAgentsStore.upsert(_machine());
}

Future<void> _pumpDrawer(
  WidgetTester tester, {
  required TestStoreOverrides stores,
  double textScale = 1.0,
  List<Override> extraOverrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        ...extraOverrides,
        currentUserProvider.overrideWith((_) async => null),
        accountAgentsProvider.overrideWith((_) async => const []),
        for (final id in const [_warmProjectId, _bareProjectId, _machineUuid])
          projectStatusProvider(
            id,
          ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
        // Both bands render their liveness dot only when there is something to
        // report, and that dot is the resting tenant of the rail cell.
        hostStatusProvider.overrideWith(
          (_) => Stream.value(const HostStatus(HostPhase.up)),
        ),
        supervisorStatusProvider(
          _machineUuid,
        ).overrideWith((_) => Stream.value(const Connected())),
        controlPlaneStateProvider(_machineUuid).overrideWith(
          (_) => Stream.value(
            const ControlPlaneState(
              projects: [
                AdvertisedProject(
                  projectId: _advertisedProjectId,
                  label: _advertisedName,
                  path: '/gamma',
                  running: true,
                ),
              ],
            ),
          ),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const Scaffold(body: ProjectsDrawer()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // A machine's advertised projects exist only once its band is open.
  await tester.tap(find.text(_machineName));
  await tester.pumpAndSettle();
}

/// The drawer's own row shell around [label]: a link or a menu header.
Finder _row(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (w) => w is CarbonSideNavLink || w is CarbonSideNavMenu,
      ),
    )
    .first;

Finder _within(Finder row, Finder glyph) =>
    find.descendant(of: row, matching: glyph);

/// Whether [glyph] is both built and painted. Carbon keeps a row's hidden
/// actions mounted under `Visibility`, so presence alone proves nothing.
bool _shown(WidgetTester tester, Finder glyph) {
  if (glyph.evaluate().isEmpty) return false;
  final gate = tester.element(glyph.first).findAncestorWidgetOfExactType<Visibility>();
  return gate?.visible ?? true;
}

/// Where the rail's glyph centres sit, derived from the panel's own edge and
/// the metrics every row shares rather than read off another row.
double _expectedRailX(WidgetTester tester) {
  final t = CarbonTheme.of(tester.element(find.byType(CarbonSideNav)));
  final panelRight = tester.getRect(find.byType(ProjectsDrawer)).right;
  return panelRight - 1 - kDrawerRailInset - drawerRailCell(t) / 2;
}

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

  group('the trailing rail', () {
    for (final v in _variants) {
      testWidgets('${v.name}: the resting glyphs share the column', (
        tester,
      ) async {
        await _onPlatform(v.platform, () async {
          _useTallView(tester);
          await _seed(stores);
          await _pumpDrawer(tester, stores: stores, textScale: v.scale);

          final rail = _expectedRailX(tester);
          expect(
            tester.getCenter(_button('Refresh')).dx,
            closeTo(rail, _railEpsilon),
            reason: 'the Projects header refresh is off the rail',
          );

          final hostDot = _within(
            find.byType(LocalMachineBand),
            find.byType(CarbonStatusDot),
          );
          expect(hostDot, findsOneWidget);
          expect(
            tester.getCenter(hostDot).dx,
            closeTo(rail, _railEpsilon),
            reason: "the local band's host dot is off the rail",
          );

          final bandDot = _within(
            _row(_machineName),
            find.byType(CarbonStatusDot),
          );
          expect(bandDot, findsOneWidget);
          final bandMenu = _within(_row(_machineName), _actionsFor(_machineName));
          expect(bandMenu, findsOneWidget);
          if (v.platform == TargetPlatform.android) {
            // Touch shows the menu permanently and it owns the terminal cell,
            // so the resting dot sits one cell inboard of the rail.
            expect(
              tester.getCenter(bandDot).dx,
              lessThan(tester.getCenter(bandMenu).dx),
              reason: "the machine band's dot must sit inboard of its menu",
            );
          } else {
            expect(
              tester.getCenter(bandDot).dx,
              closeTo(rail, _railEpsilon),
              reason: "the machine band's liveness dot is off the rail",
            );
          }
          expect(
            tester.getCenter(bandMenu).dx,
            closeTo(rail, _railEpsilon),
            reason: "the machine band's terminal cell is off the rail",
          );

          await tester.pumpWidget(const SizedBox());
        });
      });

      for (final target in <({
        String name,
        String hoverLabel,
        Finder Function() glyph,
      })>[
        (
          name: "a local project row's outermost action",
          hoverLabel: _bareName,
          glyph: () => _within(_row(_bareName), _actionsFor(_bareName)),
        ),
        (
          // It has no remove menu, so Memory ends the row.
          name: "an advertised project row's outermost action",
          hoverLabel: _advertisedName,
          glyph: () => _within(
            _row(_advertisedName),
            _button('$_advertisedName memories'),
          ),
        ),
        (
          name: "a session row's overflow menu",
          hoverLabel: _sessionName,
          glyph: () => _actionsFor(_sessionName),
        ),
      ]) {
        testWidgets('${v.name}: ${target.name} lands on the rail', (
          tester,
        ) async {
          await _onPlatform(v.platform, () async {
            _useTallView(tester);
            await _seed(stores);
            await _pumpDrawer(tester, stores: stores, textScale: v.scale);

            final rail = _expectedRailX(tester);
            // Deliberately not settled: a hovered project row arms a 300ms
            // session prefetch, and advancing the clock past it would build a
            // real ProjectSession.
            await hoverRow(tester, find.text(target.hoverLabel));

            final glyph = target.glyph();
            expect(
              _shown(tester, glyph),
              isTrue,
              reason: 'hovering ${target.hoverLabel} must reveal its action',
            );
            expect(
              tester.getCenter(glyph).dx,
              closeTo(rail, _railEpsilon),
              reason: '${target.name} is off the rail',
            );

            await tester.pumpWidget(const SizedBox());
          });
        });
      }
    }
  });

  group('rail targets', () {
    for (final mobile in [true, false]) {
      final platform = mobile ? TargetPlatform.android : TargetPlatform.windows;

      testWidgets(
        '${mobile ? 'mobile' : 'desktop'}: the + and the overflow menu '
        '${mobile ? 'are 44x44 targets inside their row' : 'stay compact'}',
        (tester) async {
          await _onPlatform(platform, () async {
            _useTallView(tester);
            await _seed(stores);
            await _pumpDrawer(tester, stores: stores);

            await hoverRow(tester, find.text(_bareName));
            final bare = _row(_bareName);
            final plus = _within(bare, _button('New session'));
            final menu = _within(bare, _actionsFor(_bareName));
            expect(plus, findsOneWidget);
            expect(menu, findsOneWidget);
            final plusRect = tester.getRect(plus);
            final menuRect = tester.getRect(menu);
            final rowRect = tester.getRect(bare);
            final t = CarbonTheme.of(tester.element(bare));
            if (mobile) {
              expect(plusRect.size, const Size(44, 44));
              expect(menuRect.size, const Size(44, 44));
              expect(plusRect.right, lessThanOrEqualTo(menuRect.left + 0.01));
              expect(plusRect.top, greaterThanOrEqualTo(rowRect.top - 0.01));
              expect(plusRect.bottom, lessThanOrEqualTo(rowRect.bottom + 0.01));
            } else {
              expect(plusRect.height, drawerRailCell(t));
              expect(menuRect.height, drawerRailCell(t));
              expect(plusRect.height, lessThan(44));
            }
            await tester.pumpWidget(const SizedBox());
          });
        },
      );

      testWidgets(
        '${mobile ? 'mobile' : 'desktop'}: the session overflow menu '
        '${mobile ? 'is a 44x44 target on the rail' : 'stays compact'}',
        (tester) async {
          await _onPlatform(platform, () async {
            _useTallView(tester);
            await _seed(stores);
            await _pumpDrawer(tester, stores: stores);

            final rail = _expectedRailX(tester);
            await hoverRow(tester, find.text(_sessionName));
            final menu = _actionsFor(_sessionName);
            expect(menu, findsOneWidget);
            final menuRect = tester.getRect(menu);
            final rowRect = tester.getRect(
              find
                  .ancestor(
                    of: find.text(_sessionName),
                    matching: find.byType(CarbonSideNavLink),
                  )
                  .first,
            );
            if (mobile) {
              expect(menuRect.size, const Size(44, 44));
              expect(menuRect.top, greaterThanOrEqualTo(rowRect.top - 0.01));
              expect(menuRect.bottom, lessThanOrEqualTo(rowRect.bottom + 0.01));
              expect(menuRect.center.dx, closeTo(rail, _railEpsilon));
            } else {
              expect(
                menuRect.height,
                drawerRailCell(CarbonTheme.of(tester.element(menu))),
              );
              expect(menuRect.height, lessThan(44));
            }
            await tester.pumpWidget(const SizedBox());
          });
        },
      );
    }
  });

  group('no vertical jitter', () {
    for (final scale in const [1.0, 1.3]) {
      for (final target in <({
        String name,
        String label,
        Finder Function() action,
      })>[
        (
          name: 'a local project row holding sessions',
          label: _warmName,
          action: () => _within(_row(_warmName), _button('New session')),
        ),
        (
          name: 'a local project row holding none',
          label: _bareName,
          action: () => _within(_row(_bareName), _actionsFor(_bareName)),
        ),
        (
          name: 'a machine band',
          label: _machineName,
          action: () => _within(_row(_machineName), _actionsFor(_machineName)),
        ),
        (
          name: 'an advertised project row',
          label: _advertisedName,
          action: () => _within(_row(_advertisedName), _button('New session')),
        ),
      ]) {
        testWidgets(
          '${target.name} keeps its height on hover, scale $scale',
          (tester) async {
            await _onPlatform(TargetPlatform.windows, () async {
              _useTallView(tester);
              await _seed(stores);
              await _pumpDrawer(tester, stores: stores, textScale: scale);

              final resting = tester.getSize(_row(target.label)).height;
              expect(
                _shown(tester, target.action()),
                isFalse,
                reason:
                    '${target.name} must hide its action at rest, or this '
                    'measures nothing',
              );

              await hoverRow(tester, find.text(target.label));

              expect(
                _shown(tester, target.action()),
                isTrue,
                reason: "hover must reveal ${target.name}'s action",
              );
              expect(
                tester.getSize(_row(target.label)).height,
                resting,
                reason:
                    '${target.name} grew on pointer-enter, shoving every row '
                    'below it down',
              );

              await tester.pumpWidget(const SizedBox());
            });
          },
        );
      }
    }
  });

  testWidgets('keyboard focus reveals the actions a pointer would', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.windows, () async {
      final entry = LocalProjectEntry(_project(_bareProjectId, _bareName));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            projectStatusProvider(
              _bareProjectId,
            ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AbCarbonScope(child: DrawerEntryRow(entry)),
            ),
          ),
        ),
      );
      await tester.pump();

      final menu = _actionsFor(_bareName);
      final newSession = _button('New session');
      expect(_shown(tester, menu), isFalse);
      expect(_shown(tester, newSession), isFalse);

      // Tab rather than a direct focus request: the reveal hangs off the focus
      // HIGHLIGHT, which only a traversal or a key press turns on.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        _shown(tester, menu),
        isTrue,
        reason:
            'a hidden action a pointer alone can summon is unreachable '
            'without a mouse',
      );
      expect(_shown(tester, newSession), isTrue);

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the Projects header refresh is a 44x44 target on mobile', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.android, () async {
      _useTallView(tester);
      await _seed(stores);
      await _pumpDrawer(tester, stores: stores);

      expect(tester.getSize(_button('Refresh')), const Size(44, 44));

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the Projects header refresh keeps its compact target on desktop', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.windows, () async {
      _useTallView(tester);
      await _seed(stores);
      await _pumpDrawer(tester, stores: stores);

      expect(tester.getSize(_button('Refresh')).height, lessThan(44));

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('mobile keeps the band liveness dot beside its overflow menu', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.android, () async {
      _useTallView(tester);
      await _seed(stores);
      await _pumpDrawer(tester, stores: stores);

      final band = _row(_machineName);
      final dot = _within(band, find.byType(CarbonStatusDot));
      final menu = _within(band, _actionsFor(_machineName));

      // Asserted on the dot's presence, not on the width of a slot: the slot is
      // reserved either way, so measuring it would pass with nothing in it.
      expect(
        dot,
        findsOneWidget,
        reason:
            'touch shows the menu permanently, and a swap would hide the '
            "machine's only liveness report forever",
      );
      expect(menu, findsOneWidget);
      expect(
        tester.getCenter(menu).dx,
        closeTo(_expectedRailX(tester), _railEpsilon),
        reason: 'the action, not the dot, owns the terminal cell on touch',
      );
      expect(
        tester.getCenter(dot).dx,
        lessThan(tester.getCenter(menu).dx),
        reason: 'the resting dot sits inboard of the cell it cannot share',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a revealed action outlives the hover its own modal ends', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.macOS, () async {
      _useTallView(tester);
      await _seed(stores);
      await _pumpDrawer(tester, stores: stores);

      final menu = _within(_row(_bareName), _actionsFor(_bareName));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(_row(_bareName)));
      await tester.pump();
      expect(_shown(tester, menu), isTrue);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from history'));
      await tester.pumpAndSettle();
      // The modal covers the row, so the pointer has already left it; moving
      // the mouse away only makes that explicit.
      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();

      expect(
        _shown(tester, menu),
        isTrue,
        reason:
            'the row must not hide its actions out from under a dialog one of '
            'them opened',
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // Cancel hands focus back to the trigger and focus-within keeps a row
      // revealed on purpose; blur it so only the modal latch is under test.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(
        _shown(tester, menu),
        isFalse,
        reason: 'and the latch must release once the dialog is answered',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('row height', () {
    for (final mobile in [true, false]) {
      final platform = mobile ? TargetPlatform.android : TargetPlatform.windows;

      testWidgets(
        '${mobile ? 'mobile' : 'desktop'}: every row is at least one target '
        'tall and the rows pitch evenly',
        (tester) async {
          await _onPlatform(platform, () async {
            _useTallView(tester);
            await _seed(stores);
            await _pumpDrawer(tester, stores: stores);

            final t = CarbonTheme.of(tester.element(find.byType(CarbonSideNav)));
            final rows = <String, Finder>{
              'band': _row(_machineName),
              'local band': _row('This machine'),
              'project': _row(_warmName),
              'bare project': _row(_bareName),
              'advertised': _row(_advertisedName),
              'session': _row(_sessionName),
            };
            for (final e in rows.entries) {
              final height = tester.getSize(e.value).height;
              expect(
                height,
                greaterThanOrEqualTo(t.minTarget),
                reason: '${e.key} row is under one target tall',
              );
              if (mobile) {
                expect(height, greaterThanOrEqualTo(44), reason: e.key);
              } else {
                expect(height, 32, reason: '${e.key} compact desktop row');
              }
            }

            expect(
              tester.getSize(rows['local band']!).height,
              tester.getSize(rows['band']!).height,
              reason: 'the local and remote bands measure the same',
            );

            // A machine's advertised project sits directly under its band, so
            // the distance between their tops is one band-row height.
            final bandTop = tester.getTopLeft(rows['band']!).dy;
            final advertisedTop = tester.getTopLeft(rows['advertised']!).dy;
            expect(
              advertisedTop - bandTop,
              closeTo(tester.getSize(rows['band']!).height, 1),
            );

            await tester.pumpWidget(const SizedBox());
          });
        },
      );

      testWidgets(
        '${mobile ? 'mobile' : 'desktop'}: the retry control is '
        '${mobile ? 'a 44 target' : 'present'}',
        (tester) async {
          await _onPlatform(platform, () async {
            _useTallView(tester);
            await _seed(stores);
            await _pumpDrawer(
              tester,
              stores: stores,
              extraOverrides: [
                drawerProjectSessionsProvider(
                  '$_machineUuid.$_advertisedProjectId',
                ).overrideWith((_) async => throw StateError('offline')),
              ],
            );
            await tester.tap(find.text(_advertisedName));
            await tester.pumpAndSettle();

            expect(find.text('Could not load sessions'), findsOneWidget);
            final retry = find.descendant(
              of: find.byType(CarbonInlineLoading),
              matching: find.byType(CarbonButton),
            );
            expect(retry, findsOneWidget);
            if (mobile) {
              expect(
                tester.getSize(retry).height,
                greaterThanOrEqualTo(44),
              );
            }
            await tester.pumpWidget(const SizedBox());
          });
        },
      );
    }
  });
}
