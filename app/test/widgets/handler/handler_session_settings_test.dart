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

/// Feeds its own `onChanged` back into `value`, the way [_SettingsSheetState]
/// really wires the sheet in production. Needed the moment a test taps more
/// than one chip in sequence: which PRESET reads as selected comes off the
/// `value` prop (only [HandlerLensControl]'s own-lens flag is local state),
/// so a harness that never echoes a commit back leaves every earlier preset
/// looking chosen forever.
class _ControlledSettings extends StatefulWidget {
  const _ControlledSettings({
    required this.initial,
    required this.onChanged,
    required this.appliesNextPass,
  });

  final HandlerSessionSettingsValue initial;
  final ValueChanged<HandlerSessionSettingsValue> onChanged;
  final bool appliesNextPass;

  @override
  State<_ControlledSettings> createState() => _ControlledSettingsState();
}

class _ControlledSettingsState extends State<_ControlledSettings> {
  late HandlerSessionSettingsValue _value = widget.initial;

  @override
  void didUpdateWidget(_ControlledSettings old) {
    super.didUpdateWidget(old);
    // A second `_pump` call in the same test re-mounts this same State (no
    // key, same runtimeType) rather than creating a fresh one — reset only
    // when the CALLER handed a new starting value; a rebuild from this
    // widget's own `onChanged` must not stomp what the user just did.
    if (widget.initial != old.initial) _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) => HandlerSessionSettings(
    terminalId: 't1',
    value: _value,
    appliesNextPass: widget.appliesNextPass,
    onChanged: (v) {
      setState(() => _value = v);
      widget.onChanged(v);
    },
  );
}

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
          body: _ControlledSettings(
            initial: value,
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

const _defaultChip = 'NOTHING EXTRA';
const _ownChip = 'YOUR OWN';

/// The "Your own" panel's field, keyed rather than positional: it only mounts
/// once that chip is selected, unlike the always-on field this replaced.
Finder get _ownField => find.byKey(const ValueKey('handlerOwnLensField'));

/// Selects the sixth chip so the panel (and its field) mount.
Future<void> _selectOwn(WidgetTester tester) async {
  await tester.tap(find.text(_ownChip));
  await tester.pump();
}

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

    test('names no line between handling and escalating', () {
      // Printed inside the lens block, so it is lens copy for the reader even
      // though it lives beside the widget rather than in handler_state.dart.
      final gating = RegExp('escalat|handl', caseSensitive: false);
      expect(gating.hasMatch(handlerJudgeParkedNotice('Codex')), isFalse);
      expect(gating.hasMatch(handlerJudgeParkedNotice(null)), isFalse);
    });
  });

  group('the sheet', () {
    testWidgets('leads with what it looks for and follows with the judge', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'));
      final lens = tester
          .getTopLeft(find.text('WHAT HANDLER WEIGHS'))
          .dy;
      final judge = tester.getTopLeft(find.text('JUDGED BY')).dy;
      final model = tester.getTopLeft(find.text('MODEL')).dy;
      expect(lens, lessThan(judge));
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
      // "Nothing extra" is one of the two picks whose caption is empty — the
      // floor line above the chips already says it (§7) — so neither the old
      // null-branch blurb nor the parked one may render.
      expect(find.text(handlerLensBlurb(null)), findsNothing);
      expect(find.text(handlerLensParkedBlurb), findsNothing);
    });

    testWidgets('the live lens reads no quieter than a warning does', (
      tester,
    ) async {
      // The chips name roles — PM, QA, CRITIC — and nothing else, so what each
      // one asks the agent exists ONLY in this line. It used to render muted on
      // the reasoning that a working control needs no commentary, which set the
      // definition of the chosen option at the contrast floor and made the row
      // undecidable without leaving the sheet.
      await _pump(tester, value: _value(lens: (roleId: 'qa', brief: null)));
      final live = tester.widget<Text>(
        find.text(handlerLensBlurb(HandlerLens.qa)),
      );

      await _pump(tester, value: _value(lens: null));
      final warning = tester.widget<Text>(find.text(handlerLensUnsetBlurb));

      expect(live.style?.color, warning.style?.color);
      expect(live.style?.color, kDefaultPalette.textSecondary);
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
      expect(_chip(tester, 'PROOF IT WORKS').selected, isTrue);
      expect(_chip(tester, 'PROOF IT WORKS').color, isNull);
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
      // "Your own" is one of the disabled six — nothing here can be picked,
      // including the panel a tap on it would otherwise reveal.
      expect(find.text(_ownChip), findsOneWidget);
      expect(_ownField, findsNothing);
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
      expect(find.text('STAYS IN SCOPE'), findsOneWidget);
      expect(find.text('PROOF IT WORKS'), findsOneWidget);
      expect(find.text('WHAT COULD BREAK'), findsNothing);
      expect(find.text('READY TO SHIP'), findsNothing);
      expect(find.text(_defaultChip), findsOneWidget);
      // Neither preset id, so unconditional regardless of what the machine
      // advertised (redesign spec §7).
      expect(find.text(_ownChip), findsOneWidget);
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

      await tester.tap(find.text('PROOF IT WORKS'));
      await tester.pump();

      final edit = handlerSessionSettingsEdit(from, sent!);
      expect(edit.role, 'qa');
      expect(edit.judgeTool, isNull);
      expect(edit.judgeModel, isNull);
    });

    testWidgets('a submitted own lens commits trimmed, and clears as empty', (
      tester,
    ) async {
      HandlerSessionSettingsValue? sent;
      final from = _value(judgeTool: 'claude');
      await _pump(tester, value: from, onChanged: (v) => sent = v);
      await _selectOwn(tester);
      // Picking the chip alone is a commit too — an empty draft — before any
      // text is typed.
      sent = null;

      await tester.enterText(_ownField, '  show tests  ');
      await tester.pump();
      // A keystroke alone commits nothing on this sheet: each commit is a
      // configure frame, and the bridge's edit path buys a real judge pass.
      expect(sent, isNull);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(handlerSessionSettingsEdit(from, sent!).brief, 'show tests');

      final typed = sent!;
      await tester.enterText(_ownField, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(handlerSessionSettingsEdit(typed, sent!).brief, '');
    });

    testWidgets('the own lens stops where the prompt stops', (tester) async {
      // Mirrored by hand from the bridge's MAX_BRIEF_CHARS. The bridge clips
      // a longer brief rather than refusing it, so a cap that drifted here
      // would let the user type a tail the judge never reads.
      expect(handlerMaxBriefChars, 1000);
      HandlerSessionSettingsValue? sent;
      final from = _value(judgeTool: 'claude');
      await _pump(tester, value: from, onChanged: (v) => sent = v);
      await _selectOwn(tester);

      await tester.enterText(_ownField, 'x' * (handlerMaxBriefChars + 1));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(
        handlerSessionSettingsEdit(from, sent!).brief,
        hasLength(handlerMaxBriefChars),
      );
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

      expect(find.text('WHAT HANDLER WEIGHS'), findsOneWidget);
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
      expect(find.text('WHAT HANDLER WEIGHS'), findsNothing);
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

    testWidgets('the six chips are one radio group', (tester) async {
      // Redesign spec §3.2, §9: one selection lives at a time, whichever of
      // the six it lands on — never a preset row plus a separate disclosure.
      const sixLabels = [
        'NOTHING EXTRA',
        'STAYS IN SCOPE',
        'PROOF IT WORKS',
        'WHAT COULD BREAK',
        'READY TO SHIP',
        'YOUR OWN',
      ];
      await _pump(tester, value: _value(judgeTool: 'claude'));
      expect(_chip(tester, 'NOTHING EXTRA').selected, isTrue);

      await tester.tap(find.text('WHAT COULD BREAK'));
      await tester.pump();
      for (final label in sixLabels) {
        expect(
          _chip(tester, label).selected,
          label == 'WHAT COULD BREAK',
          reason: label,
        );
      }

      await tester.tap(find.text(_ownChip));
      await tester.pump();
      for (final label in sixLabels) {
        expect(_chip(tester, label).selected, label == _ownChip, reason: label);
      }
    });

    testWidgets('the own-lens panel shows only while its chip is picked', (
      tester,
    ) async {
      await _pump(tester, value: _value(judgeTool: 'claude'));
      expect(_ownField, findsNothing);

      await _selectOwn(tester);
      expect(_ownField, findsOneWidget);

      await tester.tap(find.text('READY TO SHIP'));
      await tester.pump();
      expect(_ownField, findsNothing);

      await tester.tap(find.text(_defaultChip));
      await tester.pump();
      expect(_ownField, findsNothing);
    });

    testWidgets(
      'picking any other chip keeps the draft locally and sends an empty brief',
      (tester) async {
        // Redesign spec §6: two stances cannot both run, so a preset always
        // clears the WIRE brief — but the draft itself rides in the panel's
        // own controller until "Your own" is picked again.
        HandlerSessionSettingsValue? sent;
        await _pump(
          tester,
          value: _value(judgeTool: 'claude'),
          onChanged: (v) => sent = v,
        );
        await _selectOwn(tester);
        await tester.enterText(_ownField, 'watch the migrations');
        await tester.pump();

        await tester.tap(find.text('STAYS IN SCOPE'));
        await tester.pump();
        expect(sent?.lens, (roleId: 'pm', brief: ''));

        await _selectOwn(tester);
        expect(_ownField, findsOneWidget);
        expect(
          tester.widget<AbTextField>(_ownField).controller?.text,
          'watch the migrations',
        );
      },
    );

    testWidgets('the own lens joins its lines with "; " on commit', (
      tester,
    ) async {
      // The bridge's `oneLine` (decision.ts) collapses a bare newline to a
      // space, which would fuse two typed rules into one — redesign spec §8.
      HandlerSessionSettingsValue? sent;
      await _pump(
        tester,
        value: _value(judgeTool: 'claude'),
        onChanged: (v) => sent = v,
      );
      await _selectOwn(tester);

      await tester.enterText(
        _ownField,
        '  first rule  \nsecond rule\n\nthird rule',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(sent?.lens?.brief, 'first rule; second rule; third rule');
    });
  });

  group('handlerJoinOwnLensLines', () {
    test('trims each line and drops blank ones', () {
      expect(
        handlerJoinOwnLensLines('  a  \n\nb\n c '),
        'a; b; c',
      );
    });

    test('a single line passes through unjoined', () {
      expect(handlerJoinOwnLensLines('one rule'), 'one rule');
    });

    test('an empty draft joins to an empty string', () {
      expect(handlerJoinOwnLensLines(''), '');
      expect(handlerJoinOwnLensLines('\n\n'), '');
    });
  });
}
