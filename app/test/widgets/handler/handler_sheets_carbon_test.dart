// The Handler sheets are Carbon surfaces: nothing under their scope may build
// an Ab widget, in any state, density or brightness. Each state below is the
// one most likely to have kept a stray Ab helper.
import 'dart:io';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/capability_catalog_cache.dart';
import 'package:antgrid/providers/capability_catalog.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/handler/handler_backlog_drawer.dart';
import 'package:antgrid/widgets/handler/handler_instruction_composer.dart';
import 'package:antgrid/widgets/handler/handler_judge_chip.dart';
import 'package:antgrid/widgets/handler/handler_session_settings.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/carbon_guard.dart';
import '../../helpers/fake_agent_transport.dart';
import '../../helpers/prefs_test_mock.dart';

class _SeededCatalog extends AgentCatalogNotifier {
  @override
  Map<String, AgentDescriptor> build() => {
    for (final tool in const ['claude', 'codex'])
      tool: AgentDescriptor(
        tool: tool,
        label: tool[0].toUpperCase() + tool.substring(1),
        chatCapable: true,
        judgeCapable: tool == 'claude',
        handlerTerminal: true,
        handlerChat: true,
      ),
  };
}

const _items = [
  HandlerInstructionItem(
    id: 'i1',
    text: 'run the tests',
    status: 'done',
    createdAt: 1,
  ),
  HandlerInstructionItem(
    id: 'i2',
    text: 'commit the fix',
    status: 'queued',
    createdAt: 2,
  ),
  HandlerInstructionItem(
    id: 'i3',
    text: 'open a PR',
    status: 'blocked',
    dependsOn: ['i1', 'i2'],
    createdAt: 3,
  ),
];

Future<ProjectSession> _session(List<HandlerInstructionItem> backlog) async {
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final session = ProjectSession(
    projectId: 'p',
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: await CachedSessionsStore.open(),
    onClose: () async => transport.dispose(),
  );
  addTearDown(session.close);
  transport.emit('handler:status', {
    'projectId': 'p',
    'sessions': [
      {
        'terminalId': 't1',
        'state': 'watching',
        'pendingEscalations': 0,
        'armedAt': 1,
        'goal': 'ship the fix',
        'backlog': [for (final i in backlog) i.toWire()],
      },
    ],
  });
  return session;
}

/// Wraps [home] the way the app does: the scope sits in the app builder, so
/// every modal route a sheet opens is still under it.
Widget _app(
  Widget home, {
  required Brightness brightness,
  CarbonDensity? density,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: ThemeData(brightness: brightness),
    themeAnimationDuration: Duration.zero,
    builder: (context, child) =>
        AbCarbonScope(density: density, child: child!),
    home: Scaffold(body: home),
  ),
);

void _tall(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(900, 1400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _expectClean(WidgetTester tester, String state) {
  expect(abWidgetsInScope(tester), isEmpty, reason: state);
}

void main() {
  final variants = [
    for (final b in Brightness.values)
      for (final d in CarbonDensity.values) (b, d),
  ];

  group('the backlog drawer', () {
    Future<void> pumpDrawer(
      WidgetTester tester, {
      required List<HandlerInstructionItem> backlog,
      required Brightness brightness,
      CarbonDensity? density,
      String terminalId = 't1',
    }) async {
      _tall(tester);
      final session = await _session(backlog);
      await tester.pumpWidget(
        _app(
          Center(child: HandlerBacklogDrawer(terminalId: terminalId)),
          brightness: brightness,
          density: density,
          overrides: [
            selectedRegistrationIdProvider.overrideWithValue('p'),
            projectSessionProvider('p').overrideWith((ref) => session),
            firstRunStoreProvider.overrideWithValue(
              await FirstRunStore.open(),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    for (final (b, d) in variants) {
      testWidgets('loaded, then its row menu and editor open ($b, $d)', (
        tester,
      ) async {
        await pumpDrawer(
          tester,
          backlog: _items,
          brightness: b,
          density: d,
        );
        _expectClean(tester, 'loaded');

        await tester.tap(find.byType(CarbonOverflowMenu).first);
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
        _expectClean(tester, 'row menu open');

        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        expect(find.text('Edit item'), findsOneWidget);
        _expectClean(tester, 'editor open');
      });
    }

    for (final b in Brightness.values) {
      testWidgets('empty ($b)', (tester) async {
        await pumpDrawer(tester, backlog: const [], brightness: b);
        _expectClean(tester, 'empty');
      });

      testWidgets('a terminal nothing supervises ($b)', (tester) async {
        await pumpDrawer(
          tester,
          backlog: _items,
          brightness: b,
          terminalId: 'other',
        );
        _expectClean(tester, 'unarmed');
      });
    }
  });

  group('the instruction composer', () {
    for (final (b, d) in variants) {
      testWidgets('empty and filled ($b, $d)', (tester) async {
        useInMemoryPrefs();
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _app(
            Align(
              alignment: Alignment.bottomCenter,
              child: HandlerInstructionComposer(
                terminalId: 't1',
                controller: controller,
                hintText: 'Send an instruction…',
                judge: (judgeTool: null, judgeModel: null),
                onJudgeChanged: (_) {},
                judgeScopeNote: handlerJudgeScopeNextPass,
                send: HandlerComposerSend(
                  tooltip: 'Send to Handler',
                  semanticLabel: 'Send to Handler',
                  onSend: () {},
                ),
              ),
            ),
            brightness: b,
            density: d,
            overrides: [agentCatalogProvider.overrideWith(_SeededCatalog.new)],
          ),
        );
        await tester.pumpAndSettle();
        _expectClean(tester, 'empty');

        await tester.enterText(
          find.byKey(const Key('handler-instruction-field')),
          'also update the docs',
        );
        await tester.pumpAndSettle();
        _expectClean(tester, 'filled');
      });
    }
  });

  group('the judge chip', () {
    for (final b in Brightness.values) {
      testWidgets('closed and with its menu open ($b)', (tester) async {
        useInMemoryPrefs();
        final root = Directory.systemTemp.createTempSync('ab_sheets_carbon');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
        await tester.pumpWidget(
          _app(
            Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: 320,
                child: HandlerJudgeChip(
                  terminalId: 't1',
                  judge: (judgeTool: 'claude', judgeModel: null),
                  onChanged: (_) {},
                  scopeNote: handlerJudgeScopeOnArm,
                ),
              ),
            ),
            brightness: b,
            overrides: [
              capabilityCatalogCacheProvider.overrideWithValue(
                CapabilityCatalogCache.testInstance(root: root.path),
              ),
              agentCatalogProvider.overrideWith(_SeededCatalog.new),
            ],
          ),
        );
        await tester.pumpAndSettle();
        _expectClean(tester, 'closed');

        await tester.tap(find.byType(CarbonMenuButton));
        await tester.pumpAndSettle();
        expect(find.text('Judged by'), findsOneWidget);
        _expectClean(tester, 'menu open');
      });
    }
  });

  group('the session settings', () {
    for (final (b, d) in variants) {
      testWidgets('lens tiles, own-lens panel and parked notice ($b, $d)', (
        tester,
      ) async {
        useInMemoryPrefs();
        _tall(tester);
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: HandlerSessionSettings(
                terminalId: 't1',
                value: (
                  judgeTool: 'codex',
                  judgeModel: null,
                  lens: (roleId: null, brief: 'watch the migrations'),
                ),
                onChanged: (_) {},
                appliesNextPass: true,
              ),
            ),
            brightness: b,
            density: d,
            overrides: [
              agentCatalogProvider.overrideWith(_SeededCatalog.new),
              handlerStateProvider.overrideWith(
                (ref) => Stream.value(
                  HandlerState(
                    lenses: ['pm', 'qa', 'critic', 'release'],
                    sessions: {},
                    escalations: [],
                    activity: [],
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('What Handler weighs'), findsOneWidget);
        _expectClean(tester, 'settings');
      });
    }
  });
}
