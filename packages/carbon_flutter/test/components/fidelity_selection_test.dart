import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter/src/components/option_listbox.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

// Upstream references are Carbon v11 styles/scss/components/* and
// react/src/components/*.

const Key _key = Key('subject');

final CarbonThemeData _theme = CarbonThemeData();

const List<CarbonOption<String>> _five = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Bravo'),
  CarbonOption(value: 'c', label: 'Charlie'),
  CarbonOption(value: 'd', label: 'Delta'),
  CarbonOption(value: 'e', label: 'Echo'),
];

Widget _host(Widget child) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(width: 320, child: child),
);

Widget _dropdown({
  String? value,
  List<CarbonOption<String>> options = _five,
  bool readOnly = false,
  String? placeholder,
  bool autofocus = false,
}) => _host(
  CarbonDropdown<String>(
    key: _key,
    label: 'Mode',
    options: options,
    value: value,
    placeholder: placeholder,
    readOnly: readOnly,
    autofocus: autofocus,
    onChanged: (_) {},
  ),
);

Finder get _list => find.byType(CarbonOptionListbox<String>);

Finder get _listView =>
    find.descendant(of: _list, matching: find.byType(ListView));

Future<void> _openByTap(WidgetTester tester) async {
  await tester.tap(find.byKey(_key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

bool _hasTopBorder(DecoratedBox box) {
  final decoration = box.decoration;
  return decoration is BoxDecoration &&
      decoration.border is Border &&
      (decoration.border! as Border).top.width > 0;
}

Iterable<DecoratedBox> _rowBoxes(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: _listView, matching: find.byType(DecoratedBox)),
    );

Iterable<Color> _rowFills(WidgetTester tester) => _rowBoxes(tester)
    .map((b) => b.decoration)
    .whereType<BoxDecoration>()
    .map((d) => d.color)
    .whereType<Color>();

BoxDecoration _indicator(WidgetTester tester) {
  final boxes = tester.widgetList<DecoratedBox>(
    find.descendant(
      of: find.byType(CarbonCheckbox),
      matching: find.byType(DecoratedBox),
    ),
  );
  return boxes
      .map((b) => b.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.border != null);
}

/// How much of a checkbox's 14px interior the mark covers, in px², measured
/// from rendered pixels so stroke weight is what is asserted.
Future<double> _markArea(
  WidgetTester tester, {
  required bool? value,
  required bool tristate,
}) async {
  final boundary = GlobalKey();
  await pumpCarbon(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: boundary,
        child: CarbonCheckbox(
          value: value,
          tristate: tristate,
          semanticLabel: 'x',
          onChanged: (_) {},
        ),
      ),
    ),
  );
  const ratio = 8.0;
  final area = await tester.runAsync(() async {
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await object.toImage(pixelRatio: ratio);
    final data = (await image.toByteData())!;
    final width = image.width;
    final fill = _theme.colors.iconPrimary;
    final mark = _theme.colors.iconInverse;
    final fillR = fill.r * 255;
    final markR = mark.r * 255;
    var total = 0.0;
    // The box is centred in its 32px target; its interior is 14px.
    const origin = (32 - 16) / 2 + 1;
    for (var y = (origin * ratio).round();
        y < ((origin + 14) * ratio).round();
        y++) {
      for (var x = (origin * ratio).round();
          x < ((origin + 14) * ratio).round();
          x++) {
        final r = data.getUint8((y * width + x) * 4).toDouble();
        total += ((r - fillR) / (markR - fillR)).clamp(0.0, 1.0);
      }
    }
    return total / (ratio * ratio);
  });
  return area!;
}

void main() {
  group('list option inset (list-box.scss:720 margin 0 spacing-05)', () {
    testWidgets('row text starts 16px in and the checkmark ends 16px in', (
      tester,
    ) async {
      await pumpCarbon(tester, _dropdown(value: 'a'));
      await _openByTap(tester);
      final listRect = tester.getRect(_listView);
      expect(tester
                  .getTopLeft(
                    find.descendant(of: _listView, matching: find.text('Alpha')),
                  )
                  .dx -
              listRect.left,
          16);
      final check = find.descendant(
        of: _list,
        matching: find.byWidgetPredicate(
          (w) => w is CarbonIcon && w.icon == CarbonIcons.checkmark,
        ),
      );
      expect(listRect.right - tester.getRect(check).right, 16);
    });
  });

  group('list height (dropdown.scss:358 item height * 5.5)', () {
    testWidgets('a long list shows five and a half rows', (tester) async {
      final many = [
        for (var i = 0; i < 10; i++)
          CarbonOption(value: 'v$i', label: 'Option $i'),
      ];
      await pumpCarbon(
        tester,
        _dropdown(options: many),
        size: const Size(400, 800),
      );
      await _openByTap(tester);
      expect(tester.getSize(_listView).height, 5.5 * 32 + 2);
    });

    testWidgets('a short list is not padded to five and a half rows', (
      tester,
    ) async {
      await pumpCarbon(tester, _dropdown(options: _five.sublist(0, 3)));
      await _openByTap(tester);
      expect(tester.getSize(_listView).height, 3 * 32 + 2);
    });
  });

  group('no-selection label colour (list-box.scss:453 text-primary)', () {
    testWidgets('dropdown placeholder is text-primary', (tester) async {
      await pumpCarbon(tester, _dropdown(placeholder: 'Pick one'));
      final text = tester.widget<Text>(find.text('Pick one'));
      expect(text.style!.color, _theme.colors.textPrimary);
    });

    testWidgets('select placeholder is text-primary', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonSelect<String>(
            label: 'Mode',
            options: _five,
            value: null,
            placeholder: 'Pick one',
            onChanged: (_) {},
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('Pick one'));
      expect(text.style!.color, _theme.colors.textPrimary);
    });
  });

  group('checkbox mark weight (checkbox.scss:131-135, :171-173)', () {
    testWidgets('the check is a 9x5 L of 1.5px strokes', (tester) async {
      final area = await _markArea(tester, value: true, tristate: false);
      // 9*1.5 + 5*1.5 - 1.5*1.5 = 18.75.
      expect(area, inInclusiveRange(17.0, 20.5));
    });

    testWidgets('the indeterminate mark is an 8x2 bar', (tester) async {
      final area = await _markArea(tester, value: null, tristate: true);
      expect(area, inInclusiveRange(15.0, 17.0));
    });
  });

  group('checkbox box (checkbox.scss:104-105, :219-225)', () {
    testWidgets('invalid border stays 1px, unchecked and checked', (
      tester,
    ) async {
      for (final value in <bool>[false, true]) {
        await pumpCarbon(
          tester,
          _host(
            CarbonCheckbox(
              value: value,
              labelText: 'Accept',
              errorText: 'Required',
              onChanged: (_) {},
            ),
          ),
        );
        final border = _indicator(tester).border! as Border;
        expect(border.top.width, 1);
        expect(border.top.color, _theme.colors.supportError);
      }
    });

    testWidgets('corners are rounded 2px', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonCheckbox(value: false, labelText: 'Accept', onChanged: (_) {}),
        ),
      );
      expect(_indicator(tester).borderRadius, BorderRadius.circular(2));
    });

    testWidgets('box is indented 3px and the label starts at 30px', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonCheckbox(value: false, labelText: 'Accept', onChanged: (_) {}),
        ),
      );
      final boxes = find.descendant(
        of: find.byType(CarbonCheckbox),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border != null,
        ),
      );
      expect(tester.getRect(boxes).left, 3);
      expect(tester.getTopLeft(find.text('Accept')).dx, 30);
    });

    testWidgets('a group error marks every checkbox invalid', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonCheckboxGroup<String>(
            legend: 'Pick',
            items: const [
              CarbonCheckboxItem(value: 'a', label: 'A'),
              CarbonCheckboxItem(value: 'b', label: 'B'),
            ],
            selected: const {'a'},
            errorText: 'Choose fewer',
            onChanged: (_) {},
          ),
        ),
      );
      final colors = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(CarbonCheckbox),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.border != null)
          .map((d) => (d.border! as Border).top.color)
          .toList();
      expect(colors, hasLength(2));
      expect(colors, everyElement(_theme.colors.supportError));
    });
  });

  group('checkbox error line (checkbox.scss:258-262, :294-298)', () {
    testWidgets('uses the warning-filled glyph', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonCheckbox(
            value: false,
            labelText: 'Accept',
            errorText: 'Required',
            onChanged: (_) {},
          ),
        ),
      );
      CarbonIcons? iconOf(Finder f) =>
          f.evaluate().isEmpty ? null : tester.widget<CarbonIcon>(f.first).icon;
      final glyph = find.byWidgetPredicate(
        (w) =>
            w is CarbonIcon &&
            (w.icon == CarbonIcons.warningFilled ||
                w.icon == CarbonIcons.errorFilled),
      );
      expect(iconOf(glyph), CarbonIcons.warningFilled);
    });

    testWidgets('icon is 3px in and the text starts 28px in', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonCheckbox(
            value: false,
            labelText: 'Accept',
            errorText: 'Required',
            onChanged: (_) {},
          ),
        ),
      );
      final icon = find.byWidgetPredicate(
        (w) => w is CarbonIcon && w.size == 16 && w.color == _theme.colors.supportError,
      );
      expect(tester.getRect(icon).left, 3);
      expect(tester.getTopLeft(find.text('Required')).dx, 28);
    });
  });

  group('toggle (toggle.scss:29-34, :65, :76, :84-97)', () {
    Finder track(double w, double h) => find.byWidgetPredicate(
      (x) => x is SizedBox && x.width == w && x.height == h,
    );

    testWidgets('label sits 16px above the switch', (tester) async {
      for (final small in <bool>[false, true]) {
        await pumpCarbon(
          tester,
          _host(
            CarbonToggle(
              value: false,
              labelText: 'Label',
              small: small,
              onChanged: (_) {},
            ),
          ),
        );
        final t = small ? track(32, 16) : track(48, 24);
        final gap =
            tester.getRect(t).top - tester.getRect(find.text('Label')).bottom;
        expect(gap, 16, reason: small ? 'small' : 'default');
      }
    });

    testWidgets('handle and track move in 70ms with exit easing', (
      tester,
    ) async {
      var value = false;
      late StateSetter set;
      await pumpCarbon(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return _host(
              CarbonToggle(
                value: value,
                semanticLabel: 't',
                hideStateText: true,
                onChanged: (_) {},
              ),
            );
          },
        ),
      );
      Color trackColor() => tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(CarbonToggle),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.borderRadius != null)
          .color!;
      final off = trackColor();
      set(() => value = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 35));
      final mid = trackColor();
      expect(mid, isNot(off));
      expect(mid, isNot(_theme.colors.supportSuccess));
      await tester.pump(const Duration(milliseconds: 40));
      expect(trackColor(), _theme.colors.supportSuccess);
      final handle = find.byWidgetPredicate(
        (x) => x is SizedBox && x.width == 18 && x.height == 18,
      );
      final trackRect = tester.getRect(track(48, 24));
      expect(tester.getRect(handle).right, trackRect.right - 3);
    });

    testWidgets('shows the focus outline while pressed', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonToggle(
            value: false,
            semanticLabel: 't',
            hideStateText: true,
            onChanged: (_) {},
          ),
        ),
      );
      bool visible() =>
          tester.widget<CarbonFocusRing>(find.byType(CarbonFocusRing)).visible;
      expect(visible(), isFalse);
      final gesture = await tester.startGesture(
        tester.getCenter(track(48, 24)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(visible(), isTrue);
      await gesture.up();
      await tester.pump();
    });
  });

  group('option states (list-box.scss:632-634, :713-724, :750, :829-833)', () {
    testWidgets('dividers are inset 16px at both ends', (tester) async {
      await pumpCarbon(tester, _dropdown());
      await _openByTap(tester);
      final listRect = tester.getRect(_listView);
      final dividers = find.descendant(
        of: _listView,
        matching: find.byWidgetPredicate(
          (w) => w is DecoratedBox && _hasTopBorder(w),
        ),
      );
      expect(dividers, findsWidgets);
      for (var i = 0; i < dividers.evaluate().length; i++) {
        final rect = tester.getRect(dividers.at(i));
        expect(rect.left - listRect.left, 16);
        expect(listRect.right - rect.right, 16);
      }
    });

    testWidgets('no divider touches a selected or highlighted row', (
      tester,
    ) async {
      await pumpCarbon(tester, _dropdown(value: 'c'));
      await _openByTap(tester);
      // Rows b|c and c|d are hidden; a|b and d|e remain.
      expect(_rowBoxes(tester).where(_hasTopBorder), hasLength(2));
    });

    testWidgets('a keyboard highlight draws no fill', (tester) async {
      await pumpCarbon(tester, _dropdown(autofocus: true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_list, findsOneWidget);
      expect(_rowFills(tester), isEmpty);
    });

    testWidgets('a keyboard highlight on the selected row keeps layer-selected', (
      tester,
    ) async {
      await pumpCarbon(tester, _dropdown(value: 'a', autofocus: true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_rowFills(tester).toList(), [_theme.layerSelected(1)]);
    });

    testWidgets('a pointer hover fills with layer-hover', (tester) async {
      await pumpCarbon(tester, _dropdown());
      await _openByTap(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.descendant(of: _listView, matching: find.text('Bravo'))),
      );
      await tester.pump();
      expect(_rowFills(tester).toList(), [_theme.layerHover(1)]);
    });

    testWidgets('a pressed row fills with layer-selected', (tester) async {
      await pumpCarbon(tester, _dropdown());
      await _openByTap(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.descendant(of: _listView, matching: find.text('Charlie')),
        ),
      );
      await tester.pump();
      expect(_theme.layerSelected(1), isNot(_theme.layerActive(1)));
      expect(_rowFills(tester).toList(), [_theme.layerSelected(1)]);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  group('read-only chevron (select.scss:307, dropdown.scss:522)', () {
    Finder chevron() => find.descendant(
      of: find.byKey(_key),
      matching: find.byWidgetPredicate(
        (w) => w is CarbonIcon && w.icon == CarbonIcons.chevronDown,
      ),
    );

    testWidgets('dropdown keeps the chevron in icon-disabled', (tester) async {
      await pumpCarbon(tester, _dropdown(value: 'a', readOnly: true));
      expect(chevron(), findsOneWidget);
      expect(tester.widget<CarbonIcon>(chevron()).color, _theme.colors.iconDisabled);
    });

    testWidgets('select keeps the chevron in icon-disabled', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonSelect<String>(
            key: _key,
            options: _five,
            value: 'a',
            readOnly: true,
            onChanged: (_) {},
          ),
        ),
      );
      expect(chevron(), findsOneWidget);
      expect(tester.widget<CarbonIcon>(chevron()).color, _theme.colors.iconDisabled);
    });

    testWidgets('combo box keeps the chevron in icon-disabled', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonComboBox<String>(
            key: _key,
            options: _five,
            value: 'a',
            readOnly: true,
            onChanged: (_) {},
          ),
        ),
      );
      expect(chevron(), findsOneWidget);
      expect(tester.widget<CarbonIcon>(chevron()).color, _theme.colors.iconDisabled);
    });
  });

  group('Dropdown ArrowUp keeps focus while closed', () {
    testWidgets('focus stays on the dropdown', (tester) async {
      final above = FocusNode();
      addTearDown(above.dispose);
      final dropdown = FocusNode();
      addTearDown(dropdown.dispose);
      await pumpCarbon(
        tester,
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Focus(focusNode: above, child: const SizedBox(height: 20)),
              CarbonDropdown<String>(
                focusNode: dropdown,
                label: 'Mode',
                options: _five,
                value: 'a',
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      );
      dropdown.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(dropdown.hasFocus, isTrue);
      expect(above.hasFocus, isFalse);
    });
  });

  group('Dropdown.tsx:574-580 ArrowUp is ignored while closed', () {
    testWidgets('ArrowUp does not open a closed dropdown', (tester) async {
      await pumpCarbon(tester, _dropdown(autofocus: true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_list, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_list, findsOneWidget);
    });
  });

  group('chevron rotation (list-box.scss:472, :479-483)', () {
    testWidgets('the chevron turns half a revolution when open', (
      tester,
    ) async {
      await pumpCarbon(tester, _dropdown());
      AnimatedRotation rotation() => tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(_key),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation().turns, 0);
      expect(rotation().duration, const Duration(milliseconds: 70));
      await _openByTap(tester);
      expect(rotation().turns, 0.5);
    });
  });

  group('expanded trigger (list-box.scss:152-167)', () {
    dynamic rulePainter(WidgetTester tester) => tester
        .widget<CustomPaint>(
          find
              .descendant(
                of: find.byType(CarbonFieldBox),
                matching: find.byType(CustomPaint),
              )
              .first,
        )
        .foregroundPainter;

    testWidgets('dropdown rule is border-subtle only while open', (
      tester,
    ) async {
      await pumpCarbon(tester, _dropdown());
      expect(rulePainter(tester).rule, _theme.borderStrong(1));
      await _openByTap(tester);
      expect(rulePainter(tester).rule, _theme.borderSubtle(1));
    });

    testWidgets('combo box rule is border-subtle only while open', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonComboBox<String>(
            key: _key,
            options: _five,
            value: null,
            onChanged: (_) {},
          ),
        ),
      );
      expect(rulePainter(tester).rule, _theme.borderStrong(1));
      await tester.tap(find.byKey(_key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(rulePainter(tester).rule, _theme.borderSubtle(1));
    });
  });
}
