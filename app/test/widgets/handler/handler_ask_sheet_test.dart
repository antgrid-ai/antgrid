import 'dart:io';

import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/widgets/handler/handler_ask_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A judge-authored draft on the row, which the reply sheet would seed its
// controller from. An ask is minted with an empty one, so this is the shape
// this sheet must refuse even when the wire hands it one.
const _ask = HandlerEscalation(
  escalationId: 'ask-1',
  terminalId: 't1',
  question: 'Migrate the schema now, or note the gap and carry on?',
  reasoning: 'Both are defensible and the tests pass either way.',
  draftReply: 'migrate now',
  urgency: 'normal',
  at: 1,
  nonBlocking: true,
);

Future<String?> _open(WidgetTester tester, HandlerEscalation e) async {
  String? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async => result = await showHandlerAskSheet(
                context,
                e,
              ),
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
  testWidgets('opens on the question with an empty composer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _open(tester, _ask);

    expect(find.text('Handler has a question'), findsOneWidget);
    expect(find.textContaining('Migrate the schema now'), findsOneWidget);
    expect(find.textContaining('Both are defensible'), findsOneWidget);
    // The one thing this widget exists to guarantee: the draft on the row is
    // the judge's own words, and the text in this field is what mints a
    // session-long authorization lift.
    expect(find.text('migrate now'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, '');

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Send answer returns what the user typed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    String? captured = 'sentinel';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    captured = await showHandlerAskSheet(context, _ask),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Empty field → the primary action is inert and the sheet stays open. An
    // answer of nothing retires the question on this side and is refused on the
    // other, which reads as an answer given and then lost.
    await tester.tap(find.text('Send answer'));
    await tester.pumpAndSettle();
    expect(find.text('Send answer'), findsOneWidget);
    expect(captured, 'sentinel');

    await tester.enterText(find.byType(TextField), 'note the gap');
    await tester.pump();
    await tester.tap(find.text('Send answer'));
    await tester.pumpAndSettle();
    expect(captured, 'note the gap');

    debugDefaultTargetPlatformOverride = null;
  });

  test('the sheet has no way to prefill, by construction', () {
    // The behavioural test above passes for a sheet that merely happens to be
    // handed an empty draft. This one reads the source: a prefill added later
    // has to name the field, and naming it fails here — which is the whole
    // reason an ask gets its own widget instead of a branch inside the reply
    // sheet, where the seeding line already exists one refactor away.
    final source = File('lib/widgets/handler/handler_ask_sheet.dart');
    expect(
      source.existsSync(),
      isTrue,
      reason: '${source.absolute.path} is gone — this gate is reading nothing.',
    );
    final code = source
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('draftReply'), isFalse);
  });
}
