import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _box = Key('box');

Widget _field({
  bool focused = false,
  bool enabled = true,
  bool readOnly = false,
  bool invalid = false,
  bool warn = false,
  String text = 'Value',
  Widget? trailingAction,
}) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(
    width: 300,
    child: CarbonFieldBox(
      key: _box,
      focused: focused,
      enabled: enabled,
      readOnly: readOnly,
      invalid: invalid,
      warn: warn,
      trailingAction: trailingAction,
      child: Text(text),
    ),
  ),
);

Color? _fill(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: find.byKey(_box), matching: find.byType(DecoratedBox)),
  );
  return (box.decoration as BoxDecoration).color;
}

dynamic _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find
          .descendant(of: find.byKey(_box), matching: find.byType(CustomPaint))
          .first,
    )
    .foregroundPainter;

Iterable<CarbonIcons> _icons(WidgetTester tester) => tester
    .widgetList<CarbonIcon>(
      find.descendant(of: find.byKey(_box), matching: find.byType(CarbonIcon)),
    )
    .map((icon) => icon.icon);

void main() {
  group('CarbonFieldBox', () {
    testWidgets('min height is 32 compact and 48 touch at text scale 1', (
      tester,
    ) async {
      await pumpCarbon(tester, _field());
      expect(tester.getSize(find.byKey(_box)).height, 32);

      await pumpCarbon(
        tester,
        _field(),
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      expect(tester.getSize(find.byKey(_box)).height, 48);
    });

    testWidgets('grows past the minimum at text scale 2', (tester) async {
      for (final density in CarbonDensity.values) {
        final theme = CarbonThemeData(density: density);
        await pumpCarbon(tester, _field(), theme: theme, textScale: 2);
        expect(
          tester.getSize(find.byKey(_box)).height,
          greaterThan(theme.controlHeight),
          reason: '$density',
        );
      }
    });

    testWidgets('state treatments never change the layout', (tester) async {
      await pumpCarbon(tester, _field());
      final base = tester.getRect(find.byKey(_box));
      for (final variant in <Widget>[
        _field(focused: true),
        _field(invalid: true, focused: true),
        _field(readOnly: true),
        _field(enabled: false),
      ]) {
        await pumpCarbon(tester, variant);
        expect(tester.getRect(find.byKey(_box)), base);
      }
    });

    testWidgets('fill follows the layer and hover', (tester) async {
      final theme = CarbonThemeData();
      await pumpCarbon(tester, _field());
      expect(_fill(tester), theme.field(1));

      await pumpCarbon(
        tester,
        CarbonLayer(level: 2, child: _field()),
      );
      expect(_fill(tester), theme.field(2));

      await pumpCarbon(tester, _field());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.byKey(_box)));
      await tester.pump();
      expect(_fill(tester), theme.fieldHover(1));
    });

    testWidgets('invalid shows the error glyph and outline', (tester) async {
      await pumpCarbon(tester, _field(invalid: true));
      expect(_icons(tester), <CarbonIcons>[CarbonIcons.errorFilled]);
      final colors = CarbonThemeData().colors;
      expect(_painter(tester).outline, colors.supportError);

      await pumpCarbon(tester, _field(invalid: true, focused: true));
      expect(_painter(tester).outline, colors.focus);
      expect(_icons(tester), <CarbonIcons>[CarbonIcons.errorFilled]);
    });

    testWidgets('warn shows the warning glyph without an outline', (
      tester,
    ) async {
      await pumpCarbon(tester, _field(warn: true));
      expect(_icons(tester), <CarbonIcons>[CarbonIcons.warningAltFilled]);
      expect(_painter(tester).outline, isNull);
    });

    testWidgets('read-only: transparent, subtle rule, no hover, no invalid', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(tester, _field(readOnly: true, invalid: true));
      expect(_fill(tester)!.a, 0);
      expect(_painter(tester).rule, theme.borderSubtle(1));
      expect(_painter(tester).outline, isNull);
      expect(_icons(tester), isEmpty);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.byKey(_box)));
      await tester.pump();
      expect(_fill(tester)!.a, 0);
    });

    testWidgets('disabled: no rule, disabled text color, no hover', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(tester, _field(enabled: false, warn: true));
      expect(_painter(tester).rule, isNull);
      expect(_icons(tester), isEmpty);
      final style = DefaultTextStyle.of(tester.element(find.text('Value')));
      expect(style.style.color, theme.colors.textDisabled);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.byKey(_box)));
      await tester.pump();
      expect(_fill(tester), theme.field(1));
    });

    testWidgets('trailing action sits flush with the end edge, RTL aware', (
      tester,
    ) async {
      const action = SizedBox(key: Key('action'), width: 32, height: 32);
      await pumpCarbon(tester, _field(trailingAction: action));
      expect(
        tester.getRect(find.byKey(const Key('action'))).right,
        tester.getRect(find.byKey(_box)).right,
      );
      await pumpCarbon(
        tester,
        _field(trailingAction: action),
        dir: TextDirection.rtl,
      );
      expect(
        tester.getRect(find.byKey(const Key('action'))).left,
        tester.getRect(find.byKey(_box)).left,
      );
      // Content starts after the start padding on the right in RTL.
      final theme = CarbonThemeData();
      expect(
        tester.getRect(find.text('Value')).right,
        tester.getRect(find.byKey(_box)).right - theme.controlPaddingX,
      );
    });
  });

  group('CarbonFieldFrame', () {
    Widget frame({
      String? helper = 'Helper',
      String? error,
      String? warn,
      bool required = false,
      bool showOptional = false,
      bool enabled = true,
      bool readOnly = false,
      bool merge = false,
    }) {
      Widget body = CarbonFieldFrame(
        label: 'Name',
        helperText: helper,
        errorText: error,
        warnText: warn,
        required: required,
        showOptional: showOptional,
        enabled: enabled,
        readOnly: readOnly,
        child: _field(),
      );
      if (merge) body = MergeSemantics(child: body);
      return Align(alignment: Alignment.topLeft, child: body);
    }

    testWidgets('label, field and helper stack with Carbon spacing', (
      tester,
    ) async {
      await pumpCarbon(tester, frame());
      final label = tester.getRect(find.text('Name'));
      final box = tester.getRect(find.byKey(_box));
      final helper = tester.getRect(find.text('Helper'));
      expect(box.top - label.bottom, CarbonSpacing.spacing03);
      expect(helper.top - box.bottom, CarbonSpacing.spacing02);
    });

    testWidgets('error replaces helper and uses the error color', (
      tester,
    ) async {
      final colors = CarbonThemeData().colors;
      await pumpCarbon(tester, frame(error: 'Required value'));
      expect(find.text('Helper'), findsNothing);
      final text = tester.widget<Text>(find.text('Required value'));
      expect(text.style!.color, colors.textError);
    });

    testWidgets('disabled and read-only suppress validation messages', (
      tester,
    ) async {
      await pumpCarbon(tester, frame(error: 'Bad', enabled: false));
      expect(find.text('Bad'), findsNothing);
      expect(find.text('Helper'), findsOneWidget);
      final label = tester.widget<Text>(find.text('Name'));
      expect(label.style!.color, CarbonThemeData().colors.textDisabled);

      await pumpCarbon(tester, frame(warn: 'Careful', readOnly: true));
      expect(find.text('Careful'), findsNothing);
    });

    testWidgets('optional suffix only with showOptional on optional fields', (
      tester,
    ) async {
      await pumpCarbon(tester, frame(showOptional: true));
      expect(find.text('Name (optional)'), findsOneWidget);
      await pumpCarbon(tester, frame(showOptional: true, required: true));
      expect(find.text('Name'), findsOneWidget);
    });

    testWidgets('merged semantics carry label, required and error', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        frame(required: true, error: 'Enter a name', merge: true),
      );
      final data = tester
          .getSemantics(find.byType(MergeSemantics))
          .getSemanticsData();
      expect(data.label, contains('Name'));
      expect(data.label, contains('Enter a name'));
      expect(data.hint, contains('Required'));
      expect(data.flagsCollection.isRequired, Tristate.isTrue);
      expect(data.validationResult, SemanticsValidationResult.invalid);
      handle.dispose();
    });

    testWidgets('excludeTextSemantics removes the visible strings', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        const CarbonFieldFrame(
          label: 'Name',
          errorText: 'Bad',
          excludeTextSemantics: true,
          child: SizedBox(width: 100, height: 32),
        ),
      );
      expect(find.bySemanticsLabel('Name'), findsNothing);
      expect(find.bySemanticsLabel('Bad'), findsNothing);
      handle.dispose();
    });
  });
}
