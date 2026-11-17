// The compound judge+model picker and the menu behind it. What matters here is
// what a screenshot cannot show: that a judge pick takes the model with it, that
// the model submenu is the same shape for every agent, that a model nobody has
// listed can still be typed, and that a catalog still on disk is loaded before
// the menu can show its absence.
import 'dart:io';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/models/capability_catalog.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/capability_catalog.dart';
import 'package:antgrid/services/capability_catalog_cache.dart';
import 'package:antgrid/widgets/handler/handler_judge_chip.dart';
import 'package:antgrid/widgets/handler/handler_session_settings.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

/// The bridge is authoritative for what an agent is called and what it can do,
/// so the picker has nothing to list until an advert has landed.
class _SeededCatalog extends AgentCatalogNotifier {
  _SeededCatalog(this.seed);

  final Map<String, AgentDescriptor> seed;

  @override
  Map<String, AgentDescriptor> build() => seed;
}

AgentDescriptor _descriptor(String tool, {bool judgeCapable = true}) =>
    AgentDescriptor(
      tool: tool,
      label: tool[0].toUpperCase() + tool.substring(1),
      chatCapable: true,
      judgeCapable: judgeCapable,
      handlerTerminal: true,
      handlerChat: true,
    );

/// `claude` is the tool with a catalog; `codex` deliberately has none, which is
/// the free-text branch a machine that has only run it in a terminal gets.
const _claudeModels = CapabilityCatalog(
  models: [
    AgentCapabilityModel(id: 'opus-4', name: 'Opus'),
    AgentCapabilityModel(id: 'sonnet-4', name: 'Sonnet'),
    AgentCapabilityModel(id: 'haiku-4', name: 'Haiku'),
  ],
);

/// The disk cache is rooted in a temp dir rather than left at its default:
/// `remember` writes fire-and-forget, and an unresolvable app-support directory
/// would surface as an unhandled async error rather than a swallowed one.
ProviderContainer _container({
  Map<String, AgentDescriptor>? catalog,
  bool seedModels = true,
  Directory? diskRoot,
}) {
  useInMemoryPrefs();
  final root = diskRoot ?? Directory.systemTemp.createTempSync('ab_judge_chip');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final container = ProviderContainer(
    overrides: [
      capabilityCatalogCacheProvider.overrideWithValue(
        CapabilityCatalogCache.testInstance(root: root.path),
      ),
      agentCatalogProvider.overrideWith(
        () => _SeededCatalog(
          catalog ??
              {'claude': _descriptor('claude'), 'codex': _descriptor('codex')},
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  if (seedModels) {
    container
        .read(capabilityCatalogProvider.notifier)
        .remember(capabilityCacheKey('local', 'claude'), _claudeModels);
  }
  return container;
}

/// Bottom-aligned because the composer's control row sits low on its surface
/// and the menu opens upward from it.
Widget _chipApp(
  ProviderContainer container, {
  required HandlerJudgePick judge,
  ValueChanged<HandlerJudgePick>? onChanged,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildAbTheme(),
    themeAnimationDuration: Duration.zero,
    home: Scaffold(
      body: AbCarbonScope(
        child: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(
            width: 320,
            child: HandlerJudgeChip(
              terminalId: 't1',
              judge: judge,
              onChanged: onChanged ?? (_) {},
              scopeNote: handlerJudgeScopeOnArm,
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<ProviderContainer> _pumpChip(
  WidgetTester tester, {
  required HandlerJudgePick judge,
  bool seedModels = true,
  Map<String, AgentDescriptor>? catalog,
  ValueChanged<HandlerJudgePick>? onChanged,
  Directory? diskRoot,
}) async {
  final container = _container(
    catalog: catalog,
    seedModels: seedModels,
    diskRoot: diskRoot,
  );
  await tester.pumpWidget(
    _chipApp(container, judge: judge, onChanged: onChanged),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byType(CarbonMenuButton));
  await tester.pumpAndSettle();
}

Future<void> _openModelSubmenu(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.tap(find.text('Model'));
  await tester.pumpAndSettle();
}

void main() {
  group('the trigger label', () {
    testWidgets('names the judge, then the model that qualifies it', (
      tester,
    ) async {
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: 'opus-4'),
      );

      // The catalog's display name, not the id: the id is what goes on the
      // wire, and the trigger is the one place a model is read rather than
      // sent. One label, so a model can never stand without its judge.
      expect(find.text('Claude · Opus'), findsOneWidget);
    });

    testWidgets('falls back to the raw id for a model nobody has listed', (
      tester,
    ) async {
      // A model typed into the free-text branch is never in a catalog, and
      // showing it back is the only confirmation the user gets that it stuck.
      await _pumpChip(
        tester,
        judge: (judgeTool: 'codex', judgeModel: 'o4-mini'),
      );

      expect(find.text('Codex · o4-mini'), findsOneWidget);
    });

    testWidgets('with nothing to qualify it, the judge stands alone', (
      tester,
    ) async {
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));

      expect(find.text('Claude'), findsOneWidget);
      expect(find.textContaining('Opus'), findsNothing);
    });
  });

  group('the judge group', () {
    testWidgets('offers Default plus every judge-capable tool', (tester) async {
      await _pumpChip(
        tester,
        judge: (judgeTool: null, judgeModel: null),
        catalog: {
          'claude': _descriptor('claude'),
          'codex': _descriptor('codex'),
          // Cannot run headless, so it can never be the judge.
          'aider': _descriptor('aider', judgeCapable: false),
        },
      );
      await _openMenu(tester);

      expect(find.text('Judged by'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Aider'), findsNothing);
      // Scope is stated where the pick is made — the same control means "from
      // the moment it arms" on one host and "next pass" on the other.
      expect(find.text(handlerJudgeScopeOnArm), findsOneWidget);
    });

    testWidgets('picking a judge clears the model', (tester) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: 'opus-4'),
        onChanged: picks.add,
      );
      await _openMenu(tester);
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();

      expect(picks.single.judgeTool, 'codex');
      // A model id is a name only its own CLI answers to: carried across, it
      // becomes a flag the new judge rejects on every pass.
      expect(picks.single.judgeModel, isNull);
    });

    testWidgets('re-picking the judge already in force is not an edit', (
      tester,
    ) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: 'opus-4'),
        onChanged: picks.add,
      );
      await _openMenu(tester);
      // The radio group never reports the selected option; the delta would
      // otherwise read `judgeModel: null` as "clear it".
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();

      expect(picks, isEmpty);
    });
  });

  group('the model submenu', () {
    testWidgets('is always a submenu, even for a three-model agent', (
      tester,
    ) async {
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));
      await _openMenu(tester);

      // Not listed inline under the judges: a menu that changes shape per agent
      // is one the user relearns per agent.
      expect(find.text('Sonnet'), findsNothing);

      await tester.tap(find.text('Model'));
      await tester.pumpAndSettle();

      expect(find.text('Opus'), findsOneWidget);
      expect(find.text('Sonnet'), findsOneWidget);
      expect(find.text('Haiku'), findsOneWidget);
      expect(find.text('Type a model id…'), findsOneWidget);
    });

    testWidgets('picking a model commits it', (tester) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: null),
        onChanged: picks.add,
      );
      await _openModelSubmenu(tester);
      await tester.tap(find.text('Sonnet'));
      await tester.pumpAndSettle();

      expect(picks.single.judgeTool, 'claude');
      expect(picks.single.judgeModel, 'sonnet-4');
    });

    testWidgets('a model id can be typed even when a catalog exists', (
      tester,
    ) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: null),
        onChanged: picks.add,
      );
      await _openModelSubmenu(tester);
      await tester.tap(find.text('Type a model id…'));
      await tester.pumpAndSettle();

      expect(find.text('Leave empty for the default model.'), findsOneWidget);
      await tester.enterText(find.byType(CarbonTextInput), 'my-model');
      await tester.tap(find.text('Set model'));
      await tester.pumpAndSettle();

      expect(picks.single.judgeModel, 'my-model');
    });

    testWidgets('a tool nobody has heard list its models gets a free-text id', (
      tester,
    ) async {
      // The models list is written by a CHAT session of that tool, so a machine
      // that has only ever run this agent in a terminal has nothing to offer.
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'codex', judgeModel: null),
        onChanged: picks.add,
      );
      await _openMenu(tester);
      await tester.tap(find.text('Model: Default — type an id…'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "This machine hasn't heard Codex list its models — type an id.",
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(CarbonTextInput), 'o4-mini');
      // Committed on submit, not per keystroke: a half-typed id is one the
      // judge would try to run.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(picks.single.judgeModel, 'o4-mini');
    });

    testWidgets('cancelling the id modal changes nothing', (tester) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'codex', judgeModel: null),
        onChanged: picks.add,
      );
      await _openMenu(tester);
      await tester.tap(find.text('Model: Default — type an id…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(picks, isEmpty);
      expect(find.text('Set model'), findsNothing);
    });

    testWidgets('a catalog still on disk is loaded before the menu opens', (
      tester,
    ) async {
      // Hydration is an async disk read that answers empty on the build that
      // starts it, so a catalog first touched when the menu opens would offer
      // the free-text item — telling the user nobody has listed these models —
      // and swap it for a submenu a frame later. The chip reads the key from
      // its own build to settle the answer before the menu can show it.
      final root = Directory.systemTemp.createTempSync('ab_judge_chip_disk');
      await tester.runAsync(
        () => CapabilityCatalogCache.testInstance(
          root: root.path,
        ).write(capabilityCacheKey('local', 'claude'), _claudeModels),
      );

      final container = await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: null),
        seedModels: false,
        diskRoot: root,
      );
      // Real file IO progresses only outside the fake-async zone, and its
      // continuation lands only on a pump — so alternate the two. Polling for
      // the key rather than sleeping a fixed span is what makes this a pin: a
      // chip that never started the read leaves it absent however long we wait.
      final key = capabilityCacheKey('local', 'claude');
      for (var i = 0; i < 20; i++) {
        if (container.read(capabilityCatalogProvider).containsKey(key)) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await _openMenu(tester);

      expect(find.textContaining('type an id…'), findsNothing);
      await tester.tap(find.text('Model'));
      await tester.pumpAndSettle();
      expect(find.text('Opus'), findsOneWidget);
    });
  });
}
