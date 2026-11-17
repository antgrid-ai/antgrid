import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _host(Widget child, {double width = 320}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Finder get _editable => find.byType(EditableText);

void main() {
  group('editing connection survives the clear action appearing', () {
    for (final entry in <(String, Widget Function(TextEditingController))>[
      ('search', (c) => CarbonSearch(controller: c)),
      ('clearable text input', (c) => CarbonTextInput(controller: c, clearable: true)),
    ]) {
      testWidgets(entry.$1, (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await pumpCarbon(tester, _host(entry.$2(controller)));
        await tester.showKeyboard(_editable);
        final before = tester.state(_editable);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'a',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();
        expect(tester.state(_editable), same(before));
        expect(tester.testTextInput.hasAnyClients, isTrue);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ab',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();
        expect(controller.text, 'ab');

        await tester.tap(find.byType(CarbonFieldAction));
        await tester.pump();
        expect(controller.text, '');
        expect(tester.state(_editable), same(before));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'x',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();
        expect(controller.text, 'x');
      });
    }
  });

  testWidgets('a revealed password hides again when the field is disabled', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'secret');
    addTearDown(controller.dispose);
    Widget build({required bool enabled}) => _host(
      CarbonTextInput(
        controller: controller,
        variant: CarbonTextInputVariant.password,
        enabled: enabled,
      ),
    );
    await pumpCarbon(tester, build(enabled: true));
    await tester.tap(find.bySemanticsLabel('Show password'));
    await tester.pump();
    expect(tester.widget<EditableText>(_editable).obscureText, isFalse);
    await pumpCarbon(tester, build(enabled: false));
    expect(tester.widget<EditableText>(_editable).obscureText, isTrue);
  });

  testWidgets('multiline maxLines below the default minimum is accepted', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _host(
        const CarbonTextInput(
          label: 'Notes',
          variant: CarbonTextInputVariant.multiline,
          maxLines: 2,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, lessThanOrEqualTo(field.maxLines!));
  });

  testWidgets('Escape closes an open selection toolbar before clearing', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'needle');
    addTearDown(controller.dispose);
    var cleared = 0;
    await pumpCarbon(
      tester,
      _host(CarbonSearch(controller: controller, onCleared: () => cleared++)),
    );
    await tester.tap(_editable);
    await tester.pump();
    final state = tester.state<EditableTextState>(_editable);
    state.showToolbar();
    await tester.pump();
    expect(state.selectionOverlay?.toolbarIsVisible, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.text, 'needle');
    expect(cleared, 0);
    expect(state.selectionOverlay?.toolbarIsVisible ?? false, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.text, '');
    expect(cleared, 1);
  });

  testWidgets('the search icon uses the secondary icon colour', (tester) async {
    await pumpCarbon(tester, _host(const CarbonSearch()));
    final theme = CarbonTheme.of(tester.element(find.byType(CarbonSearch)));
    final icon = find.descendant(
      of: find.byType(CarbonSearch),
      matching: find.byType(CarbonIcon),
    );
    final color = tester.widget<CarbonIcon>(icon.first).color;
    expect(color, theme.colors.iconSecondary);
  });

  testWidgets('hover fill on an action leaves the focus outline uncovered', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    await pumpCarbon(tester, _host(CarbonSearch(controller: controller)));
    await tester.tap(_editable);
    await tester.pump();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(CarbonFieldAction)));
    await tester.pump();
    final box = tester.getRect(find.byType(CarbonFieldBox));
    final fill = find.descendant(
      of: find.byType(CarbonFieldAction),
      matching: find.byType(ColoredBox),
    );
    final hoverFill = tester.getRect(fill.first);
    expect(hoverFill.top, greaterThanOrEqualTo(box.top + 2));
    expect(hoverFill.bottom, lessThanOrEqualTo(box.bottom - 2));
    expect(hoverFill.right, lessThanOrEqualTo(box.right - 2));
  });
}
