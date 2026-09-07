// The per-session Handler choices and the sheet they share. The rules that
// matter here are the ones a screenshot cannot show: what a change SENDS, and
// what the sheet claims while nothing is actually judging.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/providers.dart';
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

/// Every lens this build knows, which is what an up-to-date machine advertises.
const _allLenses = ['pm', 'qa', 'critic', 'release'];

HandlerSessionSettingsValue _value({
  String? judgeTool,
  String? judgeModel,
  HandlerLensPick? lens = (roleId: null, brief: null),
}) => (judgeTool: judgeTool, judgeModel: judgeModel, lens: lens);

/// The lens row is gated on the machine having named its lenses, so every pump
/// states what this one advertises. `lenses: null` is the machine that never
/// said, which is the inert case.
HandlerState _state(List<String>? lenses) => HandlerState(
  lenses: lenses,
  sessions: const {},
  escalations: const [],
  activity: const [],
);

Future<void> _pump(
  WidgetTester tester, {
  required HandlerSessionSettingsValue value,
  Map<String, bool> catalog = const {'claude': true},
  ValueChanged<HandlerSessionSettingsValue>? onChanged,
  bool appliesNextPass = false,
  List<String>? lenses = _allLenses,
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
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(_state(lenses)),
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

/// Mounts ONE half of the settings block. The arm sheet takes the lens half
/// alone, because its composer's chip is already the judge picker there.
Future<void> _pumpHalf(
  WidgetTester tester,
  Widget half, {
  Map<String, bool> catalog = const {'claude': true},
  List<String>? lenses = _allLenses,
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
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(_state(lenses)),
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

/// Chip labels render uppercased, so every finder here names them that way.
AbChip _chip(WidgetTester tester, String label) =>
    tester.widget<AbChip>(find.widgetWithText(AbChip, label));

const _defaultChip = 'INTENT AND COMPLETION';

/// The brief's own field. The judge's model row is an [AbTextField] too on a
/// machine that has never heard that CLI list its models, and the lens block is
/// mounted first — so position is what tells the two apart.
Finder get _briefField => find.byType(AbTextField).first;

void main() {
  group('handlerSessionSettingsEdit', () {
    test('an untouched sheet sends nothing at all', () {
      final v = _value(judgeTool: 'codex', judgeModel: 'o3');
      final edit = handlerSessionSettingsEdit(v, v);
      expect(edit.judgeTool, isNull);
      expect(edit.judgeModel, isNull);
      expect(edit.role, isNull);
      expect(edit.brief, isNull);
    });

    test('only the moved field is sent', () {
      final edit = handlerSessionSettingsEdit(
        _value(judgeTool: 'codex', judgeModel: 'o3'),
        _value(
          judgeTool: 'codex',
          judgeModel: 'o3',
          lens: (roleId: 'qa', brief: null),
        ),
      );
      expect(edit.role, 'qa');
      expect(edit.brief, isNull);
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
      // Cleared, not omitted: this app's `from` reads null whenever its cache
      // is cold, and the bridge may well be holding the PREVIOUS CLI's model.
      // Omitting the key would leave that id in force under the new judge.
      expect(edit.judgeModel, '');
    });

    test('a tool change always carries the model, cold cache included', () {
      final edit = handlerSessionSettingsEdit(
        _value(judgeTool: 'codex'),
        _value(judgeTool: 'claude'),
      );
      expect(edit.judgeTool, 'claude');
      expect(edit.judgeModel, '');
    });

    test('a model-only edit leaves the tool alone', () {
      final edit = handlerSessionSettingsEdit(
        _value(judgeTool: 'codex', judgeModel: 'o3'),
        _value(judgeTool: 'codex', judgeModel: 'o4-mini'),
      );
      expect(edit.judgeTool, isNull);
      expect(edit.judgeModel, 'o4-mini');
    });

    test('a return to the default is a clear, not silence', () {
      final edit = handlerSessionSettingsEdit(
        _value(lens: (roleId: 'qa', brief: null)),
        _value(lens: (roleId: null, brief: null)),
      );
      expect(edit.role, '');
    });

    test('a pick made over a seed nobody stated always sends', () {
      // A null `from` lens is "this app has not been told", and the bridge may
      // hold anything — including an id this build cannot name — so the pick
      // has to go out rather than be diffed into silence.
      final edit = handlerSessionSettingsEdit(
        _value(lens: null),
        _value(lens: (roleId: 'pm', brief: null)),
      );
      expect(edit.role, 'pm');
    });

    test('a brief moves on its own, and clears as the empty string', () {
      final typed = handlerSessionSettingsEdit(
        _value(lens: (roleId: 'qa', brief: null)),
        _value(lens: (roleId: 'qa', brief: 'show the failing case')),
      );
      expect(typed.brief, 'show the failing case');
      expect(typed.role, isNull);

      final cleared = handlerSessionSettingsEdit(
        _value(lens: (roleId: 'qa', brief: 'show the failing case')),
        _value(lens: (roleId: 'qa', brief: null)),
      );
      expect(cleared.brief, '');
      expect(cleared.role, isNull);
    });
  });

  group('handlerSessionSettingsFor', () {
    test('a session with nothing stored reports no lens, never a guess', () {
      // A machine that has never advertised lenses is not a machine running the
      // unnamed default: seeding it here would put a lens on screen as a live
      // fact and then send nothing when the user "changed" it to what was shown.
      final seed = handlerSessionSettingsFor(null, 't1');
      expect(seed.lens, isNull);
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
    testWidgets('leads with what it looks for and follows with the judge', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'));
      final lens = tester.getTopLeft(find.text('WHAT IT LOOKS FOR')).dy;
      final brief = tester.getTopLeft(find.text('BRIEF')).dy;
      final judge = tester.getTopLeft(find.text('JUDGED BY')).dy;
      final model = tester.getTopLeft(find.text('MODEL')).dy;
      expect(lens, lessThan(brief));
      expect(brief, lessThan(judge));
      expect(judge, lessThan(model));
    });

    testWidgets('a healthy judge marks the running lens and nothing else', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'));
      final p = kDefaultPalette;
      expect(_chip(tester, _defaultChip).selected, isTrue);
      expect(_chip(tester, _defaultChip).color, p.accent);
      // Exactly one: the accent is what says "this is what is running", and two
      // of them would be two answers to one question.
      final accented = tester
          .widgetList<AbChip>(find.byType(AbChip))
          .where((c) => c.color == p.accent);
      expect(accented, hasLength(1));
      expect(find.text(handlerLensBlurb(null)), findsOneWidget);
      expect(find.text(handlerLensParkedBlurb), findsNothing);
    });

    testWidgets('a judge that cannot run headless parks the lens', (
      tester,
    ) async {
      await _pump(
        tester,
        value: _value(judgeTool: 'codex', lens: (roleId: 'qa', brief: null)),
        catalog: const {'claude': true, 'codex': false},
      );
      // Still the user's choice to make — it starts working the moment the
      // judge is fixed — but it must not be painted as running.
      expect(_chip(tester, 'QA').selected, isTrue);
      expect(_chip(tester, 'QA').color, isNull);
      expect(find.text(handlerLensParkedBlurb), findsOneWidget);
      expect(find.textContaining(handlerJudgeParkedNotice('Codex')), findsOne);
    });

    testWidgets('the parked line outranks the next-pass line', (tester) async {
      // Both are true post-arm, and "takes effect next pass" implies it takes
      // effect at all, which is the one thing a parked lens does not do.
      await _pump(
        tester,
        value: _value(judgeTool: 'codex'),
        catalog: const {'codex': false},
        appliesNextPass: true,
      );
      expect(find.text(handlerLensParkedBlurb), findsOneWidget);
      expect(
        find.textContaining('Takes effect on the next pass.'),
        findsNothing,
      );
    });

    testWidgets('post-arm, a live lens says when it lands', (tester) async {
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

    testWidgets('a machine that named no lenses offers nothing to pick', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'), lenses: null);
      for (final chip in tester.widgetList<AbChip>(find.byType(AbChip))) {
        expect(chip.enabled, isFalse);
        expect(chip.selected, isFalse);
      }
      expect(tester.widget<AbTextField>(_briefField).enabled, isFalse);
      expect(find.text(handlerLensUnreportedBlurb), findsOneWidget);
    });

    testWidgets('only the lenses this machine named are offered', (
      tester,
    ) async {
      // The intersection, so a newer app can never send an id the far end
      // would strip off the frame in silence.
      await _pump(
        tester,
        value: _value(judgeTool: 'claude'),
        lenses: const ['pm', 'qa'],
      );
      expect(find.text('PM'), findsOneWidget);
      expect(find.text('QA'), findsOneWidget);
      expect(find.text('CRITIC'), findsNothing);
      expect(find.text('RELEASE MANAGER'), findsNothing);
      expect(find.text(_defaultChip), findsOneWidget);
    });

    testWidgets('a lens this build cannot name selects nothing and says so', (
      tester,
    ) async {
      HandlerSessionSettingsValue? sent;
      await _pump(
        tester,
        value: _value(
          judgeTool: 'claude',
          lens: (roleId: 'ship-it', brief: null),
        ),
        onChanged: (v) => sent = v,
      );
      for (final chip in tester.widgetList<AbChip>(find.byType(AbChip))) {
        expect(chip.selected, isFalse);
      }
      expect(find.text(handlerLensUnknownBlurb), findsOneWidget);

      // One tap on the default is what replaces it.
      await tester.tap(find.text(_defaultChip));
      await tester.pump();
      expect(
        handlerSessionSettingsEdit(
          _value(judgeTool: 'claude', lens: (roleId: 'ship-it', brief: null)),
          sent!,
        ).role,
        '',
      );
    });

    testWidgets('a pick this app was never told selects nothing', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude', lens: null));
      for (final chip in tester.widgetList<AbChip>(find.byType(AbChip))) {
        expect(chip.selected, isFalse);
        expect(chip.enabled, isTrue);
      }
      expect(find.text(handlerLensUnsetBlurb), findsOneWidget);
    });

    testWidgets('picking a lens sends it and leaves the judge alone', (
      tester,
    ) async {
      HandlerSessionSettingsValue? sent;
      final from = _value(judgeTool: 'claude');
      await _pump(tester, value: from, onChanged: (v) => sent = v);

      await tester.tap(find.text('QA'));
      await tester.pump();

      final edit = handlerSessionSettingsEdit(from, sent!);
      expect(edit.role, 'qa');
      expect(edit.judgeTool, isNull);
      expect(edit.judgeModel, isNull);
    });

    testWidgets('a submitted brief commits trimmed, and clears as empty', (
      tester,
    ) async {
      HandlerSessionSettingsValue? sent;
      final from = _value(judgeTool: 'claude');
      await _pump(tester, value: from, onChanged: (v) => sent = v);

      await tester.enterText(_briefField, '  show tests  ');
      await tester.pump();
      // A keystroke alone commits nothing on this sheet: each commit is a
      // configure frame, and the bridge's edit path buys a real judge pass.
      expect(sent, isNull);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(handlerSessionSettingsEdit(from, sent!).brief, 'show tests');

      final typed = sent!;
      await tester.enterText(_briefField, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(handlerSessionSettingsEdit(typed, sent!).brief, '');
    });

    testWidgets('the lens half carries no judge picker of its own', (
      tester,
    ) async {
      // On the arm sheet the composer's chip IS the judge picker, so mounting
      // these rows too would be two controls for one value.
      await _pumpHalf(
        tester,
        HandlerLensControl(
          terminalId: 't1',
          value: _value(judgeTool: 'codex'),
          onChanged: (_) {},
        ),
        catalog: const {'codex': false},
      );

      expect(find.text('WHAT IT LOOKS FOR'), findsOneWidget);
      // The parked blurb REPLACES the lens one — a lens that is stored and
      // inert must not also describe what it would be asking.
      expect(find.text(handlerLensParkedBlurb), findsOneWidget);
      // The parked notice stays with the lens it parks: its copy never says
      // "below", so on the arm sheet it points up at the chip and still reads
      // true.
      expect(find.textContaining(handlerJudgeParkedNotice('Codex')), findsOne);
      expect(find.text('JUDGED BY'), findsNothing);
      expect(find.text('MODEL'), findsNothing);
    });

    testWidgets('the judge half carries both picker rows and no lens', (
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
      expect(find.text('WHAT IT LOOKS FOR'), findsNothing);
      expect(find.text('BRIEF'), findsNothing);
      expect(find.byType(AbChip), findsNothing);
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
