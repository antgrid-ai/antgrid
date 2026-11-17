import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

// Upstream references are Carbon v11 styles/scss/components/* and
// react/src/components/*.

final GlobalKey _hostKey = GlobalKey();

Future<void> _pumpHost(WidgetTester tester, {Size? size}) async {
  await pumpCarbon(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(key: _hostKey, width: 10, height: 10),
    ),
    size: size ?? const Size(1200, 900),
  );
}

Future<void> _open(WidgetTester tester, Widget modal) async {
  showCarbonModal<void>(
    _hostKey.currentContext!,
    builder: (_) => modal,
    presentation: const CarbonModalPresentation.centered(),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Rect _rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is CarbonButton && w.label == label);

Widget _top(Widget child, {double width = 480}) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(width: width, child: child),
);

Finder _icon(CarbonIcons icon) =>
    find.byWidgetPredicate((w) => w is CarbonIcon && w.icon == icon);

void main() {
  final theme = CarbonThemeData();

  group('modal (modal/_modal.scss)', () {
    testWidgets('title to body is 16 and body to footer is 48', (tester) async {
      await _pumpHost(tester);
      await _open(
        tester,
        CarbonModal.confirmation(
          title: 'Delete project?',
          body: const Text('This cannot be undone.'),
          primary: CarbonModalAction(label: 'Delete', onPressed: () {}),
          secondary: CarbonModalAction(label: 'Cancel', onPressed: () {}),
        ),
      );
      final title = _rectOf(tester, find.text('Delete project?'));
      final body = _rectOf(tester, find.text('This cannot be undone.'));
      final footer = _rectOf(tester, find.byType(CarbonButtonSet));
      // padding-block: $spacing-03 $spacing-09 on the content, plus the
      // header's margin-block-end $spacing-03.
      expect(body.top - title.bottom, 16);
      expect(footer.top - body.bottom, 48);
    });

    testWidgets('container has a 1px border-subtle outline', (tester) async {
      await _pumpHost(tester);
      await _open(
        tester,
        const CarbonModal.informational(title: 'About', body: Text('v1')),
      );
      final outlined = find.descendant(
        of: find.byType(CarbonModal),
        matching: find.byWidgetPredicate((w) {
          if (w is! DecoratedBox) return false;
          final d = w.decoration;
          if (d is! BoxDecoration) return false;
          final b = d.border;
          return b is Border &&
              b.top.width == 1 &&
              b.top.color == theme.borderSubtle(1);
        }),
      );
      expect(outlined, findsOneWidget);
      expect(tester.getSize(outlined).width, 560);
    });

    testWidgets('footer buttons take half the width, a quarter with three, '
        'packed to the end', (tester) async {
      await _pumpHost(tester);
      await _open(
        tester,
        CarbonModal(
          title: 'One',
          body: const Text('b'),
          actions: [CarbonModalAction(label: 'Save', onPressed: () {})],
        ),
      );
      final modal = _rectOf(tester, find.byType(CarbonModal));
      final save = _rectOf(tester, _button('Save'));
      // Inside the 1px outline: (560 - 2) / 2.
      expect(save.width, closeTo(279, 0.01));
      expect(save.right, closeTo(modal.right - 1, 0.01));

      await _open(
        tester,
        CarbonModal(
          title: 'Three',
          body: const Text('b'),
          actions: [
            CarbonModalAction(
              label: 'A',
              kind: CarbonButtonKind.secondary,
              onPressed: () {},
            ),
            CarbonModalAction(
              label: 'B',
              kind: CarbonButtonKind.secondary,
              onPressed: () {},
            ),
            CarbonModalAction(label: 'C', onPressed: () {}),
          ],
        ),
      );
      final inner = _rectOf(tester, find.byType(CarbonModal).last);
      final a = _rectOf(tester, _button('A'));
      final c = _rectOf(tester, _button('C'));
      expect(a.width, closeTo((inner.width - 2) * 0.25, 1));
      expect(c.right, closeTo(inner.right - 1, 0.01));
      expect(c.width, closeTo(a.width, 0.01));
    });

    testWidgets('label sits 4px above the title', (tester) async {
      await _pumpHost(tester);
      await _open(
        tester,
        const CarbonModal.informational(
          title: 'Title',
          label: 'Project',
          body: Text('b'),
        ),
      );
      final label = _rectOf(tester, find.text('Project'));
      final title = _rectOf(tester, find.text('Title'));
      expect(title.top - label.bottom, 4);
    });

    testWidgets('exit runs 240ms like the entrance', (tester) async {
      await _pumpHost(tester);
      await _open(
        tester,
        const CarbonModal.informational(title: 'Bye', body: Text('b')),
      );
      Navigator.of(_hostKey.currentContext!, rootNavigator: true).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(find.text('Bye'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('Bye'), findsNothing);
    });

    testWidgets('a danger confirmation opens on the secondary button', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open(
        tester,
        CarbonModal.confirmation(
          title: 'Delete?',
          body: const Text('b'),
          danger: true,
          primary: CarbonModalAction(label: 'Delete', onPressed: () {}),
          secondary: CarbonModalAction(label: 'Cancel', onPressed: () {}),
        ),
      );
      final focus = FocusManager.instance.primaryFocus!;
      expect(_rectOf(tester, _button('Cancel')).contains(focus.rect.center),
          isTrue);
    });

    testWidgets('an explicit autofocus on the primary is kept', (tester) async {
      await _pumpHost(tester);
      await _open(
        tester,
        CarbonModal.confirmation(
          title: 'Delete?',
          body: const Text('b'),
          danger: true,
          primary: CarbonModalAction(
            label: 'Delete',
            autofocus: true,
            onPressed: () {},
          ),
          secondary: CarbonModalAction(label: 'Cancel', onPressed: () {}),
        ),
      );
      final focus = FocusManager.instance.primaryFocus!;
      expect(_rectOf(tester, _button('Delete')).contains(focus.rect.center),
          isTrue);
    });
  });

  group('notification (inline and toast notification scss)', () {
    testWidgets('low contrast inline is outlined at 40% on three edges', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _top(
          const CarbonNotification(
            title: 'T',
            subtitle: 'S',
            announce: false,
          ),
        ),
      );
      final outline = find
          .descendant(
            of: find.byType(CarbonNotification),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.position == DecorationPosition.foreground &&
                  (w.decoration as BoxDecoration).border != null,
            ),
          );
      expect(outline, findsOneWidget);
      final border =
          ((tester.widget<DecoratedBox>(outline)).decoration as BoxDecoration)
                  .border!
              as BorderDirectional;
      final expected = theme.colors.supportInfo.withValues(alpha: 0.4);
      expect(border.top.color, expected);
      expect(border.end.color, expected);
      expect(border.bottom.color, expected);
      expect(border.top.width, 1);
      expect(border.start, BorderSide.none);
    });

    testWidgets('status icon is 20px in inline and toast', (tester) async {
      await pumpCarbon(
        tester,
        _top(const CarbonNotification(title: 'T', announce: false)),
      );
      expect(tester.getSize(_icon(CarbonIcons.informationFilled)),
          const Size(20, 20));
      await pumpCarbon(
        tester,
        _top(const CarbonToast(title: 'T', announce: false)),
      );
      expect(tester.getSize(_icon(CarbonIcons.informationFilled)),
          const Size(20, 20));
    });

    testWidgets('inline text sits 15px down in 14/18 body-compact-01', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _top(const CarbonNotification(subtitle: 'Hello', announce: false)),
      );
      final card = _rectOf(tester, find.byType(CarbonNotification));
      final text = _rectOf(
        tester,
        find.descendant(
          of: find.byType(CarbonNotification),
          matching: find.byType(RichText),
        ),
      );
      expect(text.top - card.top, 15);
      expect(text.height, 18);
      expect(_rectOf(tester, _icon(CarbonIcons.informationFilled)).top - card.top,
          14);
    });

    testWidgets('text keeps a gap before the close button', (tester) async {
      const long =
          'A long message that has to wrap over several lines so the text '
          'column spans its whole available width and meets the close button.';
      await pumpCarbon(
        tester,
        _top(
          CarbonNotification(subtitle: long, onClose: () {}, announce: false),
        ),
      );
      final text = _rectOf(
        tester,
        find.descendant(
          of: find.byType(CarbonNotification),
          matching: find.byType(RichText),
        ),
      );
      final close = _rectOf(tester, find.bySemanticsLabel('Close notification'));
      expect(close.left - text.right, 13);

      await pumpCarbon(
        tester,
        _top(
          CarbonToast(
            title: 'T',
            subtitle: long,
            onClose: () {},
            announce: false,
          ),
        ),
      );
      final sub = _rectOf(tester, find.text(long));
      final toastClose =
          _rectOf(tester, find.bySemanticsLabel('Close notification'));
      expect(toastClose.left - sub.right, 16);
    });

    testWidgets('toast is 288px wide by default', (tester) async {
      final controller = CarbonToastController();
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        CarbonToastOverlay(
          controller: controller,
          child: const SizedBox.expand(),
        ),
        size: const Size(1200, 900),
      );
      controller.show(title: 'Hi');
      await tester.pump();
      expect(tester.getSize(find.byType(CarbonToast)).width, 288);
      // Inset 16 from the corner as before.
      expect(_rectOf(tester, find.byType(CarbonToast)).right, 1200 - 16);
      expect(_rectOf(tester, find.byType(CarbonToast)).top, 16);
    });

    testWidgets('a tap just outside the toast reaches the app below', (
      tester,
    ) async {
      final controller = CarbonToastController();
      addTearDown(controller.dispose);
      var taps = 0;
      await pumpCarbon(
        tester,
        CarbonToastOverlay(
          controller: controller,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox.expand(),
          ),
        ),
        size: const Size(1200, 900),
      );
      controller.show(title: 'Saved');
      await tester.pump();
      final card = tester.getRect(find.byType(CarbonToast));
      await tester.tapAt(Offset(card.left, card.top - 4));
      expect(taps, 1);
    });

    testWidgets('toast has a 0 2 6 shadow and inline has none', (tester) async {
      await pumpCarbon(
        tester,
        _top(const CarbonToast(title: 'T', announce: false)),
      );
      final toast = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CarbonToast),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final shadow = (toast.decoration as BoxDecoration).boxShadow!.single;
      expect(shadow.offset, const Offset(0, 2));
      expect(shadow.blurRadius, 6);
      expect(shadow.color, const Color(0x33000000));

      await pumpCarbon(
        tester,
        _top(const CarbonNotification(title: 'T', announce: false)),
      );
      final inline = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CarbonNotification),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((inline.decoration as BoxDecoration).boxShadow, isNull);
    });

    testWidgets('toast pads 16 above and below its content', (tester) async {
      await pumpCarbon(
        tester,
        _top(
          const CarbonToast(
            title: 'Title',
            subtitle: 'Sub',
            caption: 'Cap',
            announce: false,
          ),
        ),
      );
      final card = _rectOf(tester, find.byType(CarbonToast));
      expect(_rectOf(tester, find.text('Title')).top - card.top, 16);
      expect(_rectOf(tester, _icon(CarbonIcons.informationFilled)).top - card.top,
          16);
      expect(card.bottom - _rectOf(tester, find.text('Cap')).bottom, 16);
    });

    testWidgets('toast caption is 14/18 in the text colour', (tester) async {
      await pumpCarbon(
        tester,
        _top(
          const CarbonToast(
            title: 'T',
            caption: 'Cap',
            announce: false,
            highContrast: false,
          ),
        ),
      );
      expect(_rectOf(tester, find.text('Cap')).height, 18);
      expect(
        tester.widget<Text>(find.text('Cap')).style!.color,
        theme.colors.textPrimary,
      );
      await pumpCarbon(
        tester,
        _top(const CarbonToast(title: 'T', caption: 'Cap', announce: false)),
      );
      expect(
        tester.widget<Text>(find.text('Cap')).style!.color,
        theme.colors.textInverse,
      );
    });
  });

  group('inline loading (inline-loading/_inline-loading.scss)', () {
    testWidgets('inactive renders no indicator slot', (tester) async {
      await pumpCarbon(
        tester,
        _top(
          const CarbonInlineLoading(
            status: CarbonInlineLoadingStatus.inactive,
            description: 'Idle',
          ),
        ),
      );
      expect(tester.getTopLeft(find.text('Idle')).dx, 0);
    });

    testWidgets('is at least 32px tall with 14/18 text', (tester) async {
      await pumpCarbon(
        tester,
        _top(
          const CarbonInlineLoading(
            status: CarbonInlineLoadingStatus.finished,
            description: 'Done',
          ),
        ),
      );
      expect(tester.getSize(find.byType(CarbonInlineLoading)).height, 32);
      expect(_rectOf(tester, find.text('Done')).height, 18);
      expect(_rectOf(tester, find.text('Done')).center.dy, 16);
    });
  });

  group('tooltip (tooltip/_tooltip.scss)', () {
    testWidgets('sits 12px from its trigger, caret included', (tester) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.center,
          child: CarbonTooltip(
            message: 'Tip',
            showDelay: Duration.zero,
            child: CarbonButton(
              key: const Key('a'),
              label: 'Save',
              onPressed: () {},
            ),
          ),
        ),
        size: const Size(600, 600),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('a'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final tip = _rectOf(tester, find.text('Tip'));
      final anchor = _rectOf(tester, find.byKey(const Key('a')));
      // The tooltip box pads its text by 16.
      expect(anchor.top - (tip.bottom + 16), 12);
    });
  });

  group('button (button/_button.scss, _mixins.scss)', () {
    Future<Rect> labelRect(WidgetTester tester, CarbonThemeData? t) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: CarbonButton(
            key: const Key('b'),
            label: 'Delete',
            size: CarbonButtonSize.extraLarge,
            onPressed: () {},
          ),
        ),
        theme: t,
        size: const Size(600, 600),
      );
      return _rectOf(tester, find.text('Delete'));
    }

    testWidgets('a 64px compact button pins its label 14px from the top', (
      tester,
    ) async {
      final label = await labelRect(tester, null);
      final btn = _rectOf(tester, find.byKey(const Key('b')));
      expect(btn.height, 64);
      // padding-block is capped at (48 - 18) / 2 - 1 border = 14, and the
      // extra block size falls below the label.
      expect(label.top - btn.top, 14);
    });

    testWidgets('touch density keeps the label centred', (tester) async {
      final label = await labelRect(
        tester,
        CarbonThemeData(density: CarbonDensity.touch),
      );
      final btn = _rectOf(tester, find.byKey(const Key('b')));
      expect(label.center.dy - btn.center.dy, closeTo(0, 1));
    });

    testWidgets('a 48px compact button stays centred', (tester) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: CarbonButton(
            key: const Key('b'),
            label: 'Delete',
            size: CarbonButtonSize.large,
            onPressed: () {},
          ),
        ),
        size: const Size(600, 600),
      );
      final label = _rectOf(tester, find.text('Delete'));
      final btn = _rectOf(tester, find.byKey(const Key('b')));
      expect(label.center.dy - btn.center.dy, closeTo(0, 1));
    });

    testWidgets('iconOnly iconSize sizes the glyph, not the button', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: CarbonButton.iconOnly(
            key: const Key('b'),
            icon: const CarbonIcon(CarbonIcons.close),
            semanticLabel: 'Close',
            size: CarbonButtonSize.large,
            iconSize: 20,
            onPressed: () {},
          ),
        ),
        size: const Size(600, 600),
      );
      expect(
        _rectOf(tester, find.byKey(const Key('b'))).size,
        const Size(48, 48),
      );
      expect(
        _rectOf(tester, _icon(CarbonIcons.close)).size,
        const Size(20, 20),
      );
    });

    testWidgets('modal close icon is 20 in a 48 button in compact', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open(
        tester,
        const CarbonModal.informational(title: 'About', body: Text('v1')),
      );
      final close = find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      );
      expect(_rectOf(tester, close).size, const Size(48, 48));
      expect(
        _rectOf(tester, _icon(CarbonIcons.close)).size,
        const Size(20, 20),
      );
    });

    testWidgets('close buttons show no hover or press fill', (tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(1, 1));
      for (final w in [
        CarbonNotification(title: 'T', onClose: () {}, announce: false),
        CarbonToast(title: 'T', onClose: () {}, announce: false),
      ]) {
        await pumpCarbon(tester, _top(w), size: const Size(800, 600));
        final close = find.byWidgetPredicate(
          (x) => x is CarbonButton && x.semanticLabel == 'Close notification',
        );
        double fillAlpha() {
          final box = tester.widget<DecoratedBox>(
            find
                .descendant(of: close, matching: find.byType(DecoratedBox))
                .first,
          );
          return (box.decoration as BoxDecoration).color?.a ?? 0;
        }

        Color? ink() => tester
            .widget<IconTheme>(
              find
                  .descendant(of: close, matching: find.byType(IconTheme))
                  .first,
            )
            .data
            .color;
        final restInk = ink();
        await mouse.moveTo(tester.getCenter(close));
        await tester.pump();
        expect(fillAlpha(), 0);
        expect(ink(), restInk);
        await mouse.down(tester.getCenter(close));
        await tester.pump();
        expect(fillAlpha(), 0);
        expect(ink(), restInk);
        await mouse.up();
      }
    });

    testWidgets('a plain ghost icon button still fills on hover', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: CarbonButton.iconOnly(
            key: const Key('b'),
            icon: const CarbonIcon(CarbonIcons.close),
            semanticLabel: 'Close',
            onPressed: () {},
          ),
        ),
        size: const Size(600, 600),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('b'))));
      await tester.pump();
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(const Key('b')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(((box.decoration as BoxDecoration).color?.a ?? 0) > 0, isTrue);
    });
  });
}
