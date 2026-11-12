import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show Material, MaterialType, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// A host page whose trigger focus node and presenting context tests use to
/// open modals without moving focus off the trigger.
class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final FocusNode trigger = FocusNode();

  @override
  void dispose() {
    trigger.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: CarbonButton(
        label: 'Open',
        focusNode: trigger,
        autofocus: true,
        onPressed: () {},
      ),
    );
  }
}

final GlobalKey<_HostState> _hostKey = GlobalKey<_HostState>();

Future<CarbonHarness> _pumpHost(
  WidgetTester tester, {
  Size? size,
  double textScale = 1,
  bool reduceMotion = false,
  CarbonThemeData? theme,
}) async {
  final harness = await pumpCarbon(
    tester,
    _Host(key: _hostKey),
    size: size ?? const Size(800, 600),
    textScale: textScale,
    reduceMotion: reduceMotion,
    theme: theme,
  );
  await tester.pump();
  return harness;
}

class _Opened<T> {
  _Opened(this.future);
  final Future<T?> future;
}

Future<_Opened<T>> _open<T>(
  WidgetTester tester,
  WidgetBuilder builder, {
  bool barrierDismissible = true,
  ValueGetter<bool>? canDismiss,
  CarbonModalPresentation? presentation,
  Duration settle = const Duration(milliseconds: 400),
}) async {
  late Future<T?> result;
  result = showCarbonModal<T>(
    _hostKey.currentContext!,
    builder: builder,
    barrierDismissible: barrierDismissible,
    canDismiss: canDismiss,
    presentation: presentation,
  );
  await tester.pump();
  await tester.pump(settle);
  return _Opened<T>(result);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Widget _confirm({
  VoidCallback? onPrimary,
  VoidCallback? onSecondary,
  bool danger = false,
  bool busy = false,
  Widget? body,
}) => CarbonModal.confirmation(
  title: 'Delete project?',
  label: 'Project settings',
  body: body ?? const Text('This cannot be undone.'),
  danger: danger,
  primary: CarbonModalAction(
    label: 'Delete',
    onPressed: onPrimary,
    busy: busy,
  ),
  secondary: CarbonModalAction(label: 'Cancel', onPressed: onSecondary),
);

void main() {
  group('variants', () {
    testWidgets('informational has a close button and no actions', (
      tester,
    ) async {
      await _pumpHost(tester);
      var closed = false;
      await _open<void>(
          tester,
          (context) => CarbonModal.informational(
            title: 'About',
            body: const Text('Version 1'),
            onClose: () => closed = true,
          ),
        );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('About'), findsOneWidget);
      expect(find.byType(CarbonButtonSet), findsNothing);
      final close = find.bySemanticsLabel('Close');
      expect(find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ), findsOneWidget);
      expect(close, findsWidgets);
      await tester.tap(find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ));
      expect(closed, isTrue);
    });

    testWidgets('default close button pops the route', (tester) async {
      await _pumpHost(tester);
      final result = await _open<String>(
        tester,
        (context) => const CarbonModal.informational(
          title: 'About',
          body: Text('Version 1'),
        ),
      );
      await tester.tap(find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ));
      await _settle(tester);
      expect(find.text('About'), findsNothing);
      expect(await result.future, isNull);
    });

    testWidgets('showCloseButton false omits the close button', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open<void>(
          tester,
          (context) => const CarbonModal.informational(
            title: 'About',
            body: Text('Version 1'),
            showCloseButton: false,
          ),
        );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byType(CarbonModal),
          matching: find.byType(CarbonButton),
        ),
        findsNothing,
      );
    });

    testWidgets('confirmation runs the chosen action only', (tester) async {
      await _pumpHost(tester);
      var primary = 0;
      var secondary = 0;
      await _open<void>(
          tester,
          (context) => _confirm(
            onPrimary: () => primary++,
            onSecondary: () => secondary++,
          ),
        );
      await tester.tap(find.text('Delete'));
      expect((primary, secondary), (1, 0));
      await tester.tap(find.text('Cancel'));
      expect((primary, secondary), (1, 1));
    });

    testWidgets('danger variant uses the danger button, secondary stays', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm(danger: true));
      final buttons = tester
          .widgetList<CarbonButton>(
            find.descendant(
              of: find.byType(CarbonModal),
              matching: find.byType(CarbonButton),
            ),
          )
          .where((b) => b.label != null)
          .toList();
      expect(buttons.map((b) => b.kind), [
        CarbonButtonKind.secondary,
        CarbonButtonKind.danger,
      ]);
      expect(buttons.map((b) => b.label), ['Cancel', 'Delete']);
    });

    testWidgets('form action disabled and busy are host controlled', (
      tester,
    ) async {
      await _pumpHost(tester);
      var saves = 0;
      await _open<void>(
          tester,
          (context) => CarbonModal(
            title: 'Rename',
            body: const Text('Name'),
            actions: [
              const CarbonModalAction(
                label: 'Cancel',
                kind: CarbonButtonKind.secondary,
                onPressed: null,
              ),
              CarbonModalAction(label: 'Save', busy: true, onPressed: () => saves++),
            ],
          ),
        );
      final save = tester.widget<CarbonButton>(
        find.byWidgetPredicate((w) => w is CarbonButton && w.label == 'Save'),
      );
      expect(save.busy, isTrue);
      final cancel = tester.widget<CarbonButton>(
        find.byWidgetPredicate((w) => w is CarbonButton && w.label == 'Cancel'),
      );
      expect(cancel.onPressed, isNull);
      await tester.tap(find.text('Save'), warnIfMissed: false);
      expect(saves, 0, reason: 'busy swallows activation');
    });

    testWidgets('semantics names the dialog and scopes the route', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      final node = tester.getSemantics(find.bySemanticsLabel('Delete project?').first);
      expect(
        node.getSemanticsData().flagsCollection.scopesRoute &&
            node.getSemanticsData().flagsCollection.namesRoute,
        isTrue,
      );
      handle.dispose();
    });
  });

  group('sizing and presentation', () {
    testWidgets('widths follow the size and cap at the viewport', (
      tester,
    ) async {
      await _pumpHost(tester, size: const Size(900, 700));
      for (final (size, width) in [
        (CarbonModalSize.xs, 400.0),
        (CarbonModalSize.sm, 560.0),
        (CarbonModalSize.md, 720.0),
        (CarbonModalSize.lg, 900.0 - 32),
      ]) {
        await _open<void>(
            tester,
            (context) => CarbonModal.informational(
              title: 'T',
              body: const Text('B'),
              size: size,
            ),
          );
        expect(tester.getSize(find.byType(CarbonModal)).width, width, reason: '$size');
        await tester.tapAt(const Offset(2, 2));
        await _settle(tester);
      }
    });

    testWidgets('adaptive presentation is full screen on narrow widths', (
      tester,
    ) async {
      await _pumpHost(tester, size: const Size(320, 640));
      await _open<void>(tester, (context) => _confirm());
      expect(tester.getSize(find.byType(CarbonModal)), const Size(320, 640));
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
    });

    testWidgets('a presentation scope supplies the presentation', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        CarbonModalPresentationScope(
          presentation: const CarbonModalPresentation.fullScreen(),
          child: _Host(key: _hostKey),
        ),
        size: const Size(800, 600),
      );
      await tester.pump();
      await _open<void>(tester, (context) => _confirm());
      expect(tester.getSize(find.byType(CarbonModal)), const Size(800, 600));
    });

    testWidgets('host presentation receives the modal and may restyle it', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open<void>(
          tester,
          (context) => _confirm(),
          presentation: const _SheetPresentation(),
        );
      final rect = tester.getRect(find.byType(CarbonModal));
      expect(rect.bottom, 600);
      expect(rect.width, 800);
      expect(find.text('Delete project?'), findsOneWidget);
    });

    testWidgets('motion animates in and reduced motion does not', (
      tester,
    ) async {
      await _pumpHost(tester);
      late Future<void> f;
      f = showCarbonModal<void>(
        _hostKey.currentContext!,
        builder: (context) => _confirm(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      double opacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byType(CarbonModal),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(opacity(), lessThan(1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(opacity(), 1);
      await tester.tapAt(const Offset(2, 2));
      await _settle(tester);
      await f;

      await pumpCarbon(
        tester,
        _Host(key: _hostKey),
        size: const Size(800, 600),
        reduceMotion: true,
      );
      unawaited(
        showCarbonModal<void>(
          _hostKey.currentContext!,
          builder: (context) => _confirm(),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(CarbonModal), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(CarbonModal),
          matching: find.byType(Opacity),
        ),
        findsNothing,
        reason: 'no enter transition under reduced motion',
      );
    });
  });

  group('dismissal', () {
    testWidgets('Escape closes when allowed', (tester) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(CarbonModal), findsNothing);
    });

    testWidgets('system back closes when allowed', (tester) async {
      final harness = await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      await harness.back(tester);
      await _settle(tester);
      expect(find.byType(CarbonModal), findsNothing);
    });

    testWidgets('barrier tap closes only when barrierDismissible', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm(), barrierDismissible: false);
      await tester.tapAt(const Offset(2, 2));
      await _settle(tester);
      expect(find.byType(CarbonModal), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(CarbonModal), findsNothing);

      await _open<void>(tester, (context) => _confirm());
      await tester.tapAt(const Offset(2, 2));
      await _settle(tester);
      expect(find.byType(CarbonModal), findsNothing);
    });

    testWidgets('a tap inside the dialog does not dismiss it', (tester) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      await tester.tap(find.text('This cannot be undone.'));
      await _settle(tester);
      expect(find.byType(CarbonModal), findsOneWidget);
    });

    testWidgets('canDismiss vetoes Escape, back, barrier and close button', (
      tester,
    ) async {
      final harness = await _pumpHost(tester);
      var allowed = false;
      await _open<void>(
          tester,
          (context) => _confirm(busy: !allowed),
          canDismiss: () => allowed,
        );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await harness.back(tester);
      await tester.tapAt(const Offset(2, 2));
      await _settle(tester);
      expect(find.byType(CarbonModal), findsOneWidget);
      await tester.tap(find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ));
      await _settle(tester);
      expect(find.byType(CarbonModal), findsOneWidget);

      allowed = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(CarbonModal), findsNothing);
    });

    testWidgets('programmatic pop ignores the veto and returns the result', (
      tester,
    ) async {
      await _pumpHost(tester);
      final result = await _open<int>(
        tester,
        (context) => CarbonModal(
          title: 'Pick',
          body: const Text('x'),
          actions: [
            CarbonModalAction(
              label: 'Done',
              onPressed: () => Navigator.of(context).pop(7),
            ),
          ],
        ),
        canDismiss: () => false,
      );
      await tester.tap(find.text('Done'));
      await _settle(tester);
      expect(await result.future, 7);
    });
  });

  group('focus', () {
    testWidgets('initial focus lands inside and Tab stays contained', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      final modal = find.byType(CarbonModal);
      bool inside() {
        final focus = FocusManager.instance.primaryFocus;
        final ctx = focus?.context;
        if (ctx == null) return false;
        return find
            .descendant(of: modal, matching: find.byWidget(ctx.widget))
            .evaluate()
            .isNotEmpty ||
            ctx.findAncestorWidgetOfExactType<CarbonModal>() != null;
      }

      expect(inside(), isTrue, reason: 'initial focus');
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(inside(), isTrue, reason: 'after tab $i');
      }
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab, character: null);
        await tester.pump();
      }
      expect(inside(), isTrue);
    });

    testWidgets('autofocus action takes initial focus', (tester) async {
      await _pumpHost(tester);
      final safe = FocusNode();
      addTearDown(safe.dispose);
      await _open<void>(
          tester,
          (context) => CarbonModal(
            title: 'Discard?',
            body: const Text('x'),
            actions: [
              CarbonModalAction(
                label: 'Keep',
                kind: CarbonButtonKind.secondary,
                autofocus: true,
                focusNode: safe,
                onPressed: () {},
              ),
              CarbonModalAction(label: 'Discard', onPressed: () {}),
            ],
          ),
        );
      expect(safe.hasPrimaryFocus, isTrue);
    });

    testWidgets('focus returns to the trigger on close', (tester) async {
      await _pumpHost(tester);
      final trigger = _hostKey.currentState!.trigger;
      expect(trigger.hasPrimaryFocus, isTrue);
      await _open<void>(tester, (context) => _confirm());
      expect(trigger.hasPrimaryFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      await tester.pump();
      expect(find.byType(CarbonModal), findsNothing);
      expect(trigger.hasPrimaryFocus, isTrue);
    });

    testWidgets('a removed trigger does not break closing', (tester) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      await pumpCarbon(
        tester,
        const SizedBox.shrink(),
        size: const Size(800, 600),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(CarbonModal), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('live configuration', () {
    testWidgets('theme and density switches keep typed text and focus', (
      tester,
    ) async {
      final harness = await _pumpHost(tester);
      final controller = TextEditingController();
      final field = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(field.dispose);
      await _open<void>(
          tester,
          (context) => CarbonModal(
            title: 'Rename',
            body: Material(
              type: MaterialType.transparency,
              child: TextField(controller: controller, focusNode: field),
            ),
            actions: [
              CarbonModalAction(label: 'Save', onPressed: () {}),
            ],
          ),
        );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);

      Color surface() => (tester
              .widget<DecoratedBox>(
                find
                    .descendant(
                      of: find.byType(CarbonLayerSurface),
                      matching: find.byType(DecoratedBox),
                    )
                    .first,
              )
              .decoration as BoxDecoration)
          .color!;
      double titleSize() =>
          tester.widget<Text>(find.text('Rename')).style!.fontSize!;

      final white = CarbonThemeData();
      expect(surface(), white.layer(1));
      final dark = CarbonThemeData(scheme: CarbonThemeScheme.gray100);
      await harness.setTheme(tester, dark);
      await tester.pump(const Duration(milliseconds: 100));
      expect(surface(), dark.layer(1));
      expect(controller.text, 'hello');
      expect(field.hasPrimaryFocus, isTrue);

      final compactSize = titleSize();
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(titleSize(), greaterThan(compactSize));
      expect(controller.text, 'hello');
      expect(field.hasPrimaryFocus, isTrue);
      expect(surface(), dark.layer(1));

      final scrim = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .map((b) => b.color);
      expect(scrim, contains(dark.colors.overlay));
    });

    testWidgets('direction and text scale reach the open dialog', (
      tester,
    ) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      final ltrClose = tester.getTopLeft(find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ));
      expect(ltrClose.dx, greaterThan(400));
      await tester.tapAt(const Offset(2, 2));
      await _settle(tester);

      await pumpCarbon(
        tester,
        _Host(key: _hostKey),
        size: const Size(800, 600),
        dir: TextDirection.rtl,
      );
      await _open<void>(tester, (context) => _confirm());
      final rtlClose = tester.getTopLeft(find.byWidgetPredicate(
        (w) => w is CarbonButton && w.semanticLabel == 'Close',
      ));
      expect(rtlClose.dx, lessThan(400));
    });
  });

  group('long content and keyboard', () {
    Widget longBody() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (var i = 0; i < 40; i++) Text('Line $i of the body')],
    );

    Future<void> expectReachable(
      WidgetTester tester,
      Size size, {
      double inset = 0,
    }) async {
      final bottom = size.height - inset;
      final scrollable = find.descendant(
        of: find.byType(CarbonModal),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsOneWidget);
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));

      final title = tester.getRect(find.text('Delete project?'));
      final delete = tester.getRect(find.text('Delete'));
      final cancel = tester.getRect(find.text('Cancel'));
      expect(title.top, greaterThanOrEqualTo(0));
      expect(delete.bottom, lessThanOrEqualTo(bottom));
      expect(cancel.bottom, lessThanOrEqualTo(bottom));

      await tester.drag(scrollable, const Offset(0, -300));
      await tester.pump();
      expect(position.pixels, greaterThan(0));
      expect(tester.getRect(find.text('Delete project?')).top, title.top);
      expect(tester.getRect(find.text('Delete')).bottom, delete.bottom);
      expect(tester.takeException(), isNull);
    }

    testWidgets('actions and title stay visible at 200% text, short window', (
      tester,
    ) async {
      const size = Size(800, 300);
      await _pumpHost(tester, size: size, textScale: 2);
      await _open<void>(tester, (context) => _confirm(body: longBody()));
      await expectReachable(tester, size);
    });

    testWidgets('same when full screen on a narrow window', (tester) async {
      const size = Size(320, 400);
      await _pumpHost(tester, size: size, textScale: 2);
      await _open<void>(tester, (context) => _confirm(body: longBody()));
      await expectReachable(tester, size);
    });

    testWidgets('keyboard inset keeps the actions above the keyboard', (
      tester,
    ) async {
      const size = Size(800, 600);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await _pumpHost(tester, size: size);
      await _open<void>(tester, (context) => _confirm(body: longBody()));
      await expectReachable(tester, size, inset: 300);
    });

    testWidgets('safe area padding is respected', (tester) async {
      const size = Size(800, 600);
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 34);
      addTearDown(tester.view.resetPadding);
      await _pumpHost(tester, size: size);
      await _open<void>(tester, (context) => _confirm(body: longBody()));
      final rect = tester.getRect(find.byType(CarbonModal));
      expect(rect.top, greaterThanOrEqualTo(40));
      expect(rect.bottom, lessThanOrEqualTo(600 - 34));
    });

    testWidgets('short content shrinks to fit', (tester) async {
      await _pumpHost(tester);
      await _open<void>(tester, (context) => _confirm());
      expect(tester.getSize(find.byType(CarbonModal)).height, lessThan(300));
    });
  });

  group('lifecycle', () {
    testWidgets('repeated open and close leaves nothing behind', (
      tester,
    ) async {
      await _pumpHost(tester);
      for (var i = 0; i < 3; i++) {
        await _open<void>(tester, (context) => _confirm());
        expect(find.byType(CarbonModal), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(find.byType(CarbonModal), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

  });
}

class _SheetPresentation extends CarbonModalPresentation {
  const _SheetPresentation();

  @override
  Widget build(
    BuildContext context,
    Animation<double> animation,
    Widget modal,
  ) => Align(
    alignment: Alignment.bottomCenter,
    child: CarbonModalFrame(fullScreen: true, child: modal),
  );
}
