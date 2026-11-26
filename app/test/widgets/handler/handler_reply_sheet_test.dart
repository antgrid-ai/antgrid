import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/widgets/handler/handler_reply_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _esc = HandlerEscalation(
  escalationId: 'e1',
  terminalId: 't1',
  question: 'bun or vitest for the new package?',
  reasoning: 'Affects CI wiring and the lockfile.',
  draftReply: 'use bun',
  urgency: 'high',
  at: 1,
);

Future<String?> _open(WidgetTester tester) async {
  String? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async =>
                  result = await showHandlerReplySheet(context, _esc),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('shows the question and the draft, with the Why collapsed', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _open(tester);
    expect(find.textContaining('bun or vitest'), findsOneWidget);
    expect(find.text('use bun'), findsOneWidget); // prefilled field
    // The judge is promised its reasoning is read afterward and never in
    // order to answer. This sheet is where the answer is composed, so an
    // always-open block here would push the field below the question it is
    // meant to sit under and make that promise false where it counts.
    expect(find.textContaining('Affects CI wiring'), findsNothing);
    expect(find.text('Why'), findsOneWidget);

    await tester.tap(find.text('Why'));
    await tester.pump();
    expect(find.textContaining('Affects CI wiring'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Approve & send returns the (edited) field text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    String? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    captured = await showHandlerReplySheet(context, _esc),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'use vitest');
    await tester.tap(find.text('Approve & send'));
    await tester.pumpAndSettle();

    expect(captured, 'use vitest');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Approve & send is disabled while the field is empty', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const escNoDraft = HandlerEscalation(
      escalationId: 'e1',
      terminalId: 't1',
      question: 'q',
      reasoning: 'r',
      draftReply: '',
      urgency: 'normal',
      at: 1,
    );
    String? captured = 'sentinel';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    captured = await showHandlerReplySheet(context, escNoDraft),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Empty draft → tapping the primary action is a no-op; the sheet stays open.
    await tester.tap(find.text('Approve & send'));
    await tester.pumpAndSettle();
    expect(find.text('Approve & send'), findsOneWidget);
    expect(captured, 'sentinel');

    // Typing enables it.
    await tester.enterText(find.byType(TextField), 'do it');
    await tester.pump();
    await tester.tap(find.text('Approve & send'));
    await tester.pumpAndSettle();
    expect(captured, 'do it');

    debugDefaultTargetPlatformOverride = null;
  });
}
