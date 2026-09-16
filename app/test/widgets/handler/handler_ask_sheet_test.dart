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

/// Opens the sheet and hands back a box holding whatever it eventually returns.
///
/// A box rather than a value: the future completes when the sheet pops, which is
/// after this returns, and reading it before then reports every outcome as null.
Future<List<HandlerAskSheetResult?>> _openBoxed(
  WidgetTester tester,
  HandlerEscalation e,
) async {
  final box = <HandlerAskSheetResult?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async =>
                  box.add(await showHandlerAskSheet(context, e)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return box;
}

Future<HandlerAskSheetResult?> _open(
  WidgetTester tester,
  HandlerEscalation e,
) async {
  HandlerAskSheetResult? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async =>
                  result = await showHandlerAskSheet(context, e),
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
    // Behind the same "Why" disclosure the card uses: the composer for the
    // answer must not sit below a block the judge was told is read afterward.
    expect(find.textContaining('Both are defensible'), findsNothing);
    expect(find.text('Why'), findsOneWidget);
    // The one thing this widget exists to guarantee: the draft on the row is
    // the judge's own words, and the text in this field is what mints a
    // session-long authorization lift.
    expect(find.text('migrate now'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Send answer returns what the user typed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    Object? captured = 'sentinel';
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
    expect((captured as HandlerAskAnswer).text, 'note the gap');

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('backing out of the sheet decides nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final box = await _openBoxed(tester, _ask);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Null, not a decline: the screen sends nothing at all on this arm, so a
    // user who opened the question to read it leaves it standing.
    expect(box, [null]);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('declining is a decision, and needs no text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final box = await _openBoxed(tester, _ask);
    // Live with the field empty, unlike Send answer beside it: refusing to
    // answer is not an answer of nothing. This is the only exit from a standing
    // ask that is not an answer — an ask survives a submitted line by design, so
    // without it the row stands until the work it named finishes and it is
    // promoted into a question the user must answer anyway.
    await tester.tap(find.text("Don't answer"));
    await tester.pumpAndSettle();
    expect(box.single, isA<HandlerAskDecline>());

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

  testWidgets('the Why opens the reasoning on tap', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _open(tester, _ask);

    await tester.tap(find.text('Why'));
    await tester.pump();
    expect(find.textContaining('Both are defensible'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an ask with no reasoning draws no Why row', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _open(
      tester,
      const HandlerEscalation(
        escalationId: 'ask-2',
        terminalId: 't1',
        question: 'Ship it?',
        reasoning: '',
        draftReply: '',
        urgency: 'normal',
        at: 1,
        nonBlocking: true,
      ),
    );

    expect(find.text('Why'), findsNothing);
    expect(find.textContaining('Ship it?'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
