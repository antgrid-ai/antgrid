// The two per-session Handler choices and the sheet they share. The rules that
// matter here are the ones a screenshot cannot show: what a change SENDS, and
// what the sheet claims while nothing is actually judging.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_segmented.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/widgets/handler/handler_session_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

class _SeededCatalog extends AgentCatalogNotifier {
  _SeededCatalog(this.seed);

  final Map<String, AgentDescriptor> seed;

  @override
  Map<String, AgentDescriptor> build() => seed;
}

AgentDescriptor _descriptor(String tool, {required bool judgeCapable}) =>
    AgentDescriptor(
      tool: tool,
      label: tool[0].toUpperCase() + tool.substring(1),
      chatCapable: true,
      judgeCapable: judgeCapable,
      handlerTerminal: true,
      handlerChat: true,
    );

HandlerSessionSettingsValue _value({
  String? judgeTool,
  String? judgeModel,
  HandlerPersonality personality = HandlerPersonality.watchdog,
}) => (
  judgeTool: judgeTool,
  judgeModel: judgeModel,
  personality: personality,
);

Future<void> _pump(
  WidgetTester tester, {
  required HandlerSessionSettingsValue value,
  Map<String, bool> catalog = const {'claude': true},
  ValueChanged<HandlerSessionSettingsValue>? onChanged,
  bool appliesNextPass = false,
}) async {
  useInMemoryPrefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentCatalogProvider.overrideWith(
          () => _SeededCatalog({
            for (final e in catalog.entries)
              e.key: _descriptor(e.key, judgeCapable: e.value),
          }),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(
          body: HandlerSessionSettings(
            terminalId: 't1',
            value: value,
            onChanged: onChanged ?? (_) {},
            appliesNextPass: appliesNextPass,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Mounts ONE half of the settings block. The arm sheet takes the posture half
/// alone, because its composer's chip is already the judge picker there.
Future<void> _pumpHalf(
  WidgetTester tester,
  Widget half, {
  Map<String, bool> catalog = const {'claude': true},
}) async {
  useInMemoryPrefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentCatalogProvider.overrideWith(
          () => _SeededCatalog({
            for (final e in catalog.entries)
              e.key: _descriptor(e.key, judgeCapable: e.value),
          }),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(body: half),
      ),
    ),
  );
  await tester.pump();
}

AbSegmented<HandlerPersonality> _segmented(WidgetTester tester) =>
    tester.widget<AbSegmented<HandlerPersonality>>(
      find.byType(AbSegmented<HandlerPersonality>),
    );

void main() {
  group('handlerSessionSettingsEdit', () {
    test('an untouched sheet sends nothing at all', () {
      final v = _value(judgeTool: 'codex', judgeModel: 'o3');
      final edit = handlerSessionSettingsEdit(v, v);
      expect(edit.judgeTool, isNull);
      expect(edit.judgeModel, isNull);
      expect(edit.personality, isNull);
    });

    test('only the moved field is sent', () {
      final edit = handlerSessionSettingsEdit(
        _value(judgeTool: 'codex', judgeModel: 'o3'),
        _value(
          judgeTool: 'codex',
          judgeModel: 'o3',
          personality: HandlerPersonality.autopilot,
        ),
      );
      expect(edit.personality, HandlerPersonality.autopilot);
      // The judge is untouched, so the wire must not carry it — a cold cache
      // would otherwise clear a pick the bridge holds and this app has never
      // been told about.
      expect(edit.judgeTool, isNull);
      expect(edit.judgeModel, isNull);
    });

    test('clearing a judge field goes out as the empty string, not null', () {
      // Null means "leave it alone" on the wire, so the clear needs its own
      // spelling or it is indistinguishable from no change.
      final edit = handlerSessionSettingsEdit(
        _value(judgeTool: 'codex', judgeModel: 'o3'),
        _value(),
      );
      expect(edit.judgeTool, '');
      expect(edit.judgeModel, '');
    });

    test('a judge picked for the first time is sent by name', () {
      final edit = handlerSessionSettingsEdit(
        _value(),
        _value(judgeTool: 'claude'),
      );
      expect(edit.judgeTool, 'claude');
      expect(edit.judgeModel, isNull);
    });
  });

  group('handlerSessionSettingsFor', () {
    test('a session with nothing stored opens on the bridge default', () {
      final seed = handlerSessionSettingsFor(null, 't1');
      expect(seed.personality, HandlerPersonality.watchdog);
      expect(seed.judgeTool, isNull);
      expect(seed.judgeModel, isNull);
    });
  });

  group('handlerJudgeParkedNotice', () {
    test('names the judge that cannot run and the fix, not just the fault', () {
      final notice = handlerJudgeParkedNotice('Codex');
      expect(notice, contains('Codex'));
      expect(notice, contains('Pick one that can'));
    });

    test('falls back to a nameless judge rather than a blank', () {
      expect(handlerJudgeParkedNotice(null), startsWith('This judge'));
    });
  });

  group('the sheet', () {
    testWidgets('leads with the posture and follows with the judge', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'));
      final posture = tester.getTopLeft(find.text('HOW MUCH IT HANDLES')).dy;
      final judge = tester.getTopLeft(find.text('JUDGED BY')).dy;
      final model = tester.getTopLeft(find.text('MODEL')).dy;
      expect(posture, lessThan(judge));
      expect(judge, lessThan(model));
    });

    testWidgets('a healthy judge leaves the posture live and unexplained', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'));
      expect(_segmented(tester).inactive, isFalse);
      expect(
        find.text(handlerPersonalityBlurb(HandlerPersonality.watchdog)),
        findsOneWidget,
      );
      expect(find.text(handlerPostureParkedBlurb), findsNothing);
    });

    testWidgets('a judge that cannot run headless parks the posture', (
      tester,
    ) async {
      await _pump(
        tester,
        value: _value(
          judgeTool: 'codex',
          personality: HandlerPersonality.autopilot,
        ),
        catalog: const {'claude': true, 'codex': false},
      );
      // Still the user's choice to make — it starts working the moment the
      // judge is fixed — but it must not be painted as running.
      expect(_segmented(tester).inactive, isTrue);
      expect(find.text(handlerPostureParkedBlurb), findsOneWidget);
      expect(find.textContaining(handlerJudgeParkedNotice('Codex')), findsOne);
    });

    testWidgets('the parked line outranks the next-pass line', (tester) async {
      // Both are true post-arm, and "takes effect next pass" implies it takes
      // effect at all, which is the one thing a parked posture does not do.
      await _pump(
        tester,
        value: _value(judgeTool: 'codex'),
        catalog: const {'codex': false},
        appliesNextPass: true,
      );
      expect(find.text(handlerPostureParkedBlurb), findsOneWidget);
      expect(find.textContaining('Takes effect on the next pass.'), findsNothing);
    });

    testWidgets('post-arm, a live posture says when it lands', (tester) async {
      await _pump(
        tester,
        value: _value(judgeTool: 'claude'),
        appliesNextPass: true,
      );
      expect(
        find.textContaining('Takes effect on the next pass.'),
        findsOneWidget,
      );
    });

    testWidgets('the posture half carries no judge picker of its own', (
      tester,
    ) async {
      // On the arm sheet the composer's chip IS the judge picker, so mounting
      // these rows too would be two controls for one value.
      await _pumpHalf(
        tester,
        HandlerPostureControl(
          terminalId: 't1',
          value: _value(judgeTool: 'codex'),
          onChanged: (_) {},
        ),
        catalog: const {'codex': false},
      );

      expect(find.text('HOW MUCH IT HANDLES'), findsOneWidget);
      // The parked blurb REPLACES the personality one — a posture that is
      // stored and inert must not also describe what it would be doing.
      expect(find.text(handlerPostureParkedBlurb), findsOneWidget);
      // The parked notice stays with the posture it parks: its copy never says
      // "below", so on the arm sheet it points up at the chip and still reads
      // true.
      expect(find.textContaining(handlerJudgeParkedNotice('Codex')), findsOne);
      expect(find.text('JUDGED BY'), findsNothing);
      expect(find.text('MODEL'), findsNothing);
    });

    testWidgets('the judge half carries both picker rows and no posture', (
      tester,
    ) async {
      await _pumpHalf(
        tester,
        HandlerJudgeControl(
          terminalId: 't1',
          value: _value(judgeTool: 'claude'),
          onChanged: (_) {},
        ),
      );

      expect(find.text('JUDGED BY'), findsOneWidget);
      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('HOW MUCH IT HANDLES'), findsNothing);
      expect(find.byType(AbSegmented<HandlerPersonality>), findsNothing);
    });

    testWidgets('picking a judge clears the model with it', (tester) async {
      HandlerSessionSettingsValue? sent;
      await _pump(
        tester,
        value: _value(judgeTool: 'claude', judgeModel: 'sonnet-x'),
        catalog: const {'claude': true, 'codex': true},
        onChanged: (v) => sent = v,
      );
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex').last);
      await tester.pumpAndSettle();

      expect(sent?.judgeTool, 'codex');
      // A model id is a name only its own CLI answers to: carried across, it
      // becomes a flag the new judge rejects on every pass.
      expect(sent?.judgeModel, isNull);
    });
  });
}
