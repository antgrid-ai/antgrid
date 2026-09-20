import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_search_field.dart';

/// Rendered pixels between the magnifier and where the text begins.
///
/// Measured, never read off the parameters: the inset that looks like it
/// should control this ([AbTextField.contentPadding]) is the surrounding
/// box's padding and moves the GLYPH too, so a test that asserts what the
/// field was passed passes while the glyph still sits against the text.
double glyphToText(WidgetTester tester) =>
    tester.getRect(find.byType(EditableText)).left -
    tester.getRect(find.byType(AbIcon)).right;

/// How far the glyph sits from the field's own left edge. A caller aligning it
/// to a column outside the field is owed this unchanged.
double glyphInset(WidgetTester tester) =>
    tester.getRect(find.byType(AbIcon)).left -
    tester.getRect(find.byType(AbSearchField)).left;

Future<void> pump(WidgetTester tester, {double? prefixIconWidth}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: AbSearchField(
              hint: 'Filter files...',
              // Mirrors FileSearchBar, the caller this guards: borderless, so
              // the glyph's inset is the alignment itself and not a stray
              // pixel of outline.
              border: false,
              height: AbTokens.rowHeightXs,
              prefixIconWidth: prefixIconWidth,
            ),
          ),
        ),
      ),
    );

void main() {
  group('AbSearchField prefix gap', () {
    testWidgets('a full-height square carries the gap in its own margins', (
      tester,
    ) async {
      await pump(tester);

      expect(glyphToText(tester), greaterThanOrEqualTo(AbTokens.space4));
    });

    // The regression: squaring the slot to the glyph, so the magnifier lines
    // up with the disclosure chevrons below it, left the glyph with no margin
    // at all and the hint ran straight into it.
    testWidgets('a glyph-sized square still leaves the text room', (
      tester,
    ) async {
      await pump(tester, prefixIconWidth: AbTokens.iconButtonGlyph);

      expect(glyphToText(tester), AbTokens.space8);
    });

    // ...and the gap must not be bought by moving the glyph, which is the
    // whole reason the slot was narrowed.
    testWidgets('the gap does not push the glyph out of its column', (
      tester,
    ) async {
      await pump(tester, prefixIconWidth: AbTokens.iconButtonGlyph);
      final narrow = glyphInset(tester);

      expect(narrow, 0);
    });
  });
}
