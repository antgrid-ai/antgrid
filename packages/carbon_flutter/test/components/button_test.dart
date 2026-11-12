import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _btn = Key('btn');

Widget _host(Widget child, {double width = 400}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Widget _aligned(Widget child) =>
    Align(alignment: AlignmentDirectional.topStart, child: child);

Color? _fill(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(of: find.byKey(_btn), matching: find.byType(DecoratedBox))
        .first,
  );
  return (box.decoration as BoxDecoration).color;
}

void main() {
  group('sizing', () {
    testWidgets('default height follows density', (tester) async {
      final harness = await pumpCarbon(
        tester,
        _aligned(CarbonButton(key: _btn, label: 'Save', onPressed: () {})),
      );
      expect(tester.getSize(find.byKey(_btn)).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byKey(_btn)).height, 48);
    });

    testWidgets('explicit sizes in compact, touch floor holds', (tester) async {
      Widget tree(CarbonButtonSize s) => _aligned(
        CarbonButton(key: _btn, label: 'Save', size: s, onPressed: () {}),
      );
      for (final (size, expected) in [
        (CarbonButtonSize.small, 32.0),
        (CarbonButtonSize.medium, 40.0),
        (CarbonButtonSize.large, 48.0),
        (CarbonButtonSize.extraLarge, 64.0),
      ]) {
        await pumpCarbon(tester, tree(size));
        expect(tester.getSize(find.byKey(_btn)).height, expected, reason: '$size');
      }
      final touch = CarbonThemeData(density: CarbonDensity.touch);
      for (final (size, expected) in [
        (CarbonButtonSize.small, 48.0),
        (CarbonButtonSize.medium, 48.0),
        (CarbonButtonSize.large, 48.0),
        (CarbonButtonSize.extraLarge, 64.0),
      ]) {
        await pumpCarbon(tester, tree(size), theme: touch);
        expect(tester.getSize(find.byKey(_btn)).height, expected, reason: '$size');
      }
    });

    testWidgets('icon-only is square at each density', (tester) async {
      final harness = await pumpCarbon(
        tester,
        _aligned(
          CarbonButton.iconOnly(
            key: _btn,
            icon: const CarbonIcon(CarbonIcons.add),
            semanticLabel: 'Add',
            onPressed: () {},
          ),
        ),
      );
      expect(tester.getSize(find.byKey(_btn)), const Size(32, 32));
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byKey(_btn)), const Size(48, 48));
    });

    testWidgets('extraSmall is 24 square in compact, floored to 48 on touch', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        _aligned(
          CarbonOverflowMenu(
            key: _btn,
            size: CarbonButtonSize.extraSmall,
            entries: const <CarbonMenuEntry>[CarbonMenuItem(label: 'Open')],
          ),
        ),
      );
      expect(tester.getSize(find.byKey(_btn)), const Size(24, 24));
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byKey(_btn)), const Size(48, 48));
    });

    testWidgets('large text grows a wrapped label instead of clipping', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonButton(
            key: _btn,
            label: 'A rather long button label that must wrap',
            onPressed: () {},
          ),
          width: 160,
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(_btn)).height, greaterThan(64));
      expect(tester.getSize(find.byKey(_btn)).width, lessThanOrEqualTo(160));
    });

    testWidgets('expand fills the width with the icon at the end', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonButton(
            key: _btn,
            label: 'Next',
            icon: const CarbonIcon(CarbonIcons.arrowRight, key: Key('icon')),
            expand: true,
            onPressed: () {},
          ),
          width: 300,
        ),
      );
      final box = tester.getRect(find.byKey(_btn));
      expect(box.width, 300);
      final icon = tester.getRect(find.byKey(const Key('icon')));
      expect(box.right - icon.right, 16);
    });

    testWidgets('icon trails the label and mirrors sides in RTL', (
      tester,
    ) async {
      Widget tree() => _host(
        CarbonButton(
          key: _btn,
          label: 'Next',
          icon: const CarbonIcon(CarbonIcons.arrowRight, key: Key('icon')),
          onPressed: () {},
        ),
      );
      await pumpCarbon(tester, tree());
      expect(
        tester.getCenter(find.byKey(const Key('icon'))).dx,
        greaterThan(tester.getCenter(find.text('Next')).dx),
      );
      await pumpCarbon(tester, tree(), dir: TextDirection.rtl);
      expect(
        tester.getCenter(find.byKey(const Key('icon'))).dx,
        lessThan(tester.getCenter(find.text('Next')).dx),
      );
    });
  });

  group('activation', () {
    testWidgets('tap, Enter and Space each activate once', (tester) async {
      var count = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Save',
            focusNode: node,
            onPressed: () => count++,
          ),
        ),
      );
      await tester.tap(find.byKey(_btn));
      expect(count, 1);
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(count, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(count, 3);
    });

    testWidgets('two taps call twice and one double-tap gesture never more', (
      tester,
    ) async {
      var count = 0;
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(key: _btn, label: 'Save', onPressed: () => count++),
        ),
      );
      await tester.tap(find.byKey(_btn));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byKey(_btn));
      await tester.pump(const Duration(milliseconds: 500));
      expect(count, 2);
    });

    testWidgets('a pointer dragged away does not activate', (tester) async {
      var count = 0;
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(key: _btn, label: 'Save', onPressed: () => count++),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_btn)),
      );
      await gesture.moveBy(const Offset(0, 300));
      await gesture.up();
      await tester.pump();
      expect(count, 0);
    });

    testWidgets('disabled is inert, not focusable and reads disabled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _aligned(CarbonButton(key: _btn, label: 'Save', focusNode: node)),
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
      await tester.tap(find.byKey(_btn), warnIfMissed: false);
      expect(
        tester.getSemantics(find.byKey(_btn)),
        matchesSemantics(
          label: 'Save',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('disabled uses the disabled fill', (tester) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        _aligned(CarbonButton(key: _btn, label: 'Save')),
        theme: theme,
      );
      expect(_fill(tester), theme.colors.buttonDisabled);
      await pumpCarbon(
        tester,
        _aligned(CarbonButton(key: _btn, label: 'Save', onPressed: () {})),
        theme: theme,
      );
      expect(_fill(tester), theme.colors.buttonPrimary);
    });

    testWidgets('semantics: enabled button exposes label and tap', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _aligned(CarbonButton(key: _btn, label: 'Save', onPressed: () {})),
      );
      expect(
        tester.getSemantics(find.byKey(_btn)),
        matchesSemantics(
          label: 'Save',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('icon-only exposes its semantic label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton.iconOnly(
            key: _btn,
            icon: const CarbonIcon(CarbonIcons.trashCan),
            semanticLabel: 'Delete file',
            onPressed: () {},
          ),
        ),
      );
      expect(find.bySemanticsLabel('Delete file'), findsOneWidget);
      handle.dispose();
    });
  });

  group('busy', () {
    testWidgets('blocks tap and keys but keeps focus', (tester) async {
      var count = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      Widget tree(bool busy) => _aligned(
        CarbonButton(
          key: _btn,
          label: 'Save',
          busy: busy,
          focusNode: node,
          onPressed: () => count++,
        ),
      );
      await pumpCarbon(tester, tree(false));
      node.requestFocus();
      await tester.pump();
      await pumpCarbon(tester, tree(true));
      expect(node.hasFocus, isTrue);
      await tester.tap(find.byKey(_btn));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 100));
      expect(count, 0);
      await pumpCarbon(tester, tree(false));
      await tester.tap(find.byKey(_btn));
      expect(count, 1);
    });

    testWidgets('keeps its footprint for text, icon and icon-only', (
      tester,
    ) async {
      final builders = <Widget Function(bool)>[
        (busy) => _aligned(
          CarbonButton(key: _btn, label: 'Save changes', busy: busy, onPressed: () {}),
        ),
        (busy) => _aligned(
          CarbonButton(
            key: _btn,
            label: 'Save changes',
            icon: const CarbonIcon(CarbonIcons.checkmark),
            busy: busy,
            onPressed: () {},
          ),
        ),
        (busy) => _aligned(
          CarbonButton.iconOnly(
            key: _btn,
            icon: const CarbonIcon(CarbonIcons.add),
            semanticLabel: 'Add',
            busy: busy,
            onPressed: () {},
          ),
        ),
      ];
      for (final build in builders) {
        await pumpCarbon(tester, build(false));
        final idle = tester.getSize(find.byKey(_btn));
        await pumpCarbon(tester, build(true));
        expect(tester.getSize(find.byKey(_btn)), idle);
        expect(find.byType(CarbonSpinner), findsOneWidget);
        await pumpCarbon(tester, build(false));
        expect(find.byType(CarbonSpinner), findsNothing);
      }
    });

    testWidgets('announces the localized loading string', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(key: _btn, label: 'Save', busy: true, onPressed: () {}),
        ),
      );
      expect(
        tester.getSemantics(find.byKey(_btn)),
        matchesSemantics(
          label: 'Save',
          value: 'Loading',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('busy at 200% text does not overflow', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonButton(
            key: _btn,
            label: 'Save changes to the project',
            icon: const CarbonIcon(CarbonIcons.checkmark),
            busy: true,
            onPressed: () {},
          ),
          width: 220,
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('busy spinner stops under reduced motion', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(key: _btn, label: 'Save', busy: true, onPressed: () {}),
        ),
        reduceMotion: true,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('kinds and states', () {
    testWidgets('every kind renders enabled, disabled and busy', (
      tester,
    ) async {
      for (final kind in CarbonButtonKind.values) {
        for (final scheme in CarbonThemeScheme.values) {
          for (final (enabled, busy) in [(true, false), (false, false), (true, true)]) {
            await pumpCarbon(
              tester,
              _aligned(
                CarbonButton(
                  key: _btn,
                  label: 'Action',
                  kind: kind,
                  busy: busy,
                  icon: const CarbonIcon(CarbonIcons.add),
                  onPressed: enabled ? () {} : null,
                ),
              ),
              theme: CarbonThemeData(scheme: scheme),
            );
            await tester.pump(const Duration(milliseconds: 20));
            expect(tester.takeException(), isNull, reason: '$kind $scheme');
          }
        }
      }
    });

    testWidgets('filled kinds use their role colors and react to hover/press', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      final c = theme.colors;
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.secondary,
            onPressed: () {},
          ),
        ),
        theme: theme,
      );
      expect(_fill(tester), c.buttonSecondary);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(_btn)));
      await tester.pump();
      expect(_fill(tester), c.buttonSecondaryHover);
      await mouse.down(tester.getCenter(find.byKey(_btn)));
      await tester.pump();
      expect(_fill(tester), c.buttonSecondaryActive);
      await mouse.up();
    });

    testWidgets('tertiary is outlined at rest and fills on hover', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.tertiary,
            onPressed: () {},
          ),
        ),
        theme: theme,
      );
      expect(_fill(tester)!.a, 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.byKey(_btn)));
      await tester.pump();
      expect(_fill(tester), theme.colors.buttonTertiaryHover);
    });

    testWidgets('keyboard focus shows the ring, mouse focus does not', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Save',
            focusNode: node,
            onPressed: () {},
          ),
        ),
      );
      bool ring() => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byKey(_btn),
              matching: find.byType(CustomPaint),
            ),
          )
          .any((p) => p.foregroundPainter != null);
      expect(ring(), isFalse);
      node.requestFocus();
      await tester.pump();
      expect(ring(), isTrue);
    });
  });

  group('lifecycle', () {
    testWidgets('density and theme switches keep focus', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final harness = await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(key: _btn, label: 'Save', focusNode: node, onPressed: () {}),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await harness.setDensity(tester, CarbonDensity.touch);
      await harness.setTheme(
        tester,
        CarbonThemeData(
          scheme: CarbonThemeScheme.gray90,
          density: CarbonDensity.touch,
        ),
      );
      expect(node.hasFocus, isTrue);
    });

    testWidgets('focus node replacement moves focus handling', (tester) async {
      final a = FocusNode();
      final b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      Widget tree(FocusNode n) => _aligned(
        CarbonButton(key: _btn, label: 'Save', focusNode: n, onPressed: () {}),
      );
      await pumpCarbon(tester, tree(a));
      await pumpCarbon(tester, tree(b));
      b.requestFocus();
      await tester.pump();
      expect(b.hasFocus, isTrue);
      var count = 0;
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Save',
            focusNode: b,
            onPressed: () => count++,
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(count, 1);
    });

    testWidgets('repeated mount and unmount is clean', (tester) async {
      for (var i = 0; i < 4; i++) {
        await pumpCarbon(
          tester,
          _aligned(
            CarbonButton(key: _btn, label: 'Save', busy: i.isEven, onPressed: () {}),
          ),
        );
        await pumpCarbon(tester, _aligned(const SizedBox()));
      }
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('CarbonButtonSet', () {
    Widget set({
      CarbonButtonSetAlignment alignment = CarbonButtonSetAlignment.end,
      List<VoidCallback?>? taps,
    }) => CarbonButtonSet(
      alignment: alignment,
      children: [
        CarbonButton(
          key: const Key('cancel'),
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: taps?[0] ?? () {},
        ),
        CarbonButton(
          key: const Key('ok'),
          label: 'Confirm',
          onPressed: taps?[1] ?? () {},
        ),
      ],
    );

    testWidgets('end alignment keeps natural widths at the end', (
      tester,
    ) async {
      await pumpCarbon(tester, _host(set(), width: 500));
      final cancel = tester.getRect(find.byKey(const Key('cancel')));
      final ok = tester.getRect(find.byKey(const Key('ok')));
      expect(cancel.top, ok.top);
      expect(cancel.right + 1, ok.left);
      expect(ok.right, 500);
      expect(cancel.height, ok.height);
      expect(tester.getSize(find.byType(CarbonButtonSet)).width, 500);
    });

    testWidgets('fill shares the width equally', (tester) async {
      await pumpCarbon(
        tester,
        _host(set(alignment: CarbonButtonSetAlignment.fill), width: 401),
      );
      final cancel = tester.getRect(find.byKey(const Key('cancel')));
      final ok = tester.getRect(find.byKey(const Key('ok')));
      expect(cancel.width, ok.width);
      expect(cancel.left, 0);
      expect(ok.right, 401);
    });

    testWidgets('stacks with the last button on top when narrow', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(set(alignment: CarbonButtonSetAlignment.fill), width: 120),
      );
      final cancel = tester.getRect(find.byKey(const Key('cancel')));
      final ok = tester.getRect(find.byKey(const Key('ok')));
      expect(ok.top, lessThan(cancel.top));
      expect(ok.width, 120);
      expect(cancel.width, 120);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stacks at 200% text instead of clipping labels', (
      tester,
    ) async {
      await pumpCarbon(tester, _host(set(), width: 260), textScale: 2);
      final cancel = tester.getRect(find.byKey(const Key('cancel')));
      final ok = tester.getRect(find.byKey(const Key('ok')));
      expect(cancel.top, isNot(ok.top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('RTL mirrors the row and keeps buttons tappable', (
      tester,
    ) async {
      var cancelTaps = 0;
      var okTaps = 0;
      await pumpCarbon(
        tester,
        _host(
          set(taps: [() => cancelTaps++, () => okTaps++]),
          width: 500,
        ),
        dir: TextDirection.rtl,
      );
      final origin = tester.getTopLeft(find.byType(CarbonButtonSet));
      final cancel = tester
          .getRect(find.byKey(const Key('cancel')))
          .shift(-origin);
      final ok = tester.getRect(find.byKey(const Key('ok'))).shift(-origin);
      expect(ok.left, 0);
      expect(cancel.left, greaterThan(ok.left));
      await tester.tap(find.byKey(const Key('cancel')));
      await tester.tap(find.byKey(const Key('ok')));
      expect([cancelTaps, okTaps], [1, 1]);
    });

    testWidgets('both buttons tap independently in a row and stacked', (
      tester,
    ) async {
      var a = 0;
      var b = 0;
      for (final w in [500.0, 100.0]) {
        await pumpCarbon(
          tester,
          _host(set(taps: [() => a++, () => b++]), width: w),
        );
        await tester.tap(find.byKey(const Key('cancel')));
        await tester.tap(find.byKey(const Key('ok')));
      }
      expect([a, b], [2, 2]);
    });

    testWidgets('unbounded width shrink-wraps', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: set(),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final cancel = tester.getRect(find.byKey(const Key('cancel')));
      final ok = tester.getRect(find.byKey(const Key('ok')));
      expect(ok.left, cancel.right + 1);
    });
  });
}
