// The compound judge+model chip and the two-pane panel behind it. What matters
// here is what a screenshot cannot show: which half of the label survives under
// width pressure, that a judge pick takes the model with it, and that the model
// pane is reachable — and escapable — without losing the panel.
import 'dart:io';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/models/capability_catalog.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/capability_catalog.dart';
import 'package:antgrid/services/capability_catalog_cache.dart';
import 'package:antgrid/widgets/handler/handler_judge_chip.dart';
import 'package:antgrid/widgets/handler/handler_session_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Mounts the chip in a slot of [width] — a ComposerChip is handed a slot
/// rather than asking for one, so every shed decision is made against this
/// number. Bottom-aligned because the composer's control row sits low on its
/// surface and the panel opens upward from it.
Widget _chipApp(
  ProviderContainer container, {
  required HandlerJudgePick judge,
  required double width,
  ValueChanged<HandlerJudgePick>? onChanged,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomLeft,
        child: SizedBox(
          width: width,
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: HandlerJudgeChip(
                    terminalId: 't1',
                    judge: judge,
                    onChanged: onChanged ?? (_) {},
                    scopeNote: handlerJudgeScopeOnArm,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<ProviderContainer> _pumpChip(
  WidgetTester tester, {
  required HandlerJudgePick judge,
  double width = 320,
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
    _chipApp(container, judge: judge, width: width, onChanged: onChanged),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byType(HandlerJudgeChip));
  await tester.pumpAndSettle();
}

Future<void> _drillToModels(WidgetTester tester) async {
  await _openPanel(tester);
  await tester.tap(find.text('Model'));
  await tester.pumpAndSettle();
}

void main() {
  group('the chip label', () {
    testWidgets('names the judge, then the model that qualifies it', (
      tester,
    ) async {
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: 'opus-4'),
      );

      // The catalog's display name, not the id: the id is what goes on the
      // wire, and the chip is the one place a model is read rather than sent.
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Opus'), findsOneWidget);
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

      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('o4-mini'), findsOneWidget);
    });

    testWidgets('with nothing to qualify it, the judge stands alone', (
      tester,
    ) async {
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Opus'), findsNothing);
    });

    testWidgets('the model half sheds and the judge name does not', (
      tester,
    ) async {
      // Metric-independent on purpose: the exact pixel each half drops at
      // depends on the test font, but the ORDER has to hold at every width.
      final container = _container();
      var sawJudgeAlone = false;
      for (var w = 320.0; w >= 60; w -= 8) {
        await tester.pumpWidget(
          _chipApp(
            container,
            judge: (judgeTool: 'claude', judgeModel: 'opus-4'),
            width: w,
          ),
        );
        await tester.pumpAndSettle();
        final judge = find.text('Claude').evaluate().isNotEmpty;
        final model = find.text('Opus').evaluate().isNotEmpty;
        // The whole rule as an implication: the qualifier must never outlive
        // the thing it qualifies.
        expect(model && !judge, isFalse, reason: 'model survived alone at $w');
        if (judge && !model) sawJudgeAlone = true;
      }
      // And the middle rung is real, not a straight fall from both to neither.
      expect(sawJudgeAlone, isTrue);
    });
  });

  group('the judge pane', () {
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
      await _openPanel(tester);

      expect(find.text('JUDGED BY'), findsOneWidget);
      // Twice: the Default judge row, and the model drill row's trailing value,
      // which also reads Default while nothing is picked.
      expect(find.text('Default'), findsNWidgets(2));
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Aider'), findsNothing);
      // Scope is stated where the pick is made — the same control means "from
      // the moment it arms" on one host and "next pass" on the other.
      expect(find.text(handlerJudgeScopeOnArm), findsOneWidget);
    });

    testWidgets('picking a judge clears the model and keeps the panel open', (
      tester,
    ) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: 'opus-4'),
        onChanged: picks.add,
      );
      await _openPanel(tester);
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();

      expect(picks.single.judgeTool, 'codex');
      // A model id is a name only its own CLI answers to: carried across, it
      // becomes a flag the new judge rejects on every pass.
      expect(picks.single.judgeModel, isNull);
      // The model is the next thing worth revisiting, so the panel stays up.
      expect(find.text('JUDGED BY'), findsOneWidget);
    });
  });

  group('the model pane', () {
    testWidgets('is always a drill, even for a three-model agent', (
      tester,
    ) async {
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));
      await _openPanel(tester);

      // Not listed inline under the judges: a panel that changes shape per
      // agent is one the user relearns per agent.
      expect(find.text('Sonnet'), findsNothing);

      await tester.tap(find.text('Model'));
      await tester.pumpAndSettle();

      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('Opus'), findsOneWidget);
      expect(find.text('Sonnet'), findsOneWidget);
      expect(find.text('Haiku'), findsOneWidget);
    });

    testWidgets('Default survives a query that matches no model', (
      tester,
    ) async {
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));
      await _drillToModels(tester);

      await tester.enterText(find.byType(AbTextField), 'zzzz');
      await tester.pumpAndSettle();

      expect(find.text('Opus'), findsNothing);
      expect(find.text('No matching models'), findsOneWidget);
      // Pinned above the filter and outside the searched list: putting the
      // model back must never require clearing a query first.
      expect(find.text('Default'), findsOneWidget);
    });

    testWidgets('picking a model commits it and closes the panel', (
      tester,
    ) async {
      final picks = <HandlerJudgePick>[];
      await _pumpChip(
        tester,
        judge: (judgeTool: 'claude', judgeModel: null),
        onChanged: picks.add,
      );
      await _drillToModels(tester);
      await tester.tap(find.text('Sonnet'));
      await tester.pumpAndSettle();

      expect(picks.single.judgeTool, 'claude');
      expect(picks.single.judgeModel, 'sonnet-4');
      expect(find.text('MODEL'), findsNothing);
    });

    testWidgets('the back row returns to the judges without dismissing', (
      tester,
    ) async {
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));
      await _drillToModels(tester);

      // Labelled with the judge it returns to, not the word "back": the pane
      // above is a judge list, and a model only means anything under one.
      await tester.tap(find.text('Claude').last);
      await tester.pumpAndSettle();

      expect(find.text('JUDGED BY'), findsOneWidget);
    });

    testWidgets('Escape goes back a pane rather than dismissing the panel', (
      tester,
    ) async {
      // Escape is bound at the route and pops the whole panel; the pane's own
      // Actions override is what makes the innermost handler win, so a
      // mis-drill costs a pane rather than the panel and the typed query.
      await _pumpChip(tester, judge: (judgeTool: 'claude', judgeModel: null));
      await _drillToModels(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('JUDGED BY'), findsOneWidget);
      expect(find.text('MODEL'), findsNothing);
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
      await _drillToModels(tester);

      expect(
        find.text(
          "This machine hasn't heard Codex list its models — type an id.",
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(AbTextField), 'o4-mini');
      // Committed on submit, not per keystroke: a half-typed id is one the
      // judge would try to run.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(picks.single.judgeModel, 'o4-mini');
    });

    testWidgets('a catalog still on disk is loaded before the drill', (
      tester,
    ) async {
      // Hydration is an async disk read that answers empty on the build that
      // starts it, so a catalog first touched at the drill would open this pane
      // on the free-text branch — telling the user nobody has listed these
      // models — and swap it for a list a frame later. The chip reads the key
      // from its own build to settle the answer before the pane can show it.
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
      await _drillToModels(tester);

      expect(find.text('Opus'), findsOneWidget);
      expect(
        find.text(
          "This machine hasn't heard Claude list its models — type an id.",
        ),
        findsNothing,
      );
    });
  });
}
