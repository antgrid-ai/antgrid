import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter/src/components/option_listbox.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show MaterialApp, Scaffold, Scrollbar;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/host_theme.dart';

enum _Kind { select, dropdown, combo }

const List<CarbonOption<String>> _options = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Bravo', enabled: false),
  CarbonOption(value: 'c', label: 'Charlie'),
  CarbonOption(value: 'd', label: 'Delta'),
  CarbonOption(value: 'e', label: 'Echo'),
];

final List<CarbonOption<String>> _many = [
  for (var i = 0; i < 12; i++) CarbonOption(value: 'v$i', label: 'Item $i'),
];

const Key _trigger = Key('trigger');
const Size _view = Size(800, 700);

Widget _field(
  _Kind kind, {
  String? initial,
  List<CarbonOption<String>> options = _options,
  FocusNode? focusNode,
  String? listError,
}) {
  final Widget child = switch (kind) {
    _Kind.select => CarbonSelect<String>(
      key: _trigger,
      options: options,
      value: initial,
      focusNode: focusNode,
      onChanged: (_) {},
    ),
    _Kind.dropdown => CarbonDropdown<String>(
      key: _trigger,
      options: options,
      value: initial,
      focusNode: focusNode,
      listErrorText: listError,
      onChanged: (_) {},
    ),
    _Kind.combo => CarbonComboBox<String>(
      key: _trigger,
      options: options,
      value: initial,
      focusNode: focusNode,
      listErrorText: listError,
      onChanged: (_) {},
    ),
  };
  return Align(
    alignment: AlignmentDirectional.topStart,
    child: SizedBox(width: 300, child: child),
  );
}

Finder get _list => find.byType(CarbonOptionListbox<String>);

Finder _rowText(String label) =>
    find.descendant(of: _list, matching: find.text(label));

// The rule box and the fill box of a row, innermost first.
List<DecoratedBox> _boxes(String label) => find
    .ancestor(of: _rowText(label), matching: find.byType(DecoratedBox))
    .evaluate()
    .map((e) => e.widget as DecoratedBox)
    .toList();

Color? _fill(String label) =>
    (_boxes(label)[1].decoration as BoxDecoration).color;

bool _divider(String label) =>
    (_boxes(label)[0].decoration as BoxDecoration).border != null;

Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: const Offset(700, 500));
  return gesture;
}

Future<void> _clickOpen(WidgetTester tester, TestGesture mouse) async {
  final at = tester.getCenter(find.byKey(_trigger));
  await mouse.moveTo(at);
  await mouse.down(at);
  await mouse.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _hover(
  WidgetTester tester,
  TestGesture mouse,
  String label,
) async {
  await mouse.moveTo(tester.getCenter(_rowText(label)));
  await tester.pump();
}

CarbonThemeData get _t => CarbonThemeData();

void main() {
  for (final kind in _Kind.values) {
    group('${kind.name} list', () {
      testWidgets('L1 a selected row opened by a click is not hovered', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'a')),
          size: _view,
        );
        final mouse = await _mouse(tester);
        await _clickOpen(tester, mouse);
        expect(_fill('Alpha'), _t.layerSelected(1));
      });

      testWidgets('L1 a selected row opened by touch keeps layerSelected', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'a')),
          size: _view,
        );
        await tester.tap(find.byKey(_trigger));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(_fill('Alpha'), _t.layerSelected(1));
      });

      testWidgets('L2 hover ends when the pointer leaves the list', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'a')),
          size: _view,
        );
        final mouse = await _mouse(tester);
        await _clickOpen(tester, mouse);
        await _hover(tester, mouse, 'Delta');
        expect(_fill('Delta'), _t.layerHover(1));
        expect(_divider('Echo'), isFalse);
        await mouse.moveTo(const Offset(700, 500));
        await tester.pump();
        expect(_fill('Delta'), isNull);
        expect(_divider('Echo'), isTrue);
        await _hover(tester, mouse, 'Charlie');
        await mouse.moveTo(tester.getCenter(find.byKey(_trigger)));
        await tester.pump();
        expect(_fill('Charlie'), isNull);
      });

      testWidgets('L3 moving onto a disabled row clears the old hover', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'c')),
          size: _view,
        );
        final mouse = await _mouse(tester);
        await _clickOpen(tester, mouse);
        await _hover(tester, mouse, 'Alpha');
        await _hover(tester, mouse, 'Bravo');
        expect(_fill('Alpha'), isNull);
        expect(_fill('Bravo'), isNull);
        expect(_divider('Bravo'), isTrue);
      });

      testWidgets('L4 the pointer over the keyboard row adds the hover fill', (
        tester,
      ) async {
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, focusNode: focus)),
          size: _view,
        );
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        if (kind == _Kind.combo) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 600));
        expect(_fill('Alpha'), isNull);
        final mouse = await _mouse(tester);
        await _hover(tester, mouse, 'Alpha');
        expect(_fill('Alpha'), _t.layerHover(1));
      });

      testWidgets('L5 pressing the hovered selected row keeps its hover fill', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'a')),
          size: _view,
        );
        final mouse = await _mouse(tester);
        await _clickOpen(tester, mouse);
        await _hover(tester, mouse, 'Alpha');
        expect(_fill('Alpha'), _t.layerSelectedHover(1));
        await mouse.down(tester.getCenter(_rowText('Alpha')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(_fill('Alpha'), _t.layerSelectedHover(1));
        await mouse.cancel();
        await tester.pump();
      });

      testWidgets('L9 the list has no host scrollbar', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = _view;
          addTearDown(tester.view.reset);
          // MaterialApp installs the scroll behaviour that adds a scrollbar.
          await tester.pumpWidget(
            MaterialApp(
              theme: hostileHostTheme,
              home: Scaffold(
                body: CarbonTheme(
                  data: _t,
                  child: _field(kind, options: _many),
                ),
              ),
            ),
          );
          final mouse = await _mouse(tester);
          await _clickOpen(tester, mouse);
          expect(_list, findsOneWidget);
          expect(
            find.descendant(of: _list, matching: find.byType(Scrollbar)),
            findsNothing,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('L10 the checkmark follows the theme icon size', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'a')),
          size: _view,
        );
        final mouse = await _mouse(tester);
        await _clickOpen(tester, mouse);
        final icons = find.descendant(
          of: _list,
          matching: find.byType(CarbonIcon),
        );
        expect(icons, findsOneWidget);
        expect(tester.getSize(icons).width, _t.iconSize);
      });

      testWidgets('L12 a disabled row shows the not-allowed cursor', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          underHostileHost(_field(kind, initial: 'a')),
          size: _view,
        );
        final mouse = await _mouse(tester);
        await _clickOpen(tester, mouse);
        await _hover(tester, mouse, 'Bravo');
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.forbidden,
        );
        await _hover(tester, mouse, 'Charlie');
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
      });
    });
  }

  for (final kind in [_Kind.dropdown, _Kind.combo]) {
    testWidgets('L10 the list error icon follows the theme icon size '
        '(${kind.name})', (tester) async {
      await pumpCarbon(
        tester,
        underHostileHost(_field(kind, listError: 'Failed')),
        size: _view,
      );
      final mouse = await _mouse(tester);
      await _clickOpen(tester, mouse);
      final icons = find.descendant(
        of: _list,
        matching: find.byType(CarbonIcon),
      );
      expect(icons, findsOneWidget);
      expect(tester.getSize(icons).width, _t.iconSize);
    });
  }

  for (final kind in _Kind.values) {
    testWidgets('the rules beside a keyboard-highlighted row are hidden '
        '(${kind.name})', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpCarbon(
        tester,
        underHostileHost(_field(kind, focusNode: focus)),
        size: _view,
      );
      focus.requestFocus();
      await tester.pump();
      // Open, then move the highlight past the disabled Bravo to Charlie.
      final presses = kind == _Kind.combo ? 3 : 2;
      for (var i = 0; i < presses; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(_list, findsOneWidget);
      // list-box.scss: `--highlighted` hides its own rule and the next row's.
      expect(_divider('Charlie'), isFalse);
      expect(_divider('Delta'), isFalse);
      expect(_divider('Echo'), isTrue);
    });
  }

  group('L6 trigger outline while open', () {
    bool focusedBox(WidgetTester tester) =>
        tester.widget<CarbonFieldBox>(find.byType(CarbonFieldBox)).focused;

    Future<void> openByKey(WidgetTester tester, _Kind kind, String? v) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpCarbon(
        tester,
        underHostileHost(_field(kind, initial: v, focusNode: focus)),
        size: _view,
      );
      focus.requestFocus();
      await tester.pump();
      expect(focusedBox(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_list, findsOneWidget);
    }

    testWidgets('a dropdown with a value drops the outline', (tester) async {
      await openByKey(tester, _Kind.dropdown, 'a');
      expect(focusedBox(tester), isFalse);
    });

    testWidgets('a dropdown without a value keeps the outline', (tester) async {
      await openByKey(tester, _Kind.dropdown, null);
      expect(focusedBox(tester), isTrue);
    });

    testWidgets('a select keeps the outline', (tester) async {
      await openByKey(tester, _Kind.select, 'a');
      expect(focusedBox(tester), isTrue);
    });

    testWidgets('a combo box thins its outline to 1px while a row is '
        'highlighted', (tester) async {
      await openByKey(tester, _Kind.combo, 'a');
      expect(
        find.byType(CarbonFieldBox),
        paints..something((method, args) => args.any(
              (a) =>
                  a is Paint &&
                  a.style == PaintingStyle.stroke &&
                  a.color.toARGB32() == _t.colors.focus.toARGB32() &&
                  a.strokeWidth == 1,
            )),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_list, findsNothing);
      expect(
        find.byType(CarbonFieldBox),
        paints..something((method, args) => args.any(
              (a) =>
                  a is Paint &&
                  a.style == PaintingStyle.stroke &&
                  a.color.toARGB32() == _t.colors.focus.toARGB32() &&
                  a.strokeWidth == 2,
            )),
      );
    });
  });

  for (final kind in _Kind.values) {
    testWidgets('L7 an outside click blurs the field (${kind.name})', (
      tester,
    ) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpCarbon(
        tester,
        underHostileHost(_field(kind, initial: 'a', focusNode: focus)),
        size: _view,
      );
      final mouse = await _mouse(tester);
      await _clickOpen(tester, mouse);
      expect(_list, findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await mouse.down(const Offset(700, 500));
      await mouse.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_list, findsNothing);
      expect(focus.hasFocus, isFalse);
    });
  }

  testWidgets('L11 combo box selection handles use a Carbon colour', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpCarbon(
        tester,
        underHostileHost(_field(_Kind.combo, initial: 'a')),
        size: _view,
      );
      await tester.longPress(find.byType(EditableText));
      await tester.pumpAndSettle();
      final colors = <Color>[];
      void visit(Element e) {
        final w = e.widget;
        if (w is CustomPaint &&
            w.painter.runtimeType.toString() == '_TextSelectionHandlePainter') {
          colors.add((w.painter! as dynamic).color as Color);
        }
        e.visitChildren(visit);
      }

      tester.binding.rootElement!.visitChildren(visit);
      expect(colors, isNotEmpty);
      expect(colors, everyElement(isNot(hostSelection)));
      expect(colors, everyElement(_t.colors.textPrimary));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
