import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _target = Key('target');

Widget _row({
  VoidCallback? onPressed,
  VoidCallback? onDoublePressed,
  FocusNode? focusNode,
}) => Center(
  child: CarbonInteraction(
    key: _target,
    onPressed: onPressed ?? () {},
    onDoublePressed: onDoublePressed,
    focusNode: focusNode,
    label: 'Row',
    excludeChildSemantics: true,
    builder: (_, _, _) => const SizedBox(width: 120, height: 32),
  ),
);

void main() {
  testWidgets('a single press runs at once, never waiting for a second', (
    tester,
  ) async {
    var presses = 0;
    var doubles = 0;
    await pumpCarbon(
      tester,
      _row(onPressed: () => presses++, onDoublePressed: () => doubles++),
    );
    await tester.tap(find.byKey(_target));
    await tester.pump();
    expect(presses, 1);
    expect(doubles, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(presses, 1);
    expect(doubles, 0);
  });

  testWidgets('a second press inside the window runs only the double once', (
    tester,
  ) async {
    var presses = 0;
    var doubles = 0;
    await pumpCarbon(
      tester,
      _row(onPressed: () => presses++, onDoublePressed: () => doubles++),
    );
    await tester.tap(find.byKey(_target));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(_target));
    await tester.pump();
    expect(presses, 1);
    expect(doubles, 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(presses, 1);
    expect(doubles, 1);
  });

  testWidgets('keyboard activation never doubles', (tester) async {
    var presses = 0;
    var doubles = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(
      tester,
      _row(
        onPressed: () => presses++,
        onDoublePressed: () => doubles++,
        focusNode: node,
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(presses, 3);
    expect(doubles, 0);
  });

  testWidgets('a secondary click neither activates nor suppresses its tap', (
    tester,
  ) async {
    var presses = 0;
    var doubles = 0;
    var secondary = 0;
    await pumpCarbon(
      tester,
      Center(
        child: CarbonInteraction(
          key: _target,
          onPressed: () => presses++,
          onDoublePressed: () => doubles++,
          onSecondaryTap: () => secondary++,
          label: 'Row',
          excludeChildSemantics: true,
          builder: (_, _, _) => const SizedBox(width: 120, height: 32),
        ),
      ),
    );
    await tester.tap(find.byKey(_target), buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(_target), buttons: kSecondaryButton);
    await tester.pump();
    expect(presses, 0);
    expect(doubles, 0);
    expect(secondary, 2);
  });
}
