import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_composer_send_button.dart';
import 'package:antgrid/widgets/terminal_compose_box.dart';

void main() {
  late TextEditingController draft;
  late FocusNode focus;
  final sent = <String>[];

  setUp(() {
    draft = TextEditingController();
    focus = FocusNode();
    sent.clear();
  });
  tearDown(() {
    draft.dispose();
    focus.dispose();
  });

  Future<void> pump(WidgetTester tester, {int maxLines = 10}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 400,
                child: TerminalComposeBox(
                  draft: draft,
                  focusNode: focus,
                  maxLines: maxLines,
                  onSend: sent.add,
                ),
              ),
            ),
          ),
        ),
      );

  // Measured rather than read off the widget: a field once carried a large
  // maxLines while its box held it at a single row's height, so nothing past
  // the first line was ever visible.
  testWidgets('the box grows with each line of the draft', (tester) async {
    await pump(tester);
    double boxHeight() =>
        tester.getSize(find.byType(TerminalComposeBox)).height;

    final empty = boxHeight();
    await tester.enterText(
      find.byType(TextField),
      'one\ntwo\nthree\nfour\nfive\nsix',
    );
    await tester.pump();
    expect(boxHeight(), greaterThan(empty));

    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    expect(boxHeight(), empty);
  });

  testWidgets('Send needs text, then submits the whole draft', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(ComposerSendButton));
    await tester.pump();
    expect(sent, isEmpty);

    await tester.enterText(find.byType(TextField), 'a\nb');
    await tester.pump();
    await tester.tap(find.byType(ComposerSendButton));
    await tester.pump();
    expect(sent, ['a\nb']);
  });

  testWidgets('offers nothing but the field and Send', (tester) async {
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(ComposerSendButton), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.byTooltip('Direct input'), findsNothing);
    expect(find.text('Insert'), findsNothing);
  });

  testWidgets('a short pane caps the field so the box stays on screen', (
    tester,
  ) async {
    await pump(tester, maxLines: 2);
    await tester.enterText(find.byType(TextField), '1\n2\n3\n4\n5\n6\n7\n8');
    await tester.pump();
    // Two rows of the field's own line height plus the box's padding.
    expect(
      tester.getSize(find.byType(TerminalComposeBox)).height,
      lessThan(100),
    );
  });
}
