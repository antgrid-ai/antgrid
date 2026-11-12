import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart'
    show
        InputDecoration,
        InputDecorationTheme,
        InputDecorator,
        Material,
        MaterialType,
        OutlineInputBorder,
        TextField,
        Theme,
        ThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Color _border = Color(0xFFFF00FF);
const Color _focused = Color(0xFF00FFFF);
const Color _fill = Color(0xFF00FF00);

// A host app whose fields are filled and outlined, as most Material apps'
// are. Carbon's field box owns its own fill and border, so none of this may
// reach the text fields inside it.
final ThemeData _hostTheme = ThemeData(
  inputDecorationTheme: const InputDecorationTheme(
    filled: true,
    fillColor: _fill,
    border: OutlineInputBorder(borderSide: BorderSide(color: _border)),
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _border)),
    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: _focused)),
    disabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _border)),
  ),
);

bool _usesHostColor(Symbol _, List<dynamic> args) => args.any(
  (a) =>
      a is Paint &&
      (a.color == _border || a.color == _focused || a.color == _fill),
);

Widget _host(Widget child) => Theme(
  data: _hostTheme,
  child: Align(
    alignment: AlignmentDirectional.topStart,
    child: SizedBox(width: 320, child: child),
  ),
);

Future<void> _expectNoHostPaint(WidgetTester tester) async {
  final decorators = find.byType(InputDecorator);
  expect(decorators, findsWidgets);
  for (final focus in [false, true]) {
    if (focus) {
      await tester.tap(find.byType(EditableText).first);
      await tester.pump();
    }
    for (var i = 0; i < tester.widgetList(decorators).length; i++) {
      expect(
        decorators.at(i),
        isNot(paints..something(_usesHostColor)),
        reason: 'decorator $i, focused: $focus',
      );
    }
  }
}

void main() {
  testWidgets('the probe catches a collapsed decoration under the host theme',
      (tester) async {
    await pumpCarbon(
      tester,
      _host(
        const Material(
          type: MaterialType.transparency,
          child: TextField(
            decoration: InputDecoration.collapsed(hintText: 'x'),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(find.byType(InputDecorator), paints..something(_usesHostColor));
  });

  testWidgets('text inputs paint no host input decoration', (tester) async {
    await pumpCarbon(
      tester,
      _host(
        const Column(
          children: [
            CarbonTextInput(label: 'Name', placeholder: 'Schedule name'),
            CarbonTextInput(
              label: 'Prompt',
              variant: CarbonTextInputVariant.multiline,
              minLines: 3,
              placeholder: 'What should the agent do?',
            ),
          ],
        ),
      ),
    );
    await _expectNoHostPaint(tester);
  });

  testWidgets('search paints no host input decoration, with either hint',
      (tester) async {
    await pumpCarbon(
      tester,
      _host(
        const Column(
          children: [
            CarbonSearch(semanticLabel: 'Find', placeholder: 'Find'),
            CarbonSearch(semanticLabel: 'Find', placeholder: 'Type a name'),
          ],
        ),
      ),
    );
    await _expectNoHostPaint(tester);
  });

  testWidgets('combo box paints no host input decoration', (tester) async {
    await pumpCarbon(
      tester,
      _host(
        CarbonComboBox<String>(
          label: 'Project',
          placeholder: 'Pick one',
          options: const [CarbonOption(value: 'a', label: 'Alpha')],
          value: null,
          onChanged: (_) {},
        ),
      ),
    );
    await _expectNoHostPaint(tester);
  });
}
