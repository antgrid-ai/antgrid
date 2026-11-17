import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

// Upstream references are Carbon v11 styles/scss/components/*.

Widget _host(Widget child) =>
    Align(alignment: Alignment.topLeft, child: SizedBox(width: 320, child: child));

Finder _box(Type owner) =>
    find.descendant(of: find.byType(owner), matching: find.byType(CarbonFieldBox));

Finder _errorGlyph() => find.byWidgetPredicate(
  (w) => w is CarbonIcon && w.icon == CarbonIcons.warningFilled,
);

Color? _fillOf(WidgetTester tester, Finder box) {
  final decorated = tester.widget<DecoratedBox>(
    find.descendant(of: box, matching: find.byType(DecoratedBox)).first,
  );
  return (decorated.decoration as BoxDecoration).color;
}

Future<void> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: tester.getCenter(target));
  await tester.pump();
}

void main() {
  final theme = CarbonThemeData();

  group('field text inset (text-input.scss padding-inline spacing-05)', () {
    testWidgets('text starts 16px in at every size', (tester) async {
      for (final size in CarbonFieldSize.values) {
        await pumpCarbon(tester, _host(CarbonTextInput(label: 'L', size: size)));
        final box = tester.getRect(_box(CarbonTextInput));
        final text = tester.getRect(find.byType(EditableText));
        expect(text.left - box.left, 16, reason: '$size');
      }
    });

    testWidgets('error glyph ends 16px from the end edge', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'L', errorText: 'Bad')),
      );
      final box = tester.getRect(_box(CarbonTextInput));
      final glyph = tester.getRect(_errorGlyph());
      expect(box.right - glyph.right, 16);
    });
  });

  group('no hover fill (text-input.scss and search.scss have no :hover)', () {
    testWidgets('text input keeps the field fill under the pointer', (
      tester,
    ) async {
      await pumpCarbon(tester, _host(const CarbonTextInput(label: 'L')));
      await _hover(tester, _box(CarbonTextInput));
      expect(_fillOf(tester, _box(CarbonTextInput)), theme.field(1));
    });

    testWidgets('search keeps the field fill under the pointer', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSearch()));
      await _hover(tester, _box(CarbonSearch));
      expect(_fillOf(tester, _box(CarbonSearch)), theme.field(1));
    });
  });

  group('search offsets (search.scss padding 0 height; icon (height-1rem)/2)', () {
    for (final entry in <CarbonFieldSize, List<double>>{
      CarbonFieldSize.small: <double>[8, 32],
      CarbonFieldSize.medium: <double>[12, 40],
    }.entries) {
      testWidgets('${entry.key.name}: icon ${entry.value[0]}, text ${entry.value[1]}', (
        tester,
      ) async {
        await pumpCarbon(tester, _host(CarbonSearch(size: entry.key)));
        final box = tester.getRect(_box(CarbonSearch));
        final icon = tester.getRect(find.byType(CarbonIcon).first);
        final text = tester.getRect(find.byType(EditableText));
        expect(icon.left - box.left, entry.value[0]);
        expect(text.left - box.left, entry.value[1]);
      });
    }
  });

  group('multiline is a text area (text-area.scss)', () {
    Widget area({String? error}) => _host(
      CarbonTextInput(
        label: 'L',
        variant: CarbonTextInputVariant.multiline,
        errorText: error,
      ),
    );

    testWidgets('body-01 14/20 type', (tester) async {
      await pumpCarbon(tester, area());
      final style = tester.widget<EditableText>(find.byType(EditableText)).style;
      expect(style.fontSize, 14);
      expect(style.fontSize! * style.height!, closeTo(20, 0.001));
    });

    testWidgets('11px above and 8px below the text', (tester) async {
      await pumpCarbon(tester, area());
      final box = tester.getRect(_box(CarbonTextInput));
      final text = tester.getRect(find.byType(EditableText));
      expect(text.top - box.top, 11);
      expect(box.bottom - text.bottom, 8);
    });

    testWidgets('error glyph sits 12px from the top', (tester) async {
      await pumpCarbon(tester, area(error: 'Bad'));
      final box = tester.getRect(_box(CarbonTextInput));
      final glyph = tester.getRect(_errorGlyph());
      expect(glyph.top - box.top, 12);
    });
  });

  group('search clear pressed (search.scss .cds--search-close:active)', () {
    testWidgets('fills background-selected', (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(tester, _host(CarbonSearch(controller: controller)));
      final action = find.byType(CarbonFieldAction);
      final gesture = await tester.startGesture(tester.getCenter(action));
      await tester.pump(const Duration(milliseconds: 200));
      final fills = tester
          .widgetList<ColoredBox>(
            find.descendant(of: action, matching: find.byType(ColoredBox)),
          )
          .map((w) => w.color);
      expect(fills, contains(theme.colors.backgroundSelected));
      await gesture.cancel();
    });
  });

  group('disabled password (text-input.scss icon-disabled toggle)', () {
    testWidgets('keeps the view icon, inert', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label: 'L',
            variant: CarbonTextInputVariant.password,
            enabled: false,
          ),
        ),
      );
      final action = find.byType(CarbonFieldAction);
      expect(action, findsOneWidget);
      expect(tester.widget<CarbonFieldAction>(action).onPressed, isNull);
    });
  });

  group('disabled search (search.scss icon-on-color-disabled)', () {
    testWidgets('magnifier colour', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSearch(enabled: false)));
      final icon = tester.widget<CarbonIcon>(find.byType(CarbonIcon).first);
      expect(icon.color, theme.colors.iconOnColorDisabled);
    });

    testWidgets('placeholder is painted in the field fill', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSearch(enabled: false)));
      final hint = tester.widget<Text>(
        find.descendant(of: find.byType(CarbonSearch), matching: find.text('Search')),
      );
      expect(hint.style!.color, theme.field(1));
    });
  });

  group('character counter (TextInput.tsx cds--label, form.scss text-secondary)', () {
    testWidgets('label type in text-secondary', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'L', maxLength: 10, showCounter: true)),
      );
      final text = tester.widget<Text>(find.text('0/10'));
      expect(text.style!.color, theme.colors.textSecondary);
      expect(text.style!.fontSize, theme.typography.label.fontSize);
    });
  });
}
