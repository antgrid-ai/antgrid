import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _tag = Key('tag');

Widget _aligned(Widget child, {double width = 400}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Widget _t({
  String label = 'Backend',
  CarbonTagColor color = CarbonTagColor.blue,
  CarbonTagSize size = CarbonTagSize.medium,
  VoidCallback? onDismissed,
  bool? selected,
  ValueChanged<bool>? onSelectedChanged,
  VoidCallback? onPressed,
  bool disabled = false,
  Widget? icon,
  double width = 400,
  FocusNode? focusNode,
  FocusNode? dismissFocusNode,
}) => _aligned(
  CarbonTag(
    key: _tag,
    label: label,
    color: color,
    size: size,
    onDismissed: onDismissed,
    selected: selected,
    onSelectedChanged: onSelectedChanged,
    onPressed: onPressed,
    disabled: disabled,
    icon: icon,
    focusNode: focusNode,
    dismissFocusNode: dismissFocusNode,
  ),
  width: width,
);

void main() {
  group('sizing', () {
    testWidgets('read-only tags have Carbon heights', (tester) async {
      for (final size in CarbonTagSize.values) {
        await pumpCarbon(tester, _t(size: size));
        expect(tester.getSize(find.byKey(_tag)).height, size.height);
      }
    });

    testWidgets('interactive tags reserve a minTarget footprint', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        _t(onDismissed: () {}, size: CarbonTagSize.small),
      );
      expect(tester.getSize(find.byKey(_tag)).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byKey(_tag)).height, 48);
    });

    testWidgets('remove target is a minTarget square in layout', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = await pumpCarbon(tester, _t(onDismissed: () {}));
      Size removeSize() =>
          tester.getSize(find.bySemanticsLabel('Remove Backend'));
      expect(removeSize(), const Size(32, 32));
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(removeSize(), const Size(48, 48));
      handle.dispose();
    });

    testWidgets('grows with 200% text and truncates long labels', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _t(
          label: 'A very long tag label that cannot possibly fit on screen',
          onDismissed: () {},
          width: 200,
        ),
        textScale: 2,
        size: const Size(320, 600),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(_tag)).width, lessThanOrEqualTo(200));
      final text = tester.widget<Text>(find.byType(Text).first);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
    });
  });

  group('read-only', () {
    testWidgets('exposes the full label to semantics and nothing else', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _t(label: 'A very long tag label that gets truncated', width: 80),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('A very long tag label that gets truncated'),
      );
      expect(node.flagsCollection.isButton, isFalse);
      handle.dispose();
    });

    testWidgets('has an optional leading icon', (tester) async {
      await pumpCarbon(
        tester,
        _t(icon: const CarbonIcon(CarbonIcons.star)),
      );
      expect(find.byType(CarbonIcon), findsOneWidget);
    });
  });

  group('dismissible', () {
    testWidgets('remove fires only the dismiss callback', (tester) async {
      var dismissed = 0;
      final selections = <bool>[];
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _t(
          onDismissed: () => dismissed++,
          selected: false,
          onSelectedChanged: selections.add,
        ),
      );
      await tester.tap(find.bySemanticsLabel('Remove Backend'));
      await tester.pump();
      expect(dismissed, 1);
      expect(selections, isEmpty);
      handle.dispose();
    });

    testWidgets('selecting never dismisses', (tester) async {
      var dismissed = 0;
      final selections = <bool>[];
      await pumpCarbon(
        tester,
        _t(
          onDismissed: () => dismissed++,
          selected: false,
          onSelectedChanged: selections.add,
        ),
      );
      await tester.tap(find.text('Backend'));
      await tester.pump();
      expect(selections, [true]);
      expect(dismissed, 0);
    });

    testWidgets('remove is keyboard focusable and activates with space', (
      tester,
    ) async {
      var dismissed = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _t(onDismissed: () => dismissed++, dismissFocusNode: node),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(dismissed, 1);
    });

    testWidgets('dismiss label is localized with the tag name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonLocalizationsScope(
            messages: CarbonLocalizations(removeItem: (l) => 'Supprimer $l'),
            child: CarbonTag(label: 'Alpha', onDismissed: () {}),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Supprimer Alpha'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('adjacent tags do not overlap', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CarbonTag(key: const Key('a'), label: 'One', onDismissed: () {}),
              CarbonTag(key: const Key('b'), label: 'Two', onDismissed: () {}),
            ],
          ),
        ),
      );
      expect(
        tester.getTopRight(find.byKey(const Key('a'))).dx,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('b'))).dx),
      );
    });
  });

  group('selectable', () {
    testWidgets('toggles via tap and keyboard, exposes selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final requests = <bool>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _t(selected: false, onSelectedChanged: requests.add, focusNode: node),
      );
      await tester.tap(find.text('Backend'));
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(requests, [true, true]);
      var s = tester.getSemantics(find.bySemanticsLabel('Backend'));
      expect(s.flagsCollection.isSelected, Tristate.isFalse);

      await pumpCarbon(
        tester,
        _t(selected: true, onSelectedChanged: requests.add),
      );
      s = tester.getSemantics(find.bySemanticsLabel('Backend'));
      expect(s.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('selected adds a check mark, not color alone', (tester) async {
      await pumpCarbon(
        tester,
        _t(selected: true, onSelectedChanged: (_) {}),
      );
      expect(find.byType(CarbonIcon), findsOneWidget);
    });

    testWidgets('disabled selectable is inert', (tester) async {
      final requests = <bool>[];
      var dismissed = 0;
      await pumpCarbon(
        tester,
        _t(
          selected: false,
          onSelectedChanged: requests.add,
          onDismissed: () => dismissed++,
          disabled: true,
        ),
      );
      await tester.tap(find.text('Backend'));
      await tester.tapAt(tester.getTopRight(find.byKey(_tag)) + const Offset(-8, 16));
      await tester.pump();
      expect(requests, isEmpty);
      expect(dismissed, 0);
    });

    testWidgets('selectable without a handler is inert', (tester) async {
      await pumpCarbon(tester, _t(selected: false));
      await tester.tap(find.text('Backend'));
      expect(tester.takeException(), isNull);
    });
  });

  group('operational', () {
    testWidgets('onPressed fires once per tap', (tester) async {
      var pressed = 0;
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _t(onPressed: () => pressed++));
      await tester.tap(find.text('Backend'));
      await tester.pump();
      expect(pressed, 1);
      final s = tester.getSemantics(find.bySemanticsLabel('Backend'));
      expect(s.flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  group('colors', () {
    testWidgets('every role builds in every theme without overflow', (
      tester,
    ) async {
      for (final scheme in CarbonThemeScheme.values) {
        await pumpCarbon(
          tester,
          _aligned(
            Wrap(
              children: [
                for (final c in CarbonTagColor.values)
                  CarbonTag(label: c.name, color: c, onDismissed: () {}),
                const CarbonTag(label: 'disabled', disabled: true),
              ],
            ),
          ),
          theme: CarbonThemeData(scheme: scheme),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('fill follows the role and hover changes it', (tester) async {
      await pumpCarbon(tester, _t(onPressed: () {}));
      Color? fill() {
        final boxes = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(_tag),
            matching: find.byType(DecoratedBox),
          ),
        );
        return boxes
            .map((b) => (b.decoration as BoxDecoration).color)
            .whereType<Color>()
            .firstWhere((c) => c.a > 0, orElse: () => const Color(0x00000000));
      }

      final theme = CarbonThemeData();
      expect(fill(), theme.colors.tagBlue.background);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.text('Backend')));
      await tester.pump();
      expect(
        tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).any(
          (b) =>
              (b.decoration as BoxDecoration).color ==
              theme.colors.tagBlue.hover,
        ),
        isTrue,
      );
    });
  });

  group('live changes and rtl', () {
    testWidgets('remove sits at the leading-opposite end in RTL', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _t(onDismissed: () {}), dir: TextDirection.rtl);
      final remove = tester.getCenter(find.bySemanticsLabel('Remove Backend'));
      final label = tester.getCenter(find.text('Backend'));
      expect(remove.dx, lessThan(label.dx));
      handle.dispose();
    });

    testWidgets('density and theme switch keep focus on the remove target', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final harness = await pumpCarbon(
        tester,
        _t(onDismissed: () {}, dismissFocusNode: node),
      );
      node.requestFocus();
      await tester.pump();
      await harness.setDensity(tester, CarbonDensity.touch);
      await harness.setTheme(
        tester,
        CarbonThemeData(scheme: CarbonThemeScheme.gray90),
      );
      expect(node.hasFocus, isTrue);
    });

    testWidgets('repeated mount and unmount is clean', (tester) async {
      for (var i = 0; i < 3; i++) {
        await pumpCarbon(tester, _t(onDismissed: () {}));
        await pumpCarbon(tester, const SizedBox.shrink());
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('semantics and chrome', () {
    testWidgets('a selectable tag without a handler still announces selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _t(selected: true));
      final node = tester
          .getSemantics(find.bySemanticsLabel('Backend'))
          .getSemanticsData();
      expect(node.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('a selectable tag is announced as a button', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _t(selected: false, onSelectedChanged: (_) {}));
      final node = tester
          .getSemantics(find.bySemanticsLabel('Backend'))
          .getSemanticsData();
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });

    BoxDecoration pill(WidgetTester tester) =>
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byType(CarbonTag),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;

    testWidgets('an unselected selectable tag uses core tokens and a border', (
      tester,
    ) async {
      await pumpCarbon(tester, _t(selected: false, onSelectedChanged: (_) {}));
      final theme = CarbonThemeData();
      final decoration = pill(tester);
      expect(decoration.color, theme.layer(1));
      expect(
        (decoration.border! as Border).top.color,
        theme.colors.borderInverse,
      );
    });

    testWidgets('an operational tag keeps its role border', (tester) async {
      await pumpCarbon(tester, _t(onPressed: () {}));
      expect(
        (pill(tester).border! as Border).top.color,
        CarbonThemeData().colors.tagBlue.border,
      );
    });

    testWidgets('a disabled tag is outlined with the disabled border', (
      tester,
    ) async {
      await pumpCarbon(tester, _t(onPressed: () {}, disabled: true));
      final theme = CarbonThemeData();
      final decoration = pill(tester);
      expect(decoration.color, theme.layer(1));
      expect(
        (decoration.border! as Border).top.color,
        theme.colors.borderDisabled,
      );
    });

    testWidgets('a short interactive tag keeps the touch width', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        _t(label: '1', size: CarbonTagSize.small, onPressed: () {}),
      );
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(
        tester.getSize(find.byType(CarbonInteraction)).width,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('a truncated label is revealed on hover', (tester) async {
      const full = 'A very long tag label that truncates';
      await pumpCarbon(tester, _t(label: full, width: 120));
      expect(find.text(full), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(_tag)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text(full), findsNWidgets(2));
    });

    testWidgets('a label that fits has no tooltip', (tester) async {
      await pumpCarbon(tester, _t());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(_tag)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Backend'), findsOneWidget);
    });
  });
}
