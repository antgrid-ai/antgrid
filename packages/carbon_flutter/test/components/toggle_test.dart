import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _tg = Key('tg');

Widget _aligned(Widget child, {double width = 400}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Widget _toggle({
  required bool value,
  ValueChanged<bool>? onChanged,
  bool small = false,
  bool readOnly = false,
  bool busy = false,
  bool hideStateText = false,
  String? labelText = 'Auto-save',
  FocusNode? focusNode,
}) => _aligned(
  CarbonToggle(
    key: _tg,
    value: value,
    onChanged: onChanged,
    small: small,
    readOnly: readOnly,
    busy: busy,
    hideStateText: hideStateText,
    labelText: labelText,
    semanticLabel: labelText == null ? 'Hidden label' : null,
    focusNode: focusNode,
  ),
);

Finder get _hit => find.descendant(
  of: find.byKey(_tg),
  matching: find.byType(CarbonInteraction),
);

Size _trackSize(WidgetTester tester) {
  final boxes = find
      .descendant(of: find.byKey(_tg), matching: find.byType(SizedBox))
      .evaluate()
      .map((e) => (e.renderObject! as RenderBox).size)
      .where((s) => s.height == 24 || s.height == 16);
  return boxes.first;
}

void main() {
  group('display', () {
    testWidgets('shows exactly the host value, never flips on its own', (
      tester,
    ) async {
      final requests = <bool>[];
      await pumpCarbon(
        tester,
        _toggle(value: false, onChanged: requests.add),
      );
      expect(find.text('Off'), findsOneWidget);
      await tester.tap(_hit);
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests, [true]);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('On'), findsNothing);

      await pumpCarbon(tester, _toggle(value: true, onChanged: requests.add));
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('label is visible and state text can be hidden', (
      tester,
    ) async {
      await pumpCarbon(tester, _toggle(value: true, onChanged: (_) {}));
      expect(find.text('Auto-save'), findsOneWidget);
      await pumpCarbon(
        tester,
        _toggle(value: true, onChanged: (_) {}, hideStateText: true),
      );
      expect(find.text('On'), findsNothing);
    });

    testWidgets('track sizes: default 48x24, small 32x16', (tester) async {
      await pumpCarbon(tester, _toggle(value: true, onChanged: (_) {}));
      expect(_trackSize(tester), const Size(48, 24));
      await pumpCarbon(
        tester,
        _toggle(value: true, onChanged: (_) {}, small: true),
      );
      expect(_trackSize(tester), const Size(32, 16));
    });
  });

  group('sizing', () {
    testWidgets('target is at least minTarget in both densities', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        _toggle(value: false, onChanged: (_) {}, labelText: null),
      );
      expect(tester.getSize(find.byKey(_tg)).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byKey(_tg)).height, 48);
    });

    testWidgets('survives 200% text at 320px', (tester) async {
      await pumpCarbon(
        tester,
        _toggle(
          value: true,
          onChanged: (_) {},
          labelText: 'A rather long setting name that has to wrap around',
        ),
        textScale: 2,
        size: const Size(320, 600),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('activation', () {
    testWidgets('tap requests the opposite value once', (tester) async {
      final requests = <bool>[];
      await pumpCarbon(tester, _toggle(value: true, onChanged: requests.add));
      await tester.tap(find.text('On'));
      await tester.pump();
      expect(requests, [false]);
    });

    testWidgets('space and enter activate', (tester) async {
      final requests = <bool>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _toggle(value: false, onChanged: requests.add, focusNode: node),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(requests, [true, true]);
    });

    testWidgets('disabled is inert and unfocusable', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, _toggle(value: false, focusNode: node));
      await tester.tap(_hit);
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });

    testWidgets('read-only is focusable but never requests', (tester) async {
      final requests = <bool>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _toggle(
          value: true,
          readOnly: true,
          onChanged: requests.add,
          focusNode: node,
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.tap(_hit);
      await tester.pump();
      expect(node.hasFocus, isTrue);
      expect(requests, isEmpty);
    });

    testWidgets('busy blocks activation, keeps focus and value', (
      tester,
    ) async {
      final requests = <bool>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _toggle(
          value: false,
          busy: true,
          onChanged: requests.add,
          focusNode: node,
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.tap(_hit);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 100));
      expect(requests, isEmpty);
      expect(node.hasFocus, isTrue);
      expect(find.text('Off'), findsOneWidget);
      expect(find.byType(CarbonSpinner), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('label, toggled state and busy value', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _toggle(value: true, onChanged: (_) {}));
      var node = tester
          .getSemantics(find.bySemanticsLabel('Auto-save'))
          .getSemanticsData();
      expect(node.flagsCollection.isToggled, isNot(Tristate.none));
      expect(node.flagsCollection.isToggled, Tristate.isTrue);

      await pumpCarbon(tester, _toggle(value: false, onChanged: (_) {}));
      node = tester
          .getSemantics(find.bySemanticsLabel('Auto-save'))
          .getSemanticsData();
      expect(node.flagsCollection.isToggled, Tristate.isFalse);

      await pumpCarbon(
        tester,
        _toggle(value: false, busy: true, onChanged: (_) {}),
      );
      node = tester
          .getSemantics(find.bySemanticsLabel('Auto-save'))
          .getSemanticsData();
      expect(node.value, 'Loading');
      handle.dispose();
    });

    testWidgets('hidden label falls back to the semantic label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _toggle(value: true, onChanged: (_) {}, labelText: null),
      );
      expect(find.bySemanticsLabel('Hidden label'), findsOneWidget);
      handle.dispose();
    });
  });

  group('motion', () {
    Offset handleCenter(WidgetTester tester) {
      final handle = find
          .descendant(of: find.byKey(_tg), matching: find.byType(DecoratedBox))
          .evaluate()
          .map((e) => e.renderObject! as RenderBox)
          .where((b) => b.size == const Size.square(18))
          .first;
      return handle.localToGlobal(const Offset(9, 9));
    }

    testWidgets('handle slides over time', (tester) async {
      await pumpCarbon(tester, _toggle(value: false, onChanged: (_) {}));
      final before = handleCenter(tester).dx;
      await pumpCarbon(tester, _toggle(value: true, onChanged: (_) {}));
      await tester.pump(const Duration(milliseconds: 20));
      final mid = handleCenter(tester).dx;
      await tester.pump(const Duration(milliseconds: 200));
      final after = handleCenter(tester).dx;
      expect(mid, greaterThan(before));
      expect(mid, lessThan(after));
    });

    testWidgets('handle jumps under reduced motion', (tester) async {
      await pumpCarbon(
        tester,
        _toggle(value: false, onChanged: (_) {}),
        reduceMotion: true,
      );
      final before = handleCenter(tester).dx;
      await pumpCarbon(
        tester,
        _toggle(value: true, onChanged: (_) {}),
        reduceMotion: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final after = handleCenter(tester).dx;
      expect(after - before, 24);
    });
  });

  group('live changes', () {
    testWidgets('direction flips the handle side; focus survives', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final harness = await pumpCarbon(
        tester,
        _toggle(value: true, onChanged: (_) {}, focusNode: node),
      );
      node.requestFocus();
      await tester.pump();
      harness.direction.value = TextDirection.rtl;
      await tester.pump(const Duration(milliseconds: 300));
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(node.hasFocus, isTrue);
      expect(tester.getTopRight(find.byKey(_tg)).dx, 800);
    });

    testWidgets('repeated mount and unmount is clean', (tester) async {
      for (var i = 0; i < 3; i++) {
        await pumpCarbon(
          tester,
          _toggle(value: true, busy: true, onChanged: (_) {}),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await pumpCarbon(tester, const SizedBox.shrink());
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('accessible name and states', () {
    testWidgets('a custom label widget names the switch', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonToggle(
            value: true,
            onChanged: (_) {},
            label: const Text('Auto-save'),
          ),
        ),
      );
      final node = tester
          .getSemantics(find.bySemanticsLabel('Auto-save'))
          .getSemanticsData();
      expect(node.flagsCollection.isToggled, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('read-only is announced as read-only', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _toggle(value: true, readOnly: true, onChanged: (_) {}),
      );
      final node = tester
          .getSemantics(find.bySemanticsLabel('Auto-save'))
          .getSemanticsData();
      expect(node.flagsCollection.isReadOnly, isTrue);
      handle.dispose();
    });

    testWidgets('small toggle without state text keeps the touch width', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        _toggle(
          value: false,
          small: true,
          hideStateText: true,
          onChanged: (_) {},
        ),
      );
      await harness.setDensity(tester, CarbonDensity.touch);
      final size = tester.getSize(find.byType(CarbonInteraction));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('colors and glyph', () {
    Finder icons() => find.descendant(
      of: find.byType(CarbonToggle),
      matching: find.byType(CarbonIcon),
    );

    testWidgets('disabled on toggle never shows a success check', (
      tester,
    ) async {
      await pumpCarbon(tester, _toggle(value: true, small: true));
      final colors = CarbonThemeData().colors;
      expect(icons(), findsOneWidget);
      for (final icon in tester.widgetList<CarbonIcon>(icons())) {
        expect(icon.color, isNot(colors.supportSuccess));
      }
    });

    testWidgets('the check mark sits in the small handle only', (tester) async {
      await pumpCarbon(
        tester,
        _toggle(value: true, small: true, onChanged: (_) {}),
      );
      expect(icons(), findsOneWidget);
      await pumpCarbon(tester, _toggle(value: true, onChanged: (_) {}));
      expect(icons(), findsNothing);
    });
  });
}
