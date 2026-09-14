import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/widgets/handler/handler_ask_footer.dart';
import 'package:antgrid/widgets/handler/handler_decision_card.dart';
import 'package:antgrid/widgets/handler/handler_why.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _choices = [
  HandlerEscalationChoice(
    choiceId: 'approve',
    label: 'Approve',
    text: 'yes, use bun for the new package',
  ),
  HandlerEscalationChoice(
    choiceId: 'reject',
    label: 'Reject',
    text: 'no, keep vitest',
  ),
];

HandlerEscalation _escalation(String id) => HandlerEscalation(
  escalationId: id,
  terminalId: 't1',
  question: 'bun or vitest?',
  reasoning: 'Affects CI wiring.',
  draftReply: 'use bun',
  urgency: 'high',
  at: 1,
  choices: _choices,
);

/// Drives the card without a service behind it, which is the only way to hold
/// it in the in-flight state: a real answer clears the escalation within a
/// frame, so the card it is rendered from is gone by the next build. The wire
/// path is pinned in `handler_screen_test.dart` instead.
Future<void> _pumpCard(
  WidgetTester tester,
  HandlerEscalation escalation, {
  bool Function(String)? onChoice,
  VoidCallback? onCustomReply,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: HandlerDecisionCard(
        escalation: escalation,
        onChoice: onChoice,
        onCustomReply: onCustomReply,
      ),
    ),
  ),
);

/// A callback that accepts every tap, recording the id it was given.
bool Function(String) _record(List<String> into) => (id) {
  into.add(id);
  return true;
};

AbButton _button(WidgetTester tester, String label) =>
    tester.widget<AbButton>(find.widgetWithText(AbButton, label));

void main() {
  testWidgets('every choice shows the text its tap would send', (tester) async {
    await _pumpCard(tester, _escalation('e1'), onChoice: (_) => true);
    for (final c in _choices) {
      expect(find.text(c.label), findsOneWidget);
      expect(find.text(c.text), findsOneWidget);
    }
  });

  testWidgets('an in-flight choice says so and closes the other chips', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      _escalation('e1'),
      onChoice: (_) => true,
      onCustomReply: () {},
    );
    await tester.tap(find.text('Approve'));
    await tester.pump();

    expect(find.text(handlerChoiceSendingLabel), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    // The answer is already on its way — a second one would land at whatever
    // prompt the agent moved on to.
    expect(_button(tester, 'Reject').onTap, isNull);
  });

  testWidgets('a second tap in the same frame answers once', (tester) async {
    final taps = <String>[];
    await _pumpCard(tester, _escalation('e1'), onChoice: _record(taps));
    await tester.tap(find.text('Approve'));
    await tester.tap(find.text('Approve'));
    await tester.pump();
    expect(taps, ['approve']);
  });

  testWidgets('a card recycled onto another escalation is tappable again', (
    tester,
  ) async {
    final taps = <String>[];
    await _pumpCard(tester, _escalation('e1'), onChoice: _record(taps));
    await tester.tap(find.text('Approve'));
    await tester.pump();
    expect(find.text(handlerChoiceSendingLabel), findsOneWidget);

    // Same position, same type, no key: this State is the one the answered
    // escalation left behind.
    await _pumpCard(tester, _escalation('e2'), onChoice: _record(taps));
    expect(find.text(handlerChoiceSendingLabel), findsNothing);
    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(taps, ['approve', 'reject']);
  });

  testWidgets('choices are inert with nothing to answer through', (
    tester,
  ) async {
    await _pumpCard(tester, _escalation('e1'), onChoice: null);
    expect(_button(tester, 'Approve').onTap, isNull);
    await tester.tap(find.text('Approve'));
    await tester.pump();
    // Never a card stuck reporting an answer that was never sent.
    expect(find.text(handlerChoiceSendingLabel), findsNothing);
  });

  testWidgets('a refused send leaves the whole card usable', (tester) async {
    // Every refusal path in HandlerService.reply leaves the escalation open, so
    // latching here would answer one unsent reply with a card that can never
    // send another — the 3am dead end [Custom Reply] exists to prevent.
    final taps = <String>[];
    var opened = 0;
    await _pumpCard(
      tester,
      _escalation('e1'),
      onChoice: (id) {
        taps.add(id);
        return false;
      },
      onCustomReply: () => opened++,
    );
    await tester.tap(find.text('Approve'));
    await tester.pump();

    expect(find.text(handlerChoiceSendingLabel), findsNothing);
    expect(_button(tester, 'Reject').onTap, isNotNull);
    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(taps, ['approve', 'reject']);

    await tester.tap(find.text(handlerCustomReplyLabel));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('the escape hatch stays open while an answer is in flight', (
    tester,
  ) async {
    var opened = 0;
    await _pumpCard(
      tester,
      _escalation('e1'),
      onChoice: (_) => true,
      onCustomReply: () => opened++,
    );
    await tester.tap(find.text('Approve'));
    await tester.pump();

    expect(find.text(handlerChoiceSendingLabel), findsOneWidget);
    await tester.tap(find.text(handlerCustomReplyLabel));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('a max-length choice text is rendered whole, never elided', (
    tester,
  ) async {
    // The wire caps `text` at 400 characters and the card is the only place the
    // user reads what a one-tap sends.
    final long = List.generate(80, (i) => 'word$i').join(' ').substring(0, 400);
    await _pumpCard(
      tester,
      HandlerEscalation(
        escalationId: 'e1',
        terminalId: 't1',
        question: 'q',
        reasoning: 'r',
        draftReply: long,
        urgency: 'normal',
        at: 1,
        choices: [
          HandlerEscalationChoice(
            choiceId: 'approve',
            label: 'Approve',
            text: long,
          ),
          _choices[1],
        ],
      ),
      onChoice: (_) => true,
    );

    final rendered = tester.widget<Text>(find.text(long));
    expect(rendered.maxLines, isNull);
    expect(rendered.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a choice draws its label, its cost and its verbatim text', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      HandlerEscalation(
        escalationId: 'e1',
        terminalId: 't1',
        question: 'q',
        reasoning: 'r',
        draftReply: 'use bun',
        urgency: 'normal',
        at: 1,
        choices: const [
          HandlerEscalationChoice(
            choiceId: 'approve',
            label: 'Switch to bun',
            text: 'yes, use bun for the new package',
            cost: 'Runs bun install and commits the lockfile.',
          ),
          HandlerEscalationChoice(
            choiceId: 'reject',
            label: 'Reject',
            text: 'no, keep vitest',
            cost: 'Nothing is sent; the agent waits for your next instruction.',
          ),
        ],
      ),
      onChoice: (_) => true,
    );

    expect(find.text('Switch to bun'), findsOneWidget);
    expect(
      find.text('Runs bun install and commits the lockfile.'),
      findsOneWidget,
    );
    expect(find.text('yes, use bun for the new package'), findsOneWidget);
  });

  testWidgets('a choice with no cost renders exactly as it did before', (
    tester,
  ) async {
    await _pumpCard(tester, _escalation('e1'), onChoice: (_) => true);

    // _choices carries no cost for either entry — nothing new should appear.
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('yes, use bun for the new package'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the reasoning sits behind a Why disclosure, collapsed', (
    tester,
  ) async {
    final escalation = _escalation('e1');
    await _pumpCard(tester, escalation, onChoice: (_) => true);

    expect(find.text(escalation.reasoning), findsNothing);
    expect(find.text('Why'), findsOneWidget);

    await tester.tap(find.text('Why'));
    await tester.pump();
    expect(find.text(escalation.reasoning), findsOneWidget);
  });

  testWidgets('a card recycled onto another escalation collapses again', (
    tester,
  ) async {
    final e1 = _escalation('e1');
    await _pumpCard(tester, e1, onChoice: (_) => true);
    await tester.tap(find.text('Why'));
    await tester.pump();
    expect(find.text(e1.reasoning), findsOneWidget);

    // Same position, same type, no key: this is the State an answered card
    // leaves behind for the next escalation to render through.
    final e2 = _escalation('e2');
    await _pumpCard(tester, e2, onChoice: (_) => true);
    expect(find.text(e2.reasoning), findsNothing);
    expect(find.text('Why'), findsOneWidget);
  });

  testWidgets(
    'the safety floor and the ask latency note stay visible with Why collapsed',
    (tester) async {
      await _pumpCard(
        tester,
        HandlerEscalation(
          escalationId: 'e1',
          terminalId: 't1',
          question: 'q',
          reasoning: 'because of this',
          draftReply: 'd',
          urgency: 'high',
          at: 1,
          floorRule: 'never touch prod',
          nonBlocking: true,
          askOptions: const [
            HandlerAskOption(choiceId: 'a', label: 'A', cost: 'costs a'),
          ],
        ),
        onChoice: (_) => true,
      );

      expect(find.textContaining('never touch prod'), findsOneWidget);
      expect(find.text(handlerAskLatencyNote), findsOneWidget);
      // The one thing this disclosure is allowed to hide.
      expect(find.text('because of this'), findsNothing);
    },
  );

  testWidgets('a card with no reasoning draws no Why row', (tester) async {
    await _pumpCard(
      tester,
      HandlerEscalation(
        escalationId: 'e1',
        terminalId: 't1',
        question: 'q',
        reasoning: '',
        draftReply: 'd',
        urgency: 'normal',
        at: 1,
        choices: _choices,
      ),
      onChoice: (_) => true,
    );
    expect(find.text('Why'), findsNothing);
  });

  testWidgets(
    'opens on the fallback question, where reason is the only informative text',
    (tester) async {
      final escalation = HandlerEscalation(
        escalationId: 'e1',
        terminalId: 't1',
        question: handlerFallbackQuestion,
        reasoning: 'the provider limit keeps returning',
        draftReply: 'd',
        urgency: 'high',
        at: 1,
        choices: _choices,
      );
      await _pumpCard(tester, escalation, onChoice: (_) => true);

      // Not collapsed by default here: `notify.body` was empty, so `reason`
      // is the sole informative text on the card, and hiding it would leave
      // a card whose visible half says nothing.
      expect(find.text(escalation.reasoning), findsOneWidget);
    },
  );

  testWidgets('a card recycled onto a fallback-question escalation opens too', (
    tester,
  ) async {
    final e1 = _escalation('e1');
    await _pumpCard(tester, e1, onChoice: (_) => true);
    expect(find.text(e1.reasoning), findsNothing);

    final e2 = HandlerEscalation(
      escalationId: 'e2',
      terminalId: 't1',
      question: handlerFallbackQuestion,
      reasoning: 'repeated transient failures',
      draftReply: 'd',
      urgency: 'high',
      at: 1,
      choices: _choices,
    );
    await _pumpCard(tester, e2, onChoice: (_) => true);
    expect(find.text(e2.reasoning), findsOneWidget);
  });
}
