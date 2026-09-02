import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_control_box.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_harness.dart';

const _long =
    'A correction long enough to wrap several times over at this width, which '
    'is the only shape in which a growing field differs at all from the '
    'single-row one every other caller of this primitive asks for.';

Future<void> _pumpField(
  WidgetTester tester, {
  int? minLines,
  int maxLines = 1,
  String? text,
}) {
  final controller = TextEditingController(text: text ?? '');
  addTearDown(controller.dispose);
  return pumpAntgrid(
    tester,
    SizedBox(
      width: 300,
      child: AbTextField(
        controller: controller,
        minLines: minLines,
        maxLines: maxLines,
      ),
    ),
  );
}

AbControlBox _box(WidgetTester tester) =>
    tester.widget<AbControlBox>(find.byType(AbControlBox));

Row _row(WidgetTester tester) => tester.widget<Row>(
  find
      .descendant(of: find.byType(AbControlBox), matching: find.byType(Row))
      .first,
);

double _height(WidgetTester tester) =>
    tester.getSize(find.byType(AbControlBox)).height;

void main() {
  // Every field in the app but one is this one — the sign-in form,
  // AbSearchField, AbUrlField, the composer — and the wrapping branch forks
  // four visual properties away from it. Nothing else in the suite would
  // notice if the fork inverted.
  testWidgets('a single-line field is one row of exactly rowHeightSm', (
    tester,
  ) async {
    await _pumpField(tester, text: _long);

    expect(_height(tester), AbTokens.rowHeightSm);
    expect(_box(tester).minHeight, isNull);
    // Null leaves AbControlBox's own horizontal-only default standing. A
    // vertical inset leaking in here would squeeze the text in every dense row
    // and toolbar in the app.
    expect(_box(tester).padding, isNull);
    expect(_row(tester).crossAxisAlignment, CrossAxisAlignment.center);
  });

  testWidgets('a wrapping field takes that height as a floor, not a cap', (
    tester,
  ) async {
    await _pumpField(tester, minLines: 1, maxLines: 6);
    final atOneLine = _height(tester);

    // A floor and nothing more: `height` is a floor and a ceiling at once, and
    // set here it would hold the box at one row while the text ran out of it.
    expect(_box(tester).height, isNull);
    expect(_box(tester).minHeight, AbTokens.rowHeightSm);
    expect(atOneLine, greaterThanOrEqualTo(AbTokens.rowHeightSm));
    // The prefix and clear slots belong beside the first line, not halfway
    // down the paragraph.
    expect(_row(tester).crossAxisAlignment, CrossAxisAlignment.start);

    await _pumpField(tester, minLines: 1, maxLines: 6, text: _long);
    expect(_height(tester), greaterThan(atOneLine));
  });
}
