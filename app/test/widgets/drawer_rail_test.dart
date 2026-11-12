// The drawer's trailing rail: every outermost glyph in the panel — dot,
// trash, kebab, `+`, refresh — sits in one column, and no row changes height
// when its actions are revealed.
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
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
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
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/session_row.dart';

import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';

/// Holds a cached session, so its trash is withheld and the `+` is its
/// outermost action.
const _warmProjectId = 'alpha-local';
const _warmName = 'Alpha local';

/// Holds none, so it offers BOTH actions and the trash is the outermost one —
/// the case that proves the rail belongs to whatever ends up last.
const _bareProjectId = 'beta-local';
const _bareName = 'Beta local';

const _advertisedProjectId = 'gamma';
const _advertisedName = 'Gamma';
const _sessionName = 'Trace the reflow';

const _newSessionTip = 'New session';
const _kebabTip = 'Session actions';

/// A row's Remove/Forget trigger. Carbon names an icon-only control through
/// semantics, which `find.byTooltip` cannot see, so it is found by its own
/// label — one per row, since many overflow menus share the drawer.
Finder _actionsFor(String name) => find.byWidgetPredicate(
  (w) => w is CarbonOverflowMenu && w.semanticLabel == 'Actions for $name',
  description: 'overflow menu "Actions for $name"',
);

/// Slack for the comparison itself, not for misalignment: the defect this
/// suite exists to catch moves a glyph by ~9px, and a 24px button beside a 6px
/// dot is 9px out the moment either stops being centred in its own cell.
const double _railEpsilon = 0.01;

typedef _Variant = ({String name, TargetPlatform platform, double scale});

const _variants = <_Variant>[
  (name: 'desktop @1.0', platform: TargetPlatform.windows, scale: 1.0),
  (name: 'desktop @1.3', platform: TargetPlatform.windows, scale: 1.3),
  // Touch is where a cell that forgot [AbTokens.tapTargetMin] shows: every
  // button widens to 44 while a bare dot does not.
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
        // Both bands render their liveness glyph only when there is something
        // to report, and that glyph is the resting tenant of the rail cell.
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

/// The [HoverableDrawerRow] wrapping the row labelled [label] — the shell
/// every project row and machine band is built inside.
Finder _row(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(HoverableDrawerRow),
);

Finder _entryRow(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(DrawerEntryRow));

/// The band itself, excluding the hairline a [HoverableDrawerRow] carries above
/// it — that rule belongs to the block, not to the row's own metrics.
Finder _band(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(DrawerBand));

Finder _within(Finder row, Finder glyph) =>
    find.descendant(of: row, matching: glyph);

/// The rail's x, read off the one element that is on it without a pointer or a
/// row around it. Every case compares against this rather than against each
/// other, because flutter_test's mouse is a single device — two hovers in one
/// test assert — and equality against a shared reference is transitive
/// anyway.
double _railX(WidgetTester tester) {
  final refresh = find.byTooltip('Refresh');
  expect(
    refresh,
    findsOneWidget,
    reason: 'the PROJECTS header refresh is the rail reference',
  );
  return tester.getCenter(refresh).dx;
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

          final rail = _railX(tester);

          final hostDot = _within(
            find.byType(LocalMachineBand),
            find.byType(AbStatusDot),
          );
          expect(hostDot, findsOneWidget);
          expect(
            tester.getCenter(hostDot).dx,
            closeTo(rail, _railEpsilon),
            reason:
                "LocalMachineBand's host dot is off the rail the PROJECTS "
                'refresh sits on',
          );

          final bandTrash = _within(
            _row(_machineName),
            _actionsFor(_machineName),
          );
          expect(bandTrash, findsOneWidget);
          expect(
            tester.getCenter(bandTrash).dx,
            closeTo(rail, _railEpsilon),
            reason: "the machine band's terminal cell is off the rail",
          );

          if (v.platform != TargetPlatform.android) {
            // Desktop puts both of a band's tenants in the SAME cell, so the
            // liveness dot answers for the rail exactly as the trash does.
            // Touch renders them side by side instead — see the mobile case.
            final bandDot = _within(
              _row(_machineName),
              find.byType(AbStatusDot),
            );
            expect(bandDot, findsOneWidget);
            expect(
              tester.getCenter(bandDot).dx,
              closeTo(rail, _railEpsilon),
              reason:
                  "the band's liveness dot and its trash do not share a cell",
            );
          }

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
          glyph: () =>
              _within(_entryRow(_bareName), _actionsFor(_bareName)),
        ),
        (
          name: "an advertised project row's +",
          hoverLabel: _advertisedName,
          glyph: () =>
              _within(_row(_advertisedName), find.byTooltip(_newSessionTip)),
        ),
        (
          name: "a session row's kebab",
          hoverLabel: _sessionName,
          glyph: () =>
              _within(find.byType(SessionRow), find.byTooltip(_kebabTip)),
        ),
      ]) {
        testWidgets('${v.name}: ${target.name} lands on the rail', (
          tester,
        ) async {
          await _onPlatform(v.platform, () async {
            _useTallView(tester);
            await _seed(stores);
            await _pumpDrawer(tester, stores: stores, textScale: v.scale);

            final rail = _railX(tester);
            // Deliberately not settled: a hovered project row arms a 300ms
            // session prefetch, and advancing the clock past it would build a
            // real ProjectSession.
            await hoverRow(tester, find.text(target.hoverLabel));

            final glyph = target.glyph();
            expect(
              glyph,
              findsOneWidget,
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

  group('no vertical jitter', () {
    for (final scale in const [1.0, 1.3]) {
      for (final target in <({
        String name,
        String label,
        Finder Function() row,
        Finder Function() action,
        bool collapsedAtRest,
      })>[
        (
          name: 'a local project row holding sessions',
          label: _warmName,
          row: () => _entryRow(_warmName),
          action: () =>
              _within(_entryRow(_warmName), find.byTooltip(_newSessionTip)),
          collapsedAtRest: true,
        ),
        (
          name: 'a local project row holding none',
          label: _bareName,
          row: () => _entryRow(_bareName),
          action: () =>
              _within(_entryRow(_bareName), _actionsFor(_bareName)),
          collapsedAtRest: true,
        ),
        (
          name: 'a machine band',
          label: _machineName,
          row: () => _band(_machineName),
          action: () => _within(_row(_machineName), _actionsFor(_machineName)),
          // A band swaps its cell's tenant instead of collapsing it, so the
          // trash is laid out at rest and only fades in.
          collapsedAtRest: false,
        ),
        (
          name: 'an advertised project row',
          label: _advertisedName,
          row: () => _row(_advertisedName),
          action: () =>
              _within(_row(_advertisedName), find.byTooltip(_newSessionTip)),
          collapsedAtRest: true,
        ),
      ]) {
        testWidgets(
          '${target.name} keeps its height on hover, scale $scale',
          (tester) async {
            await _onPlatform(TargetPlatform.windows, () async {
              _useTallView(tester);
              await _seed(stores);
              await _pumpDrawer(tester, stores: stores, textScale: scale);

              final resting = tester.getSize(target.row()).height;
              if (target.collapsedAtRest) {
                expect(
                  target.action(),
                  findsNothing,
                  reason:
                      '${target.name} must drop its action at rest, or this '
                      'measures nothing',
                );
              }

              await hoverRow(tester, find.text(target.label));

              expect(
                target.action(),
                findsOneWidget,
                reason: "hover must reveal ${target.name}'s action",
              );
              expect(
                tester.getSize(target.row()).height,
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

  group('band metrics', () {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('both bands measure the same at scale $scale', (
        tester,
      ) async {
        await _onPlatform(TargetPlatform.windows, () async {
          _useTallView(tester);
          await _seed(stores);
          await _pumpDrawer(tester, stores: stores, textScale: scale);

          final local = _band('This machine');
          final machine = _band(_machineName);
          expect(local, findsOneWidget);
          expect(machine, findsOneWidget);

          final localHeight = tester.getSize(local).height;
          expect(
            tester.getSize(machine).height,
            localHeight,
            reason:
                'the two bands sit in one run and must read as one row class',
          );
          // Pinned to the floor's own arithmetic rather than to a literal: the
          // content floor scales, the padding and margin do not.
          expect(
            localHeight,
            closeTo(
              AbIconButton.boxExtent(tester.element(local)) +
                  2 * AbTokens.space6 +
                  2 * AbTokens.space2,
              _railEpsilon,
            ),
            reason: 'a band is content floor + row padding + row margin',
          );

          await tester.pumpWidget(const SizedBox());
        });
      });
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
          child: MaterialApp(home: Scaffold(body: DrawerEntryRow(entry))),
        ),
      );
      await tester.pump();

      final trash = _actionsFor(_bareName);
      final newSession = find.byTooltip(_newSessionTip);
      expect(trash, findsNothing);
      expect(newSession, findsNothing);

      // Tab rather than a direct focus request: the reveal hangs off the focus
      // HIGHLIGHT, which only a traversal or a key press turns on.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        trash,
        findsOneWidget,
        reason:
            'a collapsed action a pointer alone can summon is unreachable '
            'without a mouse',
      );
      expect(newSession, findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('mobile keeps the band liveness dot beside its revealed trash', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.android, () async {
      _useTallView(tester);
      await _seed(stores);
      await _pumpDrawer(tester, stores: stores);

      final band = _row(_machineName);
      final dot = _within(band, find.byType(AbStatusDot));
      final trash = _within(band, _actionsFor(_machineName));

      // Asserted on the dot's presence, not on the width of a slot: the slot is
      // reserved either way, so measuring it would pass with nothing in it.
      expect(
        dot,
        findsOneWidget,
        reason:
            'touch reveals the trash permanently, and a swap would hide the '
            "machine's only liveness report forever",
      );
      expect(trash, findsOneWidget);
      expect(
        tester.getCenter(trash).dx,
        closeTo(_railX(tester), _railEpsilon),
        reason: 'the action, not the dot, owns the terminal cell on touch',
      );
      expect(
        tester.getCenter(dot).dx,
        lessThan(tester.getCenter(trash).dx),
        reason: 'the resting glyph sits inboard of the cell it cannot share',
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

      final trash = _within(_entryRow(_bareName), _actionsFor(_bareName));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(_entryRow(_bareName)));
      await tester.pump();
      expect(trash, findsOneWidget);

      await tester.tap(trash);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from history'));
      await tester.pumpAndSettle();
      // The modal covers the row, so the pointer has already left it; moving
      // the mouse away only makes that explicit.
      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();

      expect(
        trash,
        findsOneWidget,
        reason:
            'the row must not collapse its actions out from under a dialog '
            "one of them opened — the button's own in-flight state goes with "
            'it',
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        trash,
        findsNothing,
        reason: 'and the latch must release once the dialog is answered',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('row height', () {
    Finder rowBox(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(AbListRow))
        .first;

    // Today's tappable height: the icon-button box plus the sm padding on each
    // side. A phone row may exceed it but never fall under it.
    double legacyHeight(double scale) => 24 * scale + 12;

    for (final mobile in [true, false]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        testWidgets(
          '${mobile ? 'mobile' : 'desktop'} @$scale: tappable height and pitch',
          (tester) async {
            await _onPlatform(
              mobile ? TargetPlatform.android : TargetPlatform.windows,
              () async {
                _useTallView(tester);
                await _seed(stores);
                await _pumpDrawer(tester, stores: stores, textScale: scale);

                final legacy = legacyHeight(scale);
                final expected = mobile ? (legacy > 44.0 ? legacy : 44.0) : legacy;
                final rows = <String, Finder>{
                  'band': rowBox(_machineName),
                  'project': rowBox(_warmName),
                  'bare project': rowBox(_bareName),
                  'advertised': rowBox(_advertisedName),
                };
                for (final e in rows.entries) {
                  expect(
                    // The row's box includes its 2+2 vertical margin.
                    tester.getSize(e.value).height - 4,
                    closeTo(expected, 0.01),
                    reason: '${e.key} row height',
                  );
                }
                // Session rows carry their own 1px padding and margin.
                final sessionLegacy = 24 * scale + 2;
                final sessionExpected = mobile
                    ? (sessionLegacy > 44.0 ? sessionLegacy : 44.0)
                    : sessionLegacy;
                expect(
                  tester
                      .getSize(
                        find
                            .descendant(
                              of: find.byType(SessionRow),
                              matching: find.byType(AbListRow),
                            )
                            .first,
                      )
                      .height - 2, // its 1+1 vertical margin
                  closeTo(sessionExpected, 0.01),
                  reason: 'session row height',
                );
                if (scale == 1.0) {
                  expect(expected, mobile ? 44.0 : 36.0);
                }

                // A machine's advertised project sits directly under its
                // band, so the distance between their tops is the pitch a
                // list sees: tappable height + the 2+2 margin.
                final bandTop = tester.getTopLeft(rowBox(_machineName)).dy;
                final advertisedTop = tester
                    .getTopLeft(rowBox(_advertisedName))
                    .dy;
                expect(advertisedTop - bandTop, closeTo(expected + 4, 0.01));

                await tester.pumpWidget(const SizedBox());
              },
            );
          },
        );
      }

      testWidgets(
        '${mobile ? 'mobile' : 'desktop'}: the rail x is where the gutter '
        'and the cell footprint put it',
        (tester) async {
          await _onPlatform(
            mobile ? TargetPlatform.android : TargetPlatform.windows,
            () async {
              _useTallView(tester);
              await _seed(stores);
              await _pumpDrawer(tester, stores: stores);

              final context = tester.element(find.byType(ProjectsDrawer));
              final drawerRight = tester
                  .getRect(find.byType(ProjectsDrawer))
                  .right;
              final expectedX =
                  drawerRight -
                  1 - // the drawer's own right border
                  AbTokens.drawerGutter -
                  AbIconButton.footprintWidth(context) / 2;
              expect(_railX(tester), closeTo(expectedX, _railEpsilon));

              await hoverRow(tester, find.text(_bareName));
              expect(
                tester.getCenter(_actionsFor(_bareName)).dx,
                closeTo(expectedX, _railEpsilon),
              );
              await tester.pumpWidget(const SizedBox());
            },
          );
        },
      );
    }

    for (final mobile in [true, false]) {
      testWidgets(
        '${mobile ? 'mobile' : 'desktop'}: the retry hint is '
        '${mobile ? 'a 44 target' : 'unchanged'}',
        (tester) async {
          await _onPlatform(
            mobile ? TargetPlatform.android : TargetPlatform.windows,
            () async {
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

              final hint = find.ancestor(
                of: find.text('Could not load sessions — tap to retry.'),
                matching: find.byType(GestureDetector),
              );
              // The drawer is narrow enough to wrap the sentence, so height
              // alone could pass without the floor: assert the floor itself.
              final floors = find.descendant(
                of: hint.first,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is ConstrainedBox &&
                      w.constraints.minHeight == AbTokens.rowHeightLg,
                ),
              );
              if (mobile) {
                expect(floors, findsOneWidget);
                expect(
                  tester.getSize(hint.first).height,
                  greaterThanOrEqualTo(AbTokens.rowHeightLg),
                );
              } else {
                expect(floors, findsNothing);
              }
              await tester.pumpWidget(const SizedBox());
            },
          );
        },
      );
    }
  });
}
